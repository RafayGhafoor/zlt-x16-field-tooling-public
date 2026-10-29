// =============================================================================
// lab.mjs — does RNNoise actually clean a phone-call uplink?
// =============================================================================
// Runs the SAME wasm the browser will run (@jitsi/rnnoise-wasm, 112 KB) under
// bun, on real material: downloaded noise beds (fan, street, café) mixed with
// speech at known SNRs, plus the speech files' own room tone.
//
// Everything is measured twice: at 48 kHz (what the microphone produces, where
// the suppressor works) and at 8 kHz (what the cellular far end actually hears,
// because the codec is G.711/PCMU). Reporting only 48 kHz would flatter the
// result — the band that matters is 300–3400 Hz.
//
// Metrics, and why each one exists:
//   dSI-SDR   scale-invariant SDR of the output against the CLEAN reference,
//             minus the same for the mixture. Positive = closer to clean speech.
//   noise     RMS change in non-speech frames (from the clean file's energy).
//             Negative = quieter noise. This is the number a far-end listener feels.
//   speech    RMS change in speech frames. Should stay near 0 dB; a big negative
//             means RNNoise is eating words.
//   dropouts  longest run of near-silence inside a speech region (artefact check).
//   rtf       real-time factor on this host (x86); a relative cost indicator only.
// =============================================================================

import { readFileSync, writeFileSync } from "node:fs";
// The shipped build is the ASYNC one (0.1 model, 112 KB wasm) because AudioWorklet
// has no fetch: the page fetches the bytes and passes them in. The 0.2 model only
// exists inside the 1.9 MB "sync" build (its wasm is 1.44 MB and its runtime ABI
// does not accept the async glue), so it is measured here for comparison only.
const BUILD = process.env.RNNOISE_BUILD === "02" ? "02" : "01";

const FRAME = 480; // RNNoise is 48 kHz / 10 ms only
const RATE = 48000;

// ------------------------------------------------------------------ wav io ---
function readWav(path) {
  const b = readFileSync(path);
  if (b.toString("ascii", 0, 4) !== "RIFF") throw new Error(`${path}: not RIFF`);
  let off = 12;
  let fmt = null;
  while (off < b.length - 8) {
    const id = b.toString("ascii", off, off + 4);
    const size = b.readUInt32LE(off + 4);
    if (id === "fmt ") {
      fmt = {
        channels: b.readUInt16LE(off + 10),
        rate: b.readUInt32LE(off + 12),
        bits: b.readUInt16LE(off + 22),
      };
    } else if (id === "data") {
      if (!fmt) throw new Error(`${path}: data before fmt`);
      const n = Math.floor(size / 2 / fmt.channels);
      const out = new Float32Array(n);
      for (let i = 0; i < n; i += 1) {
        let acc = 0;
        for (let c = 0; c < fmt.channels; c += 1) {
          acc += b.readInt16LE(off + 8 + (i * fmt.channels + c) * 2) / 32768;
        }
        out[i] = acc / fmt.channels;
      }
      return { rate: fmt.rate, data: out };
    }
    off += 8 + size + (size % 2);
  }
  throw new Error(`${path}: no data chunk`);
}

function writeWav(path, samples, rate = RATE) {
  const n = samples.length;
  const buf = Buffer.alloc(44 + n * 2);
  buf.write("RIFF", 0, "ascii");
  buf.writeUInt32LE(36 + n * 2, 4);
  buf.write("WAVEfmt ", 8, "ascii");
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20);
  buf.writeUInt16LE(1, 22);
  buf.writeUInt32LE(rate, 24);
  buf.writeUInt32LE(rate * 2, 28);
  buf.writeUInt16LE(2, 32);
  buf.writeUInt16LE(16, 34);
  buf.write("data", 36, "ascii");
  buf.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i += 1) {
    const v = Math.max(-1, Math.min(1, samples[i]));
    buf.writeInt16LE(Math.round(v * 32767), 44 + i * 2);
  }
  writeFileSync(path, buf);
}

// ---------------------------------------------------------------- rnnoise ---
let mod;
if (BUILD === "02") {
  const { default: sync } = await import("/tmp/ns-lab/pkg/package/dist/rnnoise-sync.js");
  mod = sync();
} else {
  const { default: asyncFactory } = await import("/tmp/ns-lab/pkg/package/dist/rnnoise.js");
  const f = readFileSync("/tmp/ns-lab/pkg/package/dist/rnnoise.wasm");
  mod = await asyncFactory({ wasmBinary: f.buffer.slice(f.byteOffset, f.byteOffset + f.byteLength) });
}
await mod.ready;
const heapF32 = mod.HEAPF32 ?? new Float32Array(mod.HEAPU8.buffer);

