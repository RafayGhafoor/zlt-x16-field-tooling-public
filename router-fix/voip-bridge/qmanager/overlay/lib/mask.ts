// =============================================================================
// lib/mask.ts — what a number and a name look like before someone asks to see it
// =============================================================================
// The calls page shows who called, and a router in a shared room is not a
// private place. Every identity is therefore hidden by default: a number keeps
// only its last three digits, a contact name keeps only its first letters.
//
// The rule is "shaped, not blank": a masked row must still be scannable as a
// row — the same length, the same digit groups, the same word shapes — because
// a list of five identical `•••••` entries tells the reader nothing, and a
// reader who cannot tell rows apart will just reveal everything and leave it
// revealed. Keeping the tail (`…567`) is what makes an unlabelled row usable
// while ringing.
//
// Nothing here logs, caches or transmits; these are pure string functions so the
// rules can be tested without a browser.
// =============================================================================

/** The single mask character. Bullet U+2022 renders in every font we ship. */
const DOT = "•";

/** Digits kept visible at the end of a number. */
export const NUMBER_TAIL = 3;

/**
 * Hide all but the last three digits of a phone number, preserving its shape.
 *
 * `03001234567`    -> `••••••••567`
 * `+92 300 1234567` -> `••• ••• ••••567`
 * `*123#`          -> `*123#`    (no more digits than the tail: nothing to hide)
 *
 * An already-masked or empty value passes through unchanged, so masking is
 * idempotent and safe to apply twice.
 */
export const maskNumber = (raw: string): string => {
  if (raw === "") {
    return "";
  }
  const visible = new Set<number>();
  let kept = 0;
  for (let i = raw.length - 1; i >= 0 && kept < NUMBER_TAIL; i -= 1) {
    if (/\d/.test(raw[i])) {
      visible.add(i);
      kept += 1;
    }
  }
  let out = "";
  for (let i = 0; i < raw.length; i += 1) {
    const ch = raw[i];
    if (visible.has(i)) {
      out += ch;
    } else if (/\d/.test(ch)) {
      out += DOT;
    } else {
      // Separators (`+`, spaces, `-`, `#`) are kept: they are not secret, and
      // they are what makes the value readable once revealed.
      out += ch;
    }
  }
  return out;
};

/**
 * Hide everything after the first letter of each word.
 *
 * `Ali Khan`  -> `A•• K•••`
 * `Muhammad`  -> `M•••••••`
 *
 * Keeping the initial means "is this the call I am expecting?" is answerable
 * before revealing, and two contacts whose names differ only in their first
 * letter stay distinguishable.
 */
export const maskName = (raw: string): string => {
  if (raw === "") {
    return "";
  }
  return raw
    .split(/(\s+)/)
    .map((part) => {
      if (part === "" || /^\s+$/.test(part)) {
        return part;
      }
      const [first, ...rest] = Array.from(part);
      return first + DOT.repeat(rest.length);
    })
    .join("");
};

/**
 * Mask whatever identity a row is showing: a contact name if the number matched
 * one, otherwise the number itself. This mirrors `displayName()`, so the masked
 * value is never a different person from the revealed one.
 */
export const maskIdentity = (identity: string, isNumber: boolean): string =>
  isNumber ? maskNumber(identity) : maskName(identity);
