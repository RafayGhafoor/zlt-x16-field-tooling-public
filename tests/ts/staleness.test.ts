// =============================================================================
// tests/ts/staleness.test.ts — the freshness rule of use-modem-status.ts
// =============================================================================
// Run with:  sh tests/ts/run-ts-tests.sh
//        or: cd <qmanager> && bun test <this file>
//
// THE RULE UNDER TEST (hooks/use-modem-status.ts):
//
//   Freshness must not depend on the difference between two unsynchronised
//   clocks. `isStale` is true when the MODEM's own timestamp (`json.timestamp`)
//   has not changed for longer than STALE_THRESHOLD_SECONDS = 10, measured
//   entirely on the browser's clock. The previous implementation subtracted the
//   router's timestamp from the browser's wall clock, so a client 10 s ahead of
//   the router pinned "Readings paused" on permanently while every poll was
//   succeeding — and a client BEHIND the router could never report a frozen
//   reading at all.
//
// HOW THIS IS TESTED, AND WHY IT IS NOT A COPY OF THE EXPRESSION.
//
// The hook is a React hook, but the decision lives in the fetch callback, not in
// JSX: this file stubs only React's hook primitives (useState/useRef/
// useCallback/useEffect — no DOM, no renderer, and the tree ships neither
// jsdom nor @testing-library) and then drives the REAL exported `useModemStatus`
// through its exported `refresh()`, with `Date.now` and `fetch` faked. So the
// assertions run against the production lines, not against a transcription of
// them: if the rule goes back to subtracting two clocks, these tests fail.
//
// The stub is not free — it depends on the hook calling its hooks in a fixed
// order (the state slots below) and on `refresh()` being the way a poll starts.
// If `use-modem-status.ts` changes either, this file must change with it. It is
// a characterisation of the CURRENT hook; nothing here is generated from it.
// =============================================================================

import { afterAll, describe, expect, mock, test } from "bun:test";

const QM_ROOT = (
  process.env.QM_ROOT ?? `${import.meta.dir}/../../../greenpacket-o5a-qmanager`
).replace(/\/+$/, "");

// -----------------------------------------------------------------------------
// React stand-in
// -----------------------------------------------------------------------------
// Slots are allocated in call order, which is why the two slots this file reads
// are named below. Order in use-modem-status.ts:
//   0 data · 1 isLoading · 2 error · 3 isStale · 4 receivedAtMs
//   5 mountedRef · 6 lastSampleTsRef · 7 lastSampleChangeAtRef · 8 intervalRef
//   9 fetchData · 10 refresh · 11 the polling useEffect
const SLOT_IS_STALE = 3;
const SLOT_RECEIVED_AT = 4;

let cursor = 0;
const stateValues: unknown[] = [];
const refs: { current: unknown }[] = [];

mock.module("react", () => ({
  useState(initial: unknown) {
    const i = cursor++;
    if (!(i in stateValues)) stateValues[i] = initial;
    const set = (next: unknown) =>
      (stateValues[i] =
        typeof next === "function"
          ? (next as (previous: unknown) => unknown)(stateValues[i])
          : next);
    return [stateValues[i], set];
  },
  useRef(initial: unknown) {
    const i = cursor++;
    if (!(i in refs)) refs[i] = { current: initial };
    return refs[i];
  },
  useCallback(fn: unknown) {
    cursor++;
    return fn;
  },
  useEffect() {
    // Not run: the polling effect would start a setInterval. Every poll in this
    // file is an explicit `refresh()` call, so each test controls the clock.
    cursor++;
  },
}));

type UseModemStatus = (options?: {
  pollInterval?: number;
  enabled?: boolean;
}) => {
  isStale: boolean;
  receivedAtMs: number | null;
  refresh: () => void;
};

let useModemStatus: UseModemStatus;
try {
  ({ useModemStatus } = (await import(
    `${QM_ROOT}/hooks/use-modem-status.ts`
  )) as { useModemStatus: UseModemStatus });
} catch (err) {
  throw new Error(
    `cannot load ${QM_ROOT}/hooks/use-modem-status.ts — ` +
      `set QM_ROOT to the QManager checkout (${(err as Error).message})`,
  );
}

