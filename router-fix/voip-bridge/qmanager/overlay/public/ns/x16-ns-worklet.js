// =============================================================================
// x16-ns-worklet.js — RNNoise inside an AudioWorklet, fed by bytes we already have
// =============================================================================
// Runs in AudioWorkletGlobalScope, where `fetch()` does not exist. Two ways to get
// 112 KB of WebAssembly in here:
//
//   1. Serve the "sync" build, which inlines the wasm as a base64 data URL. It
//      works, but the file is 1.9 MB (1.3 MB gzipped) for a page served by a
//      one-core router.
//   2. Fetch the 112 KB `.wasm` on the MAIN thread (where fetch exists), hand the
//      bytes over in `processorOptions`, and instantiate them here.
//
// This file is (2): the bytes arrive as a transferable ArrayBuffer, Emscripten's
// glue is told about them with `wasmBinary`, and no network call happens in the
// worklet.
//
// Contract with the model, established by measurement (docs/32):
//   - 48 kHz only, 480-sample (10 ms) frames;
//   - rnnoise_process_frame takes samples in INT16 SCALE (|x| up to 32768).
//     Feed it normalised [-1,1] floats and it returns near-silence: the model
//     reads every frame as quiet and gates everything. That failure looks exactly
//     like "noise suppression does nothing", so the scaling is asserted in tests;
//   - it is not sample-aligned: the output lags the input by ~20 ms (2 frames).
//     That delay is the model's, not this file's — nothing here buffers on top.
// =============================================================================

import createRNNWasmModule from "./rnnoise.js";

const FRAME = 480;
const SCALE = 32768;
/** Frames of processed audio allowed to wait for the output. Bounded on purpose. */
const MAX_QUEUE = 4;
/** Below this the signal is untouched; above it, a tanh knee up to LIMIT_CEILING. */
const LIMIT_THRESHOLD = 0.7;
const LIMIT_CEILING = 0.98;