function denoise(input) {
  const state = mod._rnnoise_create(0);
  if (!state) throw new Error("rnnoise_create failed");
  const ptrIn = mod._malloc(FRAME * 4);
  const ptrOut = mod._malloc(FRAME * 4);
  const out = new Float32Array(input.length);
  const inView = new Float32Array(mod.HEAPU8.buffer, ptrIn, FRAME);
  const outView = new Float32Array(mod.HEAPU8.buffer, ptrOut, FRAME);
  let vadSum = 0;
  let vadFrames = 0;
  try {
    for (let pos = 0; pos < input.length; pos += FRAME) {
      // RNNoise's process_frame expects samples in int16 SCALE as floats
      // (|x| up to 32768), not normalised [-1,1]. Feed it 0.1-range floats and it
      // treats every frame as silence and returns near-zero output — a trap that
      // looks exactly like "the model does nothing".
      for (let i = 0; i < FRAME; i += 1) {
        inView[i] = (pos + i < input.length ? input[pos + i] : 0) * 32768;
      }
      const p = mod._rnnoise_process_frame(state, ptrOut, ptrIn);
      if (typeof p === "number") {
        vadSum += p;
        vadFrames += 1;
      }
      for (let i = 0; i < FRAME; i += 1) {
        if (pos + i < out.length) out[pos + i] = outView[i] / 32768;
      }
    }
  } finally {
    mod._free(ptrIn);
    mod._free(ptrOut);
    mod._rnnoise_destroy(state);
  }
  return { out, vad: vadFrames ? vadSum / vadFrames : 0 };
}

// ---------------------------------------------------------------- metrics ---
const rms = (x, from, to) => {
  let s = 0;
  for (let i = from; i < to; i += 1) s += x[i] * x[i];
  return Math.sqrt(s / Math.max(1, to - from));
};

const db = (x) => (x <= 0 ? -120 : 20 * Math.log10(x));

/** 20 ms RMS envelope of the CLEAN reference, used to find speech vs silence. */
function frameEnergy(clean) {
  const hop = 960; // 20 ms
  const frames = [];
  for (let p = 0; p + hop <= clean.length; p += hop) {
    frames.push({ at: p, db: db(rms(clean, p, p + hop)) });
  }
  return frames;
}

function speechMask(clean) {
  const fr = frameEnergy(clean);
  const peak = Math.max(...fr.map((f) => f.db));
  // A frame is speech when it is within 30 dB of the loudest speech frame; the
  // band below that is the file's own room tone, which is what we want to
  // measure the suppressor against.
  return fr.map((f) => ({ ...f, speech: f.db > peak - 30 && f.db > -60 }));
}

/**
 * RNNoise is not sample-aligned: the model has a lookahead, so its output lags the
 * input by ~20 ms (two 10 ms frames, measured, not assumed). Comparing the two
 * without aligning first produces SI-SDR figures around -30 dB for a suppressor
 * that is working perfectly — the error is all phase.
 */
function findDelay(reference, processed) {
  const hop = 480;
  const frames = Math.min(600, Math.floor(reference.length / hop) - 40);
  let best = { lag: 0, corr: -2 };
  for (let lag = -24; lag <= 24; lag += 1) {
    let aa = 0;
    let bb = 0;
    let ab = 0;
    for (let k = 20; k < 20 + frames; k += 1) {
      const i = k * hop;
      const j = i + lag * hop;
      if (j < 0 || j + hop >= reference.length) continue;
      for (let m = 0; m < hop; m += 4) {
        aa += processed[i + m] * processed[i + m];
        bb += reference[j + m] * reference[j + m];
        ab += processed[i + m] * reference[j + m];
      }
    }
    const corr = ab / Math.sqrt(aa * bb || 1);
    if (corr > best.corr) best = { lag, corr };
  }
  // corr(processed[i], reference[i + lag]) peaks at lag = -d, so the delay is
  // the negation: processed[i] holds what the reference had d samples earlier.
  return -best.lag * hop;
}

/** Return `x` shifted left by `delay` samples, so it lines up with the reference. */
function align(x, delay) {
  if (delay <= 0) return x;
  const out = new Float32Array(Math.max(0, x.length - delay));
  for (let i = 0; i < out.length; i += 1) out[i] = x[i + delay];
  return out;
}