// -----------------------------------------------------------------------------
// Clock and transport
// -----------------------------------------------------------------------------
// One fake browser clock and one fake modem timestamp are enough to express
// every case: `clockMs` is the client's wall clock, `routerTs` is what the
// modem's snapshot says (in the ROUTER's seconds, a different clock entirely).
const CLIENT_CLOCK_MS = 1_764_000_000_000;
const STALE_THRESHOLD_SECONDS = 10;

let clockMs = CLIENT_CLOCK_MS;
let routerTs = 0;
let fetchStatus = 200;

const realDateNow = Date.now;
const realFetch = globalThis.fetch;

Date.now = () => clockMs;
globalThis.fetch = (async () =>
  new Response(JSON.stringify({ timestamp: routerTs }), {
    status: fetchStatus,
    headers: { "content-type": "application/json" },
  })) as unknown as typeof fetch;

afterAll(() => {
  Date.now = realDateNow;
  globalThis.fetch = realFetch;
});

/** Let the fetch callback's promise chain settle (it is fire-and-forget). */
const settle = async () => {
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));
};

type Poll = {
  /** Milliseconds the BROWSER's clock advances before this poll. */
  advanceMs: number;
  /** Whether the modem has produced a new timestamp since the previous poll. */
  readingAdvances: boolean;
};

type Verdict = "fresh" | "stale";

/**
 * One hook instance, driven through a scripted poll sequence.
 *
 * @param routerClockOffsetSeconds router clock minus browser clock, in seconds
 *        (negative = router behind, positive = router ahead). Only the skew
 *        changes between the skew cases; the poll script stays identical.
 * @returns the freshness verdict after each poll, in order.
 */
async function runPolls(
  routerClockOffsetSeconds: number,
  polls: Poll[],
): Promise<{ verdicts: Verdict[]; receivedAtMs: (number | null)[] }> {
  // Fresh hook instance: reset the stub's slot allocations.
  cursor = 0;
  stateValues.length = 0;
  refs.length = 0;

  clockMs = CLIENT_CLOCK_MS;
  fetchStatus = 200;
  routerTs = Math.floor(CLIENT_CLOCK_MS / 1000) + routerClockOffsetSeconds;

  const hook = useModemStatus({ enabled: true });
  const verdicts: Verdict[] = [];
  const receivedAtMs: (number | null)[] = [];

  for (const poll of polls) {
    clockMs += poll.advanceMs;
    // The router stamps its own snapshots on its own clock, advancing by its own
    // ~2 s poll period whenever the readings actually move.
    if (poll.readingAdvances) routerTs += 2;
    hook.refresh();
    await settle();
    verdicts.push(stateValues[SLOT_IS_STALE] === true ? "stale" : "fresh");
    receivedAtMs.push((stateValues[SLOT_RECEIVED_AT] ?? null) as number | null);
  }

  return { verdicts, receivedAtMs };
}

/** Readings that keep moving for 30 s — the link is alive. */
const LIVE_FOR_30S: Poll[] = [
  { advanceMs: 0, readingAdvances: true },
  { advanceMs: 2000, readingAdvances: true },
  { advanceMs: 2000, readingAdvances: true },
  { advanceMs: 2000, readingAdvances: true },
  { advanceMs: 2000, readingAdvances: true },
  { advanceMs: 2000, readingAdvances: true },
  { advanceMs: 2000, readingAdvances: true },
  { advanceMs: 2000, readingAdvances: true },
  { advanceMs: 2000, readingAdvances: true },
  { advanceMs: 2000, readingAdvances: true },
  { advanceMs: 2000, readingAdvances: true },
  { advanceMs: 2000, readingAdvances: true },
  { advanceMs: 2000, readingAdvances: true },
  { advanceMs: 2000, readingAdvances: true },
  { advanceMs: 2000, readingAdvances: true },
  { advanceMs: 2000, readingAdvances: true },
];

/** Readings that move once, freeze for 20 s, then move again. */
const FREEZE_THEN_RESUME: Poll[] = [
  { advanceMs: 0, readingAdvances: true },
  { advanceMs: 2000, readingAdvances: true },
  { advanceMs: 3000, readingAdvances: false }, // age 3 s
  { advanceMs: 6000, readingAdvances: false }, // age 9 s — still under the threshold
  { advanceMs: 11000, readingAdvances: false }, // age 20 s
  { advanceMs: 2000, readingAdvances: true }, // readings resume
];