class X16NoiseSuppressor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const bytes = options?.processorOptions?.wasm;

    this.ready = false;
    this.failed = null;
    this.bypass = false;
    this.state = 0;
    this.ptrIn = 0;
    this.ptrOut = 0;
    this.inBuf = new Float32Array(FRAME);
    this.inFill = 0;
    this.queue = [];
    this.outPos = 0;
    this.droppedSamples = 0;
    this.vad = 0;
    this.frames = 0;
    // Watchdog state: the worklet can be alive, "ready", and still emit nothing
    // (a suspended context, a starved input). Silence on the far end is the worst
    // outcome, so a run of silent output while the input carries signal is
    // reported to the page, which then puts the raw microphone back on the wire.
    this.silentRun = 0;
    this.limited = 0;
    this.gainDb = 0;
    this.inPeak = 0;
    this.reportedSilence = false;

    if (!bytes) {
      this.fail("no wasm bytes were provided to the worklet");
      return;
    }

    // Mute is handled HERE, before the model: the far end must hear nothing, and
    // the model must not spend its noise estimate on a muted room. The output is
    // zeroed as well, so a graph that is muted at the source cannot leak.
    this.muted = false;
    this.port.onmessage = (e) => {
      const msg = e.data || {};
      if (msg.type === "mute") {
        this.muted = true;
      } else if (msg.type === "unmute") {
        this.muted = false;
      }
    };

    // Emscripten's factory is async; process() runs meanwhile and emits silence
    // rather than garbage, so a slow phone never drops call audio at startup.
    createRNNWasmModule({
      wasmBinary: bytes,
      print: () => {},
      printErr: () => {},
    })
      .then((m) => {
        this.mod = m;
        this.state = m._rnnoise_create(0);
        if (!this.state) {
          this.fail("rnnoise_create returned NULL");
          return;
        }
        this.ptrIn = m._malloc(FRAME * 4);
        this.ptrOut = m._malloc(FRAME * 4);
        this.inView = new Float32Array(m.HEAPU8.buffer, this.ptrIn, FRAME);
        this.outView = new Float32Array(m.HEAPU8.buffer, this.ptrOut, FRAME);
        this.ready = true;
        this.port.postMessage({ type: "ready", frameMs: (FRAME / sampleRate) * 1000 });
      })
      .catch((err) => this.fail(String(err && err.message ? err.message : err)));
  }

  /** Emit one processed frame into the queue. */
  processFrame() {
    const gain = Math.pow(10, this.gainDb / 20);
    for (let i = 0; i < FRAME; i += 1) this.inView[i] = this.inBuf[i] * SCALE * gain;
    const p = this.mod._rnnoise_process_frame(this.state, this.ptrOut, this.ptrIn);
    if (typeof p === "number") this.vad = p;
    // Input energy over this frame, before the model touches it. This is also the
    // level the AGC aims, so it is measured with the current gain applied.
    let inSum = 0;
    for (let i = 0; i < FRAME; i += 1) inSum += this.inBuf[i] * this.inBuf[i];
    this.inPeak = Math.sqrt(inSum / FRAME);

    const out = new Float32Array(FRAME);
    if (this.muted) {
      // Feed the model silence so its state tracks "no speech", and emit silence.
      for (let i = 0; i < FRAME; i += 1) this.inView[i] = 0;
      this.mod._rnnoise_process_frame(this.state, this.ptrOut, this.ptrIn);
      this.frames += 1;
      this.queue.push(out);
      return;
    }
    if (this.bypass) {
      out.set(this.inBuf);
    } else {
      for (let i = 0; i < FRAME; i += 1) out[i] = this.outView[i] / SCALE;
    }
    // Soft limiter. The recording that exposed the AGC runaway also peaked at
    // -0.2 dBFS, which an 8-bit mu-law encoder turns into clipping — audible as a
    // crackle on a cellular call. A fast, gentle ceiling keeps the model's output
    // inside the codec's range without pumping.
    for (let i = 0; i < FRAME; i += 1) {
      const x = out[i];
      const a = Math.abs(x);
      if (a > LIMIT_THRESHOLD) {
        const over = a - LIMIT_THRESHOLD;
        const room = LIMIT_CEILING - LIMIT_THRESHOLD;
        const compressed = LIMIT_THRESHOLD + room * Math.tanh(over / room);
        out[i] = x < 0 ? -compressed : compressed;
        this.limited += 1;
      }
    }

    // Adapt the pre-gain on speech frames only (see AGC_* above).
    if (!this.bypass && !this.muted && typeof this.vad === "number") {
      const levelDbfs = this.inPeak <= 0 ? -120 : 20 * Math.log10(this.inPeak);
      if (this.vad >= AGC_VAD_ON && levelDbfs > -80) {
        const want = AGC_TARGET_DBFS - levelDbfs;
        const step = Math.max(-AGC_STEP_DB, Math.min(AGC_STEP_DB, want * 0.25));
        this.gainDb = Math.max(0, Math.min(AGC_MAX_GAIN_DB, this.gainDb + step));
      }
      // Silence: gain is FROZEN, not decayed. Nothing to adapt to, and a ramp here
      // is exactly the noise wind-up this design exists to prevent.
    }

    let outSum = 0;
    for (let i = 0; i < FRAME; i += 1) outSum += out[i] * out[i];
    const outRms = Math.sqrt(outSum / FRAME);

    // 1 s of output silence while the microphone carries real signal = the graph
    // is not delivering audio. Report once; keep bypassing so a later frame can
    // still recover if the cause was transient.
    if (!this.bypass && this.inPeak > 0.002 && outRms < 0.0005) {
      this.silentRun += 1;
      if (this.silentRun === 100 && !this.reportedSilence) {
        this.reportedSilence = true;
        this.port.postMessage({
          type: "silent",
          inPeak: Number(this.inPeak.toFixed(4)),
          reason: "the suppressor is emitting silence while the microphone has signal",
        });
      }
    } else if (outRms >= 0.0005) {
      this.silentRun = 0;
    this.limited = 0;
    this.gainDb = 0;
      this.reportedSilence = false;
    }

    this.frames += 1;
    this.queue.push(out);
  }

  fail(reason) {
    // Bypass, not break: the page keeps its microphone and the call keeps audio.
    this.failed = reason;
    this.bypass = true;
    this.port.postMessage({ type: "error", reason });
  }

  process(inputs, outputs) {
    const output = outputs[0];
    if (!output || output.length === 0) {
      return true;
    }
    const mono = output[0];
    const input = inputs[0];
    const src = input && input.length > 0 ? input[0] : null;

    if (!this.ready) {
      mono.fill(0);
      return true;
    }

    // 1. Serve the output from the processed-frame queue.
    let written = 0;
    while (written < mono.length) {
      while (this.queue.length > MAX_QUEUE) {
        this.queue.shift();
        this.outPos = 0;
        this.droppedSamples += FRAME;
      }
      const head = this.queue[0];
      if (!head) {
        break;
      }
      const need = Math.min(mono.length - written, FRAME - this.outPos);
      mono.set(head.subarray(this.outPos, this.outPos + need), written);
      written += need;
      this.outPos += need;
      if (this.outPos >= FRAME) {
        this.outPos = 0;
        this.queue.shift();
      }
    }
    for (let i = written; i < mono.length; i += 1) {
      mono[i] = 0;
    }

    // 2. Feed the model from the input, one whole 10 ms frame at a time.
    if (src) {
      for (let i = 0; i < src.length; i += 1) {
        this.inBuf[this.inFill] = src[i];
        this.inFill += 1;
        if (this.inFill === FRAME) {
          this.inFill = 0;
          this.processFrame();
        }
      }
    }

    if (this.frames > 0 && this.frames % 200 === 0) {
      this.port.postMessage({
        type: "stats",
        frames: this.frames,
        vad: Number(this.vad.toFixed(3)),
        gainDb: Number(this.gainDb.toFixed(1)),
        droppedSamples: this.droppedSamples,
        queueFrames: this.queue.length,
        bypass: this.bypass,
      });
    }
    return true;
  }
}

registerProcessor("x16-ns", X16NoiseSuppressor);