// ------------------------------------------------------------------ narrow ---
// The far end is a cellular call: G.711 at 8 kHz, so anything above ~3.4 kHz is
// discarded by the codec no matter what the suppressor removes. If RNNoise's work
// lived mostly in the top band, the feature would look great at 48 kHz and change
// nothing on the call. These two helpers answer that directly: a windowed-sinc
// low-pass at 3.4 kHz, then the same metrics on the band the far end hears.
const LOWPASS_HZ = 3400;

function lowpass(x, cutoffHz, rate = RATE, taps = 101) {
  const fc = cutoffHz / rate;
  let h = new Float32Array(taps);
  let sum = 0;
  const mid = (taps - 1) / 2;
  for (let i = 0; i < taps; i += 1) {
    const n = i - mid;
    const sinc = n === 0 ? 2 * fc : Math.sin(2 * Math.PI * fc * n) / (Math.PI * n);
    // Blackman window: enough stopband to be honest about what leaks through.
    const w =
      0.42 - 0.5 * Math.cos((2 * Math.PI * i) / (taps - 1)) + 0.08 * Math.cos((4 * Math.PI * i) / (taps - 1));
    h[i] = sinc * w;
    sum += h[i];
  }
  for (let i = 0; i < taps; i += 1) h[i] /= sum;

  const out = new Float32Array(x.length);
  for (let i = 0; i < x.length; i += 1) {
    let acc = 0;
    for (let k = 0; k < taps; k += 1) {
      const j = i - k;
      if (j >= 0) acc += h[k] * x[j];
    }
    out[i] = acc;
  }
  return out;
}

function siSdr(estimate, reference) {
  const n = Math.min(estimate.length, reference.length);
  let dot = 0;
  let rr = 0;
  for (let i = 0; i < n; i += 1) {
    dot += estimate[i] * reference[i];
    rr += reference[i] * reference[i];
  }
  const scale = rr === 0 ? 0 : dot / rr;
  let target = 0;
  let noise = 0;
  for (let i = 0; i < n; i += 1) {
    const t = scale * reference[i];
    target += t * t;
    const e = estimate[i] - t;
    noise += e * e;
  }
  if (target === 0) return -120;
  if (noise === 0) return 120;
  return 10 * Math.log10(target / noise);
}

function narrowNoiseDelta(mix, out, mask, hop) {
  let m = 0;
  let o = 0;
  let n = 0;
  for (const f of mask) {
    if (f.speech) continue;
    const to = Math.min(f.at + hop, mix.length, out.length);
    if (to <= f.at + 2) continue;
    m += rms(mix, f.at, to) ** 2;
    o += rms(out, f.at, to) ** 2;
    n += 1;
  }
  if (!n) return 0;
  return db(Math.sqrt(o / n)) - db(Math.sqrt(m / n));
}

function measure(name, mixture, processedRaw, clean) {
  const delay = findDelay(mixture, processedRaw);
  const processed = align(processedRaw, delay);
  const mask = speechMask(clean);
  const hop = 960;
  let noiseMix = 0;
  let noiseOut = 0;
  let noiseN = 0;
  let spMix = 0;
  let spOut = 0;
  let spN = 0;
  for (const f of mask) {
    const to = Math.min(f.at + hop, mixture.length, processed.length);
    if (to <= f.at + 2) continue;
    const m = rms(mixture, f.at, to);
    const o = rms(processed, f.at, to);
    if (f.speech) {
      spMix += m * m;
      spOut += o * o;
      spN += 1;
    } else {
      noiseMix += m * m;
      noiseOut += o * o;
      noiseN += 1;
    }
  }
  const noiseDelta = noiseN ? db(Math.sqrt(noiseOut / noiseN)) - db(Math.sqrt(noiseMix / noiseN)) : 0;
  const speechDelta = spN ? db(Math.sqrt(spOut / spN)) - db(Math.sqrt(spMix / spN)) : 0;

  // Longest run of near-silence inside a speech region: the artefact that makes
  // suppression sound like a broken line rather than a quiet room.
  let longest = 0;
  let run = 0;
  const gate = Math.max(1e-4, rms(processed, 0, processed.length) * 0.02);
  for (const f of mask) {
    if (!f.speech) {
      run = 0;
      continue;
    }
    const to = Math.min(f.at + hop, processed.length);
    if (rms(processed, f.at, to) < gate) {
      run += 20;
      longest = Math.max(longest, run);
    } else {
      run = 0;
    }
  }

  // Band-limit a 20 s window to what PCMU can carry and re-measure there.
  const window = Math.min(processed.length, clean.length, mixture.length, 20 * RATE);
  const nbMix = lowpass(mixture.slice(0, window), LOWPASS_HZ);
  const nbOut = lowpass(processed.slice(0, window), LOWPASS_HZ);
  const nbClean = lowpass(clean.slice(0, window), LOWPASS_HZ);

  return {
    name,
    delayMs: Math.round((delay / RATE) * 1000),
    narrow: {
      dSiSdr: +(siSdr(nbOut, nbClean) - siSdr(nbMix, nbClean)).toFixed(2),
      noiseDb: +narrowNoiseDelta(nbMix, nbOut, mask, hop).toFixed(2),
    },
    dSiSdr: +(siSdr(processed, clean) - siSdr(mixture, clean)).toFixed(2),
    noiseDb: +noiseDelta.toFixed(2),
    speechDb: +speechDelta.toFixed(2),
    dropoutsMs: longest,
    noiseFrames: noiseN,
    speechFrames: spN,
  };
}

