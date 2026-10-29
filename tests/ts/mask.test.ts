// =============================================================================
// tests/ts/mask.test.ts — what a phone number and a contact name look like hidden
// =============================================================================
// Run with:  sh tests/ts/run-ts-tests.sh
//        or: cd <qmanager> && bun test <this file>
//
// Under test: lib/mask.ts
//
// The rules exist because the Calls page sits in a shared room: numbers are
// masked by default and one eye reveals them. A mask that is wrong in either
// direction is a real problem — too little and the page leaks, too much and the
// reader cannot tell two rows apart and simply leaves everything revealed.
// =============================================================================

import { describe, expect, test } from "bun:test";

// Loaded by path, not by the `@/` alias: these suites run from the QManager tree
// but live in this repo, and only files under that tree resolve the alias.
const QM_ROOT = (
  process.env.QM_ROOT ?? `${import.meta.dir}/../../../greenpacket-o5a-qmanager`
).replace(/\/+$/, "");

interface MaskFns {
  maskNumber(raw: string): string;
  maskName(raw: string): string;
  maskIdentity(identity: string, isNumber: boolean): string;
}

let mask: MaskFns;
try {
  mask = (await import(`${QM_ROOT}/lib/mask.ts`)) as MaskFns;
} catch (err) {
  throw new Error(
    `cannot load ${QM_ROOT}/lib/mask.ts — set QM_ROOT to the QManager checkout (${(err as Error).message})`,
  );
}

const { maskNumber, maskName, maskIdentity } = mask;

describe("number masking", () => {
  test("keeps the last three digits and masks the rest, preserving the shape", () => {
    expect(maskNumber("03001234567")).toBe("••••••••567");
  });

  test("separators survive: a formatted number stays readable once revealed", () => {
    expect(maskNumber("+92 300 1234567")).toBe("+•• ••• ••••567");
    expect(maskNumber("0300-1234567")).toBe("••••-••••567");
  });

  test("a value with no more digits than the tail is shown as-is", () => {
    // `*123#` is a service code, not a number: three digits cannot be both
    // "hidden except the last three" and useful, so nothing is hidden.
    expect(maskNumber("*123#")).toBe("*123#");
    expect(maskNumber("112")).toBe("112");
  });

  test("an empty value stays empty rather than becoming bullets", () => {
    expect(maskNumber("")).toBe("");
  });

  test("masking is idempotent: masking twice equals masking once", () => {
    const once = maskNumber("03001234567");
    expect(maskNumber(once)).toBe(once);
  });

  test("a number shorter than the tail is shown in full — nothing to hide", () => {
    expect(maskNumber("12")).toBe("12");
    expect(maskNumber("123")).toBe("123");
  });

  test("the tail is digits, never a separator", () => {
    // If a dash were counted as one of the three visible characters, "0300-1234"
    // would end up showing "-34" and hiding a digit it should have shown.
    expect(maskNumber("0300-1234").endsWith("234")).toBe(true);
  });
});

describe("name masking", () => {
  test("keeps the initial of every word and masks the rest", () => {
    expect(maskName("Ali Khan")).toBe("A•• K•••");
  });

  test("word count and spacing are preserved, so rows stay distinguishable", () => {
    const masked = maskName("Muhammad Ali Khan");
    expect(masked.split(" ").length).toBe(3);
    expect(masked).toBe("M••••••• A•• K•••");
  });

  test("an accented or non-latin initial is kept as one character", () => {
    expect(maskName("Élodie")).toBe("É•••••");
    expect(maskName("张三")).toBe("张•");
  });

  test("an empty name stays empty", () => {
    expect(maskName("")).toBe("");
  });

  test("repeated spaces do not collapse, so columns do not shift", () => {
    expect(maskName("Ali  Khan")).toBe("A••  K•••");
  });
});

describe("maskIdentity", () => {
  test("a resolved contact hides a NAME, an unknown caller hides a NUMBER", () => {
    expect(maskIdentity("Ali Khan", false)).toBe("A•• K•••");
    expect(maskIdentity("03001234567", true)).toBe("••••••••567");
  });
});
