// =============================================================================
// Incoming-call ring cadence
// =============================================================================
// The ringtone is generated, not a bundled audio file: an oscillator per beep
// costs nothing on a 1-core router's clients and cannot 404 from a static
// export. This module is only the *shape* of the ring, so the cadence can be
// tested without an AudioContext — the hook owns the nodes.
//
// The pattern is the European (ETSI) telephone cadence: 400 ms on, 200 ms off,
// 400 ms on, then a long 2 s silence before the next cycle. A phone ringing in a
// room should sound like a phone, not like an alarm clock.
// =============================================================================

/** Length of one ring cycle: two beeps plus the long silence. */
export const RING_CYCLE_MS = 3000;

/** Where each beep starts inside a cycle. */
export const RING_BEEPS_MS: readonly number[] = [0, 600];

/** How long each beep lasts. The 200 ms gap between the two is the difference. */
export const RING_BEEP_MS = 400;

/** Attack/release ramp so a beep does not click. */
export const RING_RAMP_S = 0.02;

/** Peak level of the generated tone, deliberately quiet. */
export const RING_GAIN = 0.18;

// -----------------------------------------------------------------------------
// Call-progress tones
// -----------------------------------------------------------------------------
// A phone tells you when the call connected and when it ended, without words. Two
// short tones do the same here, and they are constants rather than inline numbers
// so the tests can hold them to something (a tone longer than the packet the modem
// carries, or one above 4 kHz, would not even reach the far end — it would only
// annoy the caller's own ear).
export const ANSWER_BEEP = { hz: 880, ms: 120, pulses: 2, gapMs: 90, gain: 0.12 } as const;

/** One lower tone: the line is closed. */
export const END_BEEP = { hz: 440, ms: 180, pulses: 1, gapMs: 0, gain: 0.12 } as const;

/** Vibration pattern mirroring the audible cadence (Android only). */
export const RING_VIBRATE_MS: readonly number[] = [400, 200, 400, 2000];
