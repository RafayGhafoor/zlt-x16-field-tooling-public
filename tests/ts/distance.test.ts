// =============================================================================
// tests/ts/distance.test.ts — cell-distance maths of the QManager port
// =============================================================================
// Run with:  sh tests/ts/run-ts-tests.sh
//        or: cd <qmanager> && bun test <this file>
//
// Under test (read-only, in the QManager tree — no production file is changed):
//   types/modem-status.ts
//     calculateLteDistance(ta)   ta  is a TA INDEX      (0..1282)
//     calculateNrDistance(nta)   nta is a raw NTA COUNT
//
// The two functions deliberately take DIFFERENT UNITS. Everything here exists to
// hold that line, because the values now come from two different device back
// ends on the X16: the Quectel AT command reports an index, QMI reports
// microseconds (docs/captures/recon-distance-mimo.md §1.4). A port that drops
// the conversion keeps compiling, keeps rendering a plausible number, and is
// simply wrong by ~1.9x — see the regression guard below.
// =============================================================================

const QM_ROOT = (
  process.env.QM_ROOT ?? `${import.meta.dir}/../../../greenpacket-o5a-qmanager`
).replace(/\/+$/, "");

/** Only the two exports this suite reads (the module is loaded by path, not by alias). */
interface DistanceMath {
  calculateLteDistance(ta: number | null): number | null;
  calculateNrDistance(nta: number | null): number | null;
}

// The `@/…` alias resolves against the QManager tsconfig, i.e. only for files
// that live inside that tree. This file lives in the X16 repo, so it loads the
// module by path and names the tree in the error if it cannot.
let math: DistanceMath;
try {
  math = (await import(`${QM_ROOT}/types/modem-status.ts`)) as DistanceMath;
} catch (err) {
  throw new Error(
    `cannot load ${QM_ROOT}/types/modem-status.ts — ` +
      `set QM_ROOT to the QManager checkout (${(err as Error).message})`,
  );
}
const { calculateLteDistance, calculateNrDistance } = math;

/** One LTE unit (16·Ts = 16/30720000 s) expressed in microseconds. */
const LTE_INDEX_US = 16 / 30720000 * 1e6; // 0.5208333… µs

describe("calculateLteDistance — TA index in, km out", () => {
  test("0, null and >1282 are 'no reading', never 0 km", () => {
    expect(
      calculateLteDistance(0),
      "TA 0 is the modem's 'no data' default, not a cell 0 m away; it must be null, never 0",
    ).toBeNull();
    expect(
      calculateLteDistance(null),
      "a missing TA must be null — the UI prints '-' for it and must not print a distance",
    ).toBeNull();
    expect(
      calculateLteDistance(1283),
      "1282 is the 3GPP maximum TA index (100.2 km); anything above it is a parse error or a µs value, not an index",
    ).toBeNull();
  });

  test("the 3GPP maximum index 1282 is still a usable reading", () => {
    expect(
      calculateLteDistance(1282),
      "the range guard must be > 1282, not >= 1282: 1282 is the last valid index",
    ).toBeCloseTo(100.15625, 4);
  });

  test("the known point ta=15 is ~1.17 km", () => {
    // 15 * 16 * Ts * c / 2 = 1171.875 m. This is the anchor every other number
    // in this file is compared against (docs/captures/recon-distance-mimo.md §1.4).
    expect(
      calculateLteDistance(15),
      "TA index 15 must be 1.171875 km — if this moved, the formula or the unit changed",
    ).toBeCloseTo(1.171875, 6);
  });
});

describe("regression guard — TA index vs QMI microseconds", () => {
  // THE DOCUMENTED TRAP (docs/captures/recon-distance-mimo.md §1.4).
  //
  // On this modem the LTE timing advance arrives from QMI as MICROSECONDS:
  //   qmicli --nas-get-cell-location-info  ->  LTE Timing Advance: '8' us
  // `calculateLteDistance` wants an INDEX, and one index is 16·Ts = 0.520833 µs,
  // so 8 µs is index 15.36 → 15. Feeding 8 in as an index is a silent 1.92x
  // under-report: it renders "625 m" for a cell that is 1.20 km away. Both are
  // plausible numbers on a dashboard, which is exactly why the conversion has to
  // be pinned by a test rather than by a comment: dropping it changes no type,
  // throws no error, and fails no other check.
  test("feeding QMI's 8 µs straight in as an index under-reports by 1.92x", () => {
    const rawKm = calculateLteDistance(8);
    expect(
      rawKm,
      "8 is inside the valid index range, so the mistake is not caught by the null guard — it returns a number",
    ).not.toBeNull();
    expect(
      rawKm!,
      "8 used as an index gives 625 m; if this changed, the guard below is no longer describing the trap",
    ).toBeCloseTo(0.625, 6);

    const indexFromUs = Math.round(8 / LTE_INDEX_US); // 15
    const correctedKm = calculateLteDistance(indexFromUs);
    expect(
      correctedKm,
      "the converted index must still be a reading — a conversion that lands on 0 would hide the cell entirely",
    ).not.toBeNull();
    expect(
      correctedKm!,
      "8 µs is index 15.36 → 15, i.e. 1.17 km, not 0.62 km",
    ).toBeCloseTo(1.171875, 6);

    // The conversion is the right one because both routes agree with physics:
    // a round trip of 8 µs is 1.20 km of path.
    const physicalKm = (3e8 * 8e-6) / 2 / 1000; // 1.2 km
    expect(
      correctedKm!,
      "the converted index must agree with c·8µs/2 = 1.20 km — that agreement is the proof the factor is right",
    ).toBeCloseTo(1.2, 1);
    expect(
      rawKm! / physicalKm,
      "the un-converted value must sit at 1/1.92 of the truth (0.52x), i.e. wrong by more than a cell radius",
    ).toBeCloseTo(1 / 1.92, 3);
    expect(
      rawKm!,
      "any distance under 700 m for this reading is the dropped conversion showing",
    ).toBeLessThan(0.7);
  });
});

describe("calculateNrDistance — raw NTA count in, km out", () => {
  test("0 and null are 'no reading', never 0 km", () => {
    expect(
      calculateNrDistance(0),
      "an NR block with no 5G leg still reports nta=0; that is 'no data', not a cell 0 m away",
    ).toBeNull();
    expect(
      calculateNrDistance(null),
      "a missing NTA must be null so the NR distance row renders '-'",
    ).toBeNull();
  });

  test("NTA 1000 is a metre-scale distance (~76 m), not a kilometre-scale one", () => {
    // Tc = 1/(480e3·4096): one NTA unit is 76.3 m of one-way distance.
    expect(
      calculateNrDistance(1000),
      "1000 NTA must be 76.29 m; NR takes a raw NTA count, so it is ~1000x smaller than the LTE index formula would make it",
    ).toBeCloseTo(0.076294, 5);
    expect(
      calculateNrDistance(1000)!,
      "a sane NR reading is metres, not kilometres — a km-scale answer means an LTE index was passed in",
    ).toBeLessThan(0.5);
  });

  test("the two units are not interchangeable in either direction", () => {
    const lteKm = calculateLteDistance(15)!;
    const nrKm = calculateNrDistance(15)!;
    expect(
      nrKm,
      "15 NTA is a real (very close) reading — 1.14 m — so the two formulas disagree by construction",
    ).toBeCloseTo(0.0011444, 6);
    expect(
      lteKm / nrKm,
      "one LTE index unit (16·Ts) is 1024x one NR NTA unit (Tc); the ratio is the reason the two functions exist separately",
    ).toBeCloseTo(1024, 0);
  });
});
