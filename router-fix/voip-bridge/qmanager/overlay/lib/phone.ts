// Phone-number helpers shared by the call surfaces.
//
// The device stores contacts in whatever format they were imported in
// ("+92 315 4308207", "0092-315-4308207", "03154308207") and the modem reports
// callers in its own. Comparing the last nine digits is what makes a local-format
// contact resolve an internationally formatted caller id — the same rule the
// bridge uses for its own lookup, restated here so the UI and the device agree.

export function normalizePhone(input: string): string {
  const digits = (input ?? "").replace(/[^0-9]/g, "");
  return digits.length > 9 ? digits.slice(-9) : digits;
}

/** Returns the contact whose number matches, or undefined. */
export function findContact<T extends { phone: string }>(
  contacts: T[],
  number: string
): T | undefined {
  const want = normalizePhone(number);
  if (!want) {
    return undefined;
  }
  return contacts.find((c) => normalizePhone(c.phone) === want);
}

/** "Alice Example" for 03154308207 when Alice is in the book, else the number. */
export function displayName<T extends { phone: string; name: string }>(
  contacts: T[],
  number: string
): string {
  const match = findContact(contacts, number);
  if (match && match.name.trim() !== "") {
    return match.name;
  }
  return number.trim() === "" ? "—" : number;
}
