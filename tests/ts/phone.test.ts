// =============================================================================
// tests/ts/phone.test.ts — shared phone-number matching for the call log/book
// =============================================================================
// Run with: sh tests/ts/run-ts-tests.sh
//
// The bridge's contact book is stored in the user's imported format; modem CLCC
// may report a local number and a vCard may contain the international form. The
// whole UX feature (names in the log, name on an incoming call, one contact rather
// than duplicates) depends on the last-nine-digit rule agreeing across Go and TS.
// This pins the browser half to the device's tested Go behavior.
// =============================================================================

const QM_ROOT = (
  process.env.QM_ROOT ?? `${import.meta.dir}/../../../greenpacket-o5a-qmanager`
).replace(/\/+$/, "");

interface PhoneFns {
  normalizePhone(input: string): string;
  findContact<T extends { phone: string }>(contacts: T[], number: string): T | undefined;
  displayName<T extends { phone: string; name: string }>(contacts: T[], number: string): string;
}

let phone: PhoneFns;
try {
  phone = (await import(`${QM_ROOT}/lib/phone.ts`)) as PhoneFns;
} catch (err) {
  throw new Error(
    `cannot load ${QM_ROOT}/lib/phone.ts — set QM_ROOT to the QManager checkout (${(err as Error).message})`,
  );
}

const CONTACTS = [
  { name: "Test Person", phone: "03154308207", email: "test@example.test" },
  { name: "Other", phone: "+1 (415) 555-0199", email: "" },
];

describe("phone normalization", () => {
  test("local, international, and 00-prefixed forms match on the last nine digits", () => {
    const expected = "154308207";
    expect(phone.normalizePhone("03154308207")).toBe(expected);
    expect(phone.normalizePhone("+92 315 4308207")).toBe(expected);
    expect(phone.normalizePhone("0092-315-4308207")).toBe(expected);
  });

  test("a call-log number resolves to the imported contact name", () => {
    expect(phone.displayName(CONTACTS, "+92 315 4308207")).toBe("Test Person");
    expect(phone.displayName(CONTACTS, "03154308207")).toBe("Test Person");
  });

  test("unknown and empty numbers remain honest", () => {
    expect(phone.displayName(CONTACTS, "03000000000")).toBe("03000000000");
    expect(phone.displayName(CONTACTS, "")).toBe("—");
    expect(phone.findContact(CONTACTS, "")).toBeUndefined();
  });
});
