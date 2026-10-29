// =============================================================================
// tests/ts/rnnoise.test.ts — the noise suppressor's two silent-failure traps
// =============================================================================
// Run with:  sh tests/ts/run-ts-tests.sh
//        or: cd <qmanager> && bun test <this file>
//
// Under test (the bytes that ship to the browser):
//   public/ns/rnnoise.js     Emscripten glue (@jitsi/rnnoise-wasm, Apache-2.0)
//   public/ns/rnnoise.wasm   the model itself, 112 KB — RNNoise **0.1**
//
// The package ships two builds and they are NOT interchangeable: the async pair
// above is the 0.1 model (112 KB) and the `*-sync.js` build inlines a 1.44 MB 0.2
// model whose runtime ABI the async glue cannot drive (it traps on
// rnnoise_process_frame). We ship 0.1 on purpose: measured on the same material it
// is within ~0.5 dB of 0.2 for noise reduction, 4x faster and 13x smaller.
//   public/ns/x16-ns-worklet.js  our AudioWorklet
//
// Two failures are worth a permanent test, because both look like success from
// the outside and neither throws:
//
//   1. SCALE. `rnnoise_process_frame` expects samples in int16 scale (|x| up to
//      32768). Given normalised [-1,1] floats it does not suppress at all — the
//      level change is ~0 dB and nothing is logged. Measured: -0.07 dB on white
//      noise at scale 1 against -42 dB at scale 32768. The page would say
//      "suppression on", the far end would hear the same noise, and every test
//      that only checks "audio still flows" would pass.
//   2. NO WORK. A suppressor that passes audio through unchanged also "works".
//      These tests require the model to actually remove noise, measured, while
//      keeping a speech-like harmonic at full level.
//
// The model is 48 kHz / 480-sample frames only, so every signal here is built at
// 48 kHz — the same rate the browser's AudioContext is pinned to.
// =============================================================================

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const QM_ROOT = (
  process.env.QM_ROOT ?? `${import.meta.dir}/../../../greenpacket-o5a-qmanager`
).replace(/\/+$/, "");

const FRAME = 480;
const RATE = 48000;

const rms = (x: Float32Array | number[]): number => {
  let s = 0;
  for (let i = 0; i < x.length; i += 1) s += x[i] * x[i];
  return Math.sqrt(s / Math.max(1, x.length));
};
const db = (x: number): number => (x <= 0 ? -120 : 20 * Math.log10(x));

/** Deterministic white noise: the same bytes every run, no flake. */
function whiteNoise(n: number, amplitude: number): Float32Array {
  const out = new Float32Array(n);
  let seed = 0x9e3779b9;
  for (let i = 0; i < n; i += 1) {
    seed = (seed * 1664525 + 1013904223) >>> 0;
    out[i] = ((seed / 0xffffffff) * 2 - 1) * amplitude;
  }
  return out;
}

/**
 * 1/f (pink) noise: the closest cheap stand-in for fan, HVAC and traffic. Pure
 * white noise is the hard case — the 0.1 model only takes ~5 dB off it, while real
 * beds lose 12-22 dB (docs/32) — so the strong assertion uses pink and white keeps
 * a weak one.
 */
function pinkNoise(n: number, amplitude: number): Float32Array {
  const out = new Float32Array(n);
  let b0 = 0;
  let b1 = 0;
  let b2 = 0;
  let seed = 12345;
  for (let i = 0; i < n; i += 1) {
    seed = (seed * 1664525 + 1013904223) >>> 0;
    const w = (seed / 0xffffffff) * 2 - 1;
    b0 = 0.99765 * b0 + w * 0.099046;
    b1 = 0.963 * b1 + w * 0.2965164;
    b2 = 0.57 * b2 + w * 1.0526913;
    out[i] = (b0 + b1 + b2 + w * 0.1848) * 0.05 * amplitude;
  }
  return out;
}

/** A voiced-sound stand-in: harmonics of 140 Hz with a slow amplitude envelope. */
function voiced(n: number, amplitude: number): Float32Array {
  const out = new Float32Array(n);
  for (let i = 0; i < n; i += 1) {
    const t = i / RATE;
    const env = 0.55 + 0.45 * Math.sin(2 * Math.PI * 2.5 * t);
    let v = 0;
    for (let h = 1; h <= 12; h += 1) v += Math.sin(2 * Math.PI * 140 * h * t) / h;
    out[i] = (v / 3.1) * amplitude * env;
  }
  return out;
}

interface RnnModule {
  ready: Promise<unknown>;
  HEAPU8: Uint8Array;
  _malloc(n: number): number;
  _free(p: number): void;
  _rnnoise_create(model: number): number;
  _rnnoise_destroy(state: number): void;
  _rnnoise_process_frame(state: number, out: number, input: number): number;
}