/** The threshold itself: age 10 s is not stale, age 11 s is. */
const AT_THE_THRESHOLD: Poll[] = [
  { advanceMs: 0, readingAdvances: true },
  { advanceMs: 10000, readingAdvances: false }, // age == 10 s
  { advanceMs: 1000, readingAdvances: false }, // age == 11 s
  { advanceMs: 2000, readingAdvances: true },
];

describe("freshness does not depend on the difference between two clocks", () => {
  test("same clock: 30 s of moving readings is never stale", async () => {
    const { verdicts } = await runPolls(0, LIVE_FOR_30S);
    expect(
      verdicts.every((v) => v === "fresh"),
      "a live link is fresh on every poll; if this fails, freshness is being measured against something other than the reading itself",
    ).toBe(true);
  });

  test("client 30 s ahead of the router: still fresh (the bug this rule replaced)", async () => {
    // The browser's clock is 30 s ahead of the router's. The old rule computed
    // `browserSeconds - json.timestamp` = 30 and called every poll stale, pinning
    // "Readings paused" on a perfectly live link. A 10 s threshold has no margin
    // against a skew of even 10 s, so the verdict must ignore the skew entirely.
    const { verdicts } = await runPolls(-30, LIVE_FOR_30S);
    expect(
      verdicts.some((v) => v === "stale"),
      "a client clock 30 s ahead of the router must not stale a live link — that is the clock-subtraction bug",
    ).toBe(false);
  });

  test("client 30 s behind the router: a frozen reading still goes stale", async () => {
    // The mirror image, and the other half of the same bug: with the browser's
    // clock behind the router's, `browserSeconds - json.timestamp` is NEGATIVE,
    // so a reading that stopped 20 s ago still looked fresh. Freshness has to be
    // symmetric — skew in either direction must change nothing.
    const { verdicts } = await runPolls(+30, FREEZE_THEN_RESUME);
    expect(
      verdicts,
      "a 30 s clock skew must not hide frozen readings: fresh, fresh, fresh, fresh, STALE, fresh",
    ).toEqual(["fresh", "fresh", "fresh", "fresh", "stale", "fresh"]);
  });

  test("same clock: a frozen reading goes stale, and recovers when it moves", async () => {
    const { verdicts } = await runPolls(0, FREEZE_THEN_RESUME);
    expect(
      verdicts,
      "the readings card means 'the readings stopped moving': 9 s frozen is fresh, 20 s frozen is stale, and a new reading clears it",
    ).toEqual(["fresh", "fresh", "fresh", "fresh", "stale", "fresh"]);
  });

  test(`the threshold is 10 s: age ${STALE_THRESHOLD_SECONDS} is fresh, age ${STALE_THRESHOLD_SECONDS + 1} is stale`, async () => {
    const { verdicts } = await runPolls(0, AT_THE_THRESHOLD);
    expect(
      verdicts,
      "the comparison is `> 10`, not `>= 10`: a poll that lands exactly on the threshold is still on time",
    ).toEqual(["fresh", "fresh", "stale", "fresh"]);
  });

  test("the verdict sequence is identical at −30 s, 0 s and +30 s of skew", async () => {
    // Sequential on purpose: the fake clock and the stub's slots are shared by
    // construction, so concurrent runs would interleave and each would grade the
    // other's polls.
    const aligned = await runPolls(0, LIVE_FOR_30S);
    const behind = await runPolls(-30, LIVE_FOR_30S);
    const ahead = await runPolls(+30, LIVE_FOR_30S);
    expect(
      behind.verdicts,
      "skew must cancel: the same reading sequence must produce the same verdicts whatever the clock offset",
    ).toEqual(aligned.verdicts);
    expect(
      ahead.verdicts,
      "skew must cancel in both directions, not just the one that used to look fine",
    ).toEqual(aligned.verdicts);
  });
});

describe("the arrival stamp consumers measure age from", () => {
  test("receivedAtMs is this browser's clock, never the modem's timestamp", async () => {
    // `receivedAtMs` exists so a consumer can compute "how long since this
    // snapshot" without reading a clock during render. If it were populated from
    // `json.timestamp` it would reintroduce the skew the rule above removes.
    const { receivedAtMs } = await runPolls(-30, [
      { advanceMs: 0, readingAdvances: true },
      { advanceMs: 2000, readingAdvances: true },
    ]);
    expect(
      receivedAtMs,
      "each snapshot's arrival stamp must be the browser's own clock reading at that poll",
    ).toEqual([CLIENT_CLOCK_MS, CLIENT_CLOCK_MS + 2000]);
  });
});
