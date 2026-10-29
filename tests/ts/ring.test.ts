// =============================================================================
// tests/ts/ring.test.ts — the incoming-call ring cadence
// =============================================================================
// Run with:  sh tests/ts/run-ts-tests.sh
//        or: cd <qmanager> && bun test <this file>
//
// Under test: lib/ring.ts
//
// The ringtone is generated rather than bundled, so its cadence is data. These
// rules pin the data: two beeps per cycle, a real gap between them, and a long
// silence that makes it sound like a telephone instead of an alarm. A cadence
// that drifts into a continuous tone is indistinguishable from a stuck call.
// =============================================================================

import { describe, expect, test } from "bun:test";

// Loaded by path: see mask.test.ts for why the `@/` alias is not used here.
const QM_ROOT = (
  process.env.QM_ROOT ?? `${import.meta.dir}/../../../greenpacket-o5a-qmanager`
).replace(/\/+$/, "");

interface Ring {
  ANSWER_BEEP: { hz: number; ms: number; pulses: number; gapMs: number; gain: number };
  END_BEEP: { hz: number; ms: number; pulses: number; gapMs: number; gain: number };
  RING_BEEPS_MS: readonly number[];
  RING_BEEP_MS: number;
  RING_CYCLE_MS: number;
  RING_GAIN: number;
  RING_RAMP_S: number;
  RING_VIBRATE_MS: readonly number[];
}

let ring: Ring;
try {
  ring = (await import(`${QM_ROOT}/lib/ring.ts`)) as Ring;
} catch (err) {
  throw new Error(
    `cannot load ${QM_ROOT}/lib/ring.ts — set QM_ROOT to the QManager checkout (${(err as Error).message})`,
  );
}

const {
  ANSWER_BEEP,
  END_BEEP,
  RING_BEEPS_MS,
  RING_BEEP_MS,
  RING_CYCLE_MS,
  RING_GAIN,
  RING_RAMP_S,
  RING_VIBRATE_MS,
} = ring;

describe("ring cadence", () => {
  test("two beeps per cycle, in ascending order, starting at the cycle boundary", () => {
    expect(RING_BEEPS_MS.length).toBe(2);
    expect(RING_BEEPS_MS[0]).toBe(0);
    expect(RING_BEEPS_MS[1]).toBeGreaterThan(RING_BEEPS_MS[0]);
  });

  test("the beeps do not overlap: the gap is at least 100 ms", () => {
    const gap = RING_BEEPS_MS[1] - (RING_BEEPS_MS[0] + RING_BEEP_MS);
    expect(gap).toBeGreaterThanOrEqual(100);
  });

  test("the last beep finishes inside the cycle, leaving a real silence", () => {
    const lastEnd = RING_BEEPS_MS[RING_BEEPS_MS.length - 1] + RING_BEEP_MS;
    expect(lastEnd).toBeLessThan(RING_CYCLE_MS);
    expect(RING_CYCLE_MS - lastEnd).toBeGreaterThanOrEqual(1500);
  });

  test("the tone is quiet enough to hold next to the ear", () => {
    expect(RING_GAIN).toBeGreaterThan(0);
    expect(RING_GAIN).toBeLessThanOrEqual(0.25);
  });

  test("the ramps fit inside a beep, so the envelope never runs backwards", () => {
    const hold = RING_BEEP_MS / 1000 - RING_RAMP_S;
    expect(hold).toBeGreaterThan(0);
  });

  test("the answer tone is audible, distinguishable, and inside the phone band", () => {
    // Above 4 kHz it would only reach the caller's own ear, because the modem's
    // uplink is 8 kHz G.711; below ~300 Hz it competes with line noise.
    expect(ANSWER_BEEP.hz).toBeGreaterThan(300);
    expect(ANSWER_BEEP.hz).toBeLessThanOrEqual(3400);
    expect(ANSWER_BEEP.pulses).toBe(2);
    expect(ANSWER_BEEP.ms).toBeGreaterThanOrEqual(80);
    expect(ANSWER_BEEP.ms).toBeLessThanOrEqual(250);
  });

  test("the end tone is lower than the answer tone and shorter or equal in pulses", () => {
    expect(END_BEEP.hz).toBeLessThan(ANSWER_BEEP.hz);
    expect(END_BEEP.pulses).toBeLessThanOrEqual(ANSWER_BEEP.pulses);
  });

  test("neither tone is loud enough to startle a caller holding the phone", () => {
    expect(ANSWER_BEEP.gain).toBeLessThanOrEqual(0.2);
    expect(END_BEEP.gain).toBeLessThanOrEqual(0.2);
  });

  test("vibration mirrors the audible pattern, not a different rhythm", () => {
    expect(RING_VIBRATE_MS.slice(0, 2)).toEqual([RING_BEEP_MS, RING_BEEPS_MS[1] - RING_BEEP_MS]);
    const total = RING_VIBRATE_MS.reduce((a, b) => a + b, 0);
    expect(total).toBe(RING_CYCLE_MS);
  });
});