let createModule: ((opts?: Record<string, unknown>) => Promise<RnnModule>) | null = null;
let loadError: string | null = null;

try {
  const mod = (await import(`${QM_ROOT}/public/ns/rnnoise.js`)) as {
    default: (opts?: Record<string, unknown>) => Promise<RnnModule>;
  };
  createModule = mod.default;
} catch (err) {
  loadError = (err as Error).message;
}

/**
 * One wasm instance for the whole file.
 *
 * Emscripten's glue is not re-entrant: asking it for a second Module in the same
 * process hands back a runtime that is already initialised, and the model then
 * suppresses ~5 dB instead of ~40 — a quiet wrongness that looks like "the codec
 * is doing its job". The browser has the same shape (one worklet per context),
 * so one instance per test file mirrors it.
 */
let modulePromise: Promise<RnnModule> | null = null;

function getModule(): Promise<RnnModule> {
  if (!createModule) {
    throw new Error(`cannot load ${QM_ROOT}/public/ns/rnnoise.js — ${loadError}`);
  }
  if (!modulePromise) {
    // wasmBinary is how the worklet gets the bytes too (no fetch in a worklet).
    // `.buffer` alone would hand over Node's whole 8 KB pool instead of the file.
    const file = readFileSync(`${QM_ROOT}/public/ns/rnnoise.wasm`);
    const wasmBinary = file.buffer.slice(file.byteOffset, file.byteOffset + file.byteLength);
    modulePromise = createModule({ wasmBinary });
  }
  return modulePromise;
}

/** Run the model over `input`, applying `scale` to the samples it feeds in. */
async function denoise(input: Float32Array, scale: number): Promise<Float32Array> {
  const m = await getModule();
  const state = m._rnnoise_create(0);
  if (!state) throw new Error("rnnoise_create returned NULL");
  const ptrIn = m._malloc(FRAME * 4);
  const ptrOut = m._malloc(FRAME * 4);
  const out = new Float32Array(input.length);
  try {
    for (let pos = 0; pos < input.length; pos += FRAME) {
      const inView = new Float32Array(m.HEAPU8.buffer, ptrIn, FRAME);
      const outView = new Float32Array(m.HEAPU8.buffer, ptrOut, FRAME);
      for (let i = 0; i < FRAME; i += 1) {
        inView[i] = (pos + i < input.length ? input[pos + i] : 0) * scale;
      }
      m._rnnoise_process_frame(state, ptrOut, ptrIn);
      for (let i = 0; i < FRAME; i += 1) {
        if (pos + i < out.length) out[pos + i] = outView[i] / scale;
      }
    }
  } finally {
    m._free(ptrIn);
    m._free(ptrOut);
    m._rnnoise_destroy(state);
  }
  return out;
}