/** Mix `noise` under `speech` at a target SNR (measured over speech frames). */
function mixAtSnr(speech, noise, snrDb) {
  const mask = speechMask(speech).filter((f) => f.speech);
  let sp = 0;
  let np = 0;
  let n = 0;
  for (const f of mask) {
    const to = Math.min(f.at + 960, speech.length, noise.length);
    if (to <= f.at + 2) continue;
    sp += rms(speech, f.at, to) ** 2;
    np += rms(noise, f.at, to) ** 2;
    n += 1;
  }
  const spRms = Math.sqrt(sp / Math.max(1, n));
  const npRms = Math.sqrt(np / Math.max(1, n));
  const gain = spRms / Math.max(1e-9, npRms) / Math.pow(10, snrDb / 20);
  const out = new Float32Array(speech.length);
  for (let i = 0; i < out.length; i += 1) {
    out[i] = speech[i] + noise[i] * gain;
  }
  return out;
}

// ------------------------------------------------------------------- run ----
const src = (n) => readWav(`/tmp/ns-lab/src/${n}.wav`).data;
const speech = src("speech");
const speech2 = src("speech2");
const noises = { fan: src("fan"), traffic: src("traffic"), cafe: src("cafe") };

const results = [];

// A. Speech files as they are: their own room tone is the noise.
for (const [label, clean] of [["speech", speech], ["speech2", speech2]]) {
  const t0 = performance.now();
  const { out, vad } = denoise(clean);
  const ms = performance.now() - t0;
  const r = measure(`${label} (own room tone)`, clean, out, clean);
  results.push({ ...r, vad: +vad.toFixed(3), rtf: +(ms / 1000 / (clean.length / RATE)).toFixed(4) });
  writeWav(`/tmp/ns-lab/out/${label}-own.wav`, out);
}

// B. Known-SNR mixtures of clean speech with each real noise bed.
for (const snr of [5, 10, 15]) {
  for (const [nname, noise] of Object.entries(noises)) {
    const mix = mixAtSnr(speech, noise, snr);
    const t0 = performance.now();
    const { out } = denoise(mix);
    const ms = performance.now() - t0;
    const r = measure(`speech+${nname} @${snr}dB`, mix, out, speech);
    results.push({ ...r, rtf: +(ms / 1000 / (mix.length / RATE)).toFixed(4) });
    writeWav(`/tmp/ns-lab/out/speech-${nname}-${snr}dB.wav`, out);
    if (snr === 10) writeWav(`/tmp/ns-lab/out/speech-${nname}-${snr}dB-mix.wav`, mix);
  }
}

writeFileSync(`/tmp/ns-lab/results-${BUILD}.json`, JSON.stringify(results, null, 2));
console.log(`\n== RNNoise build ${BUILD === "02" ? "0.2 (sync, 1.44 MB)" : "0.1 (async, 112 KB)"} ==`);
const pad = (s, n) => String(s).padEnd(n);
console.log(
  pad("case", 26), pad("delay ms", 9), pad("dSI-SDR", 9), pad("noise dB", 9),
  pad("speech dB", 10), pad("dropout ms", 11), pad("rtf", 8), pad("8k dSI-SDR", 10), pad("8k noise", 10)
);
for (const r of results) {
  console.log(
    pad(r.name, 26), pad(r.delayMs, 9), pad(r.dSiSdr, 9), pad(r.noiseDb, 9),
    pad(r.speechDb, 10), pad(r.dropoutsMs, 11), pad(r.rtf ?? "-", 8),
    pad(r.narrow?.dSiSdr ?? "-", 10), pad(r.narrow?.noiseDb ?? "-", 10)
  );
}