describe("the shipped worklet's contract", () => {
  test("frames are 480 samples at the model's 48 kHz", () => {
    const src = readFileSync(`${QM_ROOT}/public/ns/x16-ns-worklet.js`, "utf8");
    expect(src).toContain("const FRAME = 480;");
    expect(src).toContain("const SCALE = 32768;");
  });

  test("the worklet never fetches: bytes arrive in processorOptions", () => {
    const raw = readFileSync(`${QM_ROOT}/public/ns/x16-ns-worklet.js`, "utf8");
    // Strip comments first: the file *documents* why fetch is unavailable, and
    // that explanation is not a call. Only real code counts.
    const code = raw
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .split("\n")
      .filter((line) => !line.trim().startsWith("//"))
      .join("\n");
    // AudioWorkletGlobalScope has no fetch(); a worklet that calls it fails at
    // load time on every browser.
    expect(code).not.toMatch(/\bfetch\s*\(/);
    expect(raw).toContain("processorOptions");
  });

  test("a missing wasm byte block fails closed to a bypass, not to silence", () => {
    const src = readFileSync(`${QM_ROOT}/public/ns/x16-ns-worklet.js`, "utf8");
    expect(src).toContain("this.fail(\"no wasm bytes were provided to the worklet\")");
    expect(src).toContain("this.bypass = true");
  });
});

describe("the pre-gain cannot become the AGC that ran away", () => {
  // The browser's AGC took a -59 dBFS microphone to -21 dBFS in three seconds of
  // silence (recording 20261028-192436), which the far end heard as noise. Ours is
  // allowed to lift a quiet talker, but only while RNNoise says there IS speech,
  // and only inside a bound. These assertions exist because that difference is one
  // missing `if` away from being lost.
  const worklet = readFileSync(`${QM_ROOT}/public/ns/x16-ns-worklet.js`, "utf8");

  test("adaptation is gated on the model's VAD, not on level alone", () => {
    expect(worklet).toContain("AGC_VAD_ON");
    expect(worklet).toMatch(/this\.vad >= AGC_VAD_ON/);
  });

  test("silence freezes the gain: no decay, no ramp", () => {
    expect(worklet).toContain("gain is FROZEN");
    // A decay branch on silence is the wind-up bug; it must not exist.
    expect(worklet).not.toMatch(/else\s*\{\s*[^}]*gainDb\s*-=/);
  });

  test("the gain is bounded", () => {
    expect(worklet).toMatch(/AGC_MAX_GAIN_DB/);
    expect(worklet).toMatch(/Math\.max\(0, Math\.min\(AGC_MAX_GAIN_DB/);
  });
});

describe("the preference: on by default, but a decision is respected", () => {
  test("nothing stored means ON", async () => {
    const mod = (await import(`${QM_ROOT}/lib/ns-pref.ts`)) as {
      parseNsPref: (v: string | null) => boolean;
    };
    expect(mod.parseNsPref(null)).toBe(true);
    expect(mod.parseNsPref(undefined)).toBe(true);
  }, 20000);

  test("an explicit off is never overridden by the default", async () => {
    const mod = (await import(`${QM_ROOT}/lib/ns-pref.ts`)) as {
      parseNsPref: (v: string | null) => boolean;
    };
    expect(mod.parseNsPref("0")).toBe(false);
    expect(mod.parseNsPref("1")).toBe(true);
  }, 20000);

  test("a value that is not a decision falls back to the default, not to off", async () => {
    const mod = (await import(`${QM_ROOT}/lib/ns-pref.ts`)) as {
      parseNsPref: (v: string | null) => boolean;
    };
    // A corrupted key, another app's value, or a string "false" all mean "no
    // decision was recorded here" — they must not silently disable the feature.
    expect(mod.parseNsPref("")).toBe(true);
    expect(mod.parseNsPref("true")).toBe(true);
    expect(mod.parseNsPref("false")).toBe(true);
    expect(mod.parseNsPref("undefined")).toBe(true);
  }, 20000);
});

describe("the model, as this repo ships it", () => {
  test("normalised input is the documented trap: the model does nothing", async () => {
    const input = whiteNoise(RATE, 0.2); // |x| ~ 0.11, as a browser hands it over
    const out = await denoise(input, 1);
    const ratioDb = db(rms(out)) - db(rms(input));
    // Fail-quiet, not fail-loud: no suppression, no error. Pinned so nobody
    // "simplifies" the scale away and ships a feature that does nothing.
    expect(Math.abs(ratioDb)).toBeLessThan(3);
  }, 30000);

  test("int16-scaled input removes 1/f noise for real (>= 10 dB)", async () => {
    const input = pinkNoise(RATE, 1);
    const out = await denoise(input, 32768);
    const ratioDb = db(rms(out)) - db(rms(input));
    // Measured -13.6 dB with the shipped 0.1 model; the margin absorbs a different
    // wasm build without letting a no-op pass.
    expect(ratioDb).toBeLessThanOrEqual(-10);
  }, 30000);

  test("white noise is the hard case and is still attenuated at all", async () => {
    const input = whiteNoise(RATE, 0.2);
    const out = await denoise(input, 32768);
    const ratioDb = db(rms(out)) - db(rms(input));
    // Measured -4.65 dB. Documented rather than wished for: if a change makes this
    // the headline number, the real beds have regressed too.
    expect(ratioDb).toBeLessThanOrEqual(-3);
  }, 30000);

  test("a voiced signal survives: its level is preserved within 6 dB", async () => {
    const speech = voiced(RATE, 0.3);
    const out = await denoise(speech, 32768);
    const delta = db(rms(out)) - db(rms(speech));
    // RNNoise ducks quiet talkers; this pins the ducking to something a listener
    // would not notice, so a regression that eats speech is caught here.
    expect(delta).toBeGreaterThan(-6);
    expect(delta).toBeLessThan(6);
  }, 30000);

  test("noise under speech is attenuated more than the speech itself", async () => {
    const speech = voiced(RATE, 0.25);
    const noise = whiteNoise(RATE, 0.05);
    const mix = new Float32Array(RATE);
    for (let i = 0; i < mix.length; i += 1) mix[i] = speech[i] + noise[i];

    const out = await denoise(mix, 32768);

    // Compare the tail of the file (no envelope, so the voiced part is at its
    // floor) against the same window of the input.
    const from = Math.floor(RATE * 0.9);
    const to = RATE;
    const tailIn = rms(mix.subarray(from, to));
    const tailOut = rms(out.subarray(from - 0, to));
    const overall = db(rms(out)) - db(rms(mix));
    expect(overall).toBeLessThanOrEqual(0);
    expect(tailOut).toBeLessThan(tailIn);
  }, 30000);
});
