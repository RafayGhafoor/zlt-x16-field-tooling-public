// =============================================================================
// lib/ns-pref.ts — the noise-suppression preference, and what "default" means
// =============================================================================
// Suppression is ON by default because that is the operator's decision for this
// deployment: the far end of a cellular call is the one that suffers from an open
// microphone, and they asked for it on.
//
// "Default on" must still be honest in three ways:
//   - an explicit OFF is remembered and wins (`"0"`), so the switch is a switch;
//   - a browser where the worklet cannot run reports that fact instead of
//     silently leaving the operator with a raw microphone (the hook re-requests
//     the microphone with the browser's own suppressor in that case);
//   - the stored value is only ever `"1"` or `"0"`. Anything else — a different
//     app's key, a corrupted value, private-mode restrictions — falls back to the
//     default rather than to a string comparison that quietly says "off".
//
// Kept as a pure function so the rule can be tested without a browser.
// =============================================================================

export const NS_STORAGE_KEY = "x16.ns.enabled";

/** Default when nothing (or nothing usable) is stored. */
export const NS_DEFAULT_ENABLED = true;

/**
 * Interpret a stored preference.
 *
 * `null` (never set)  -> the default (on)
 * `"1"`               -> on
 * `"0"`               -> off  (an explicit decision, and it is respected)
 * anything else       -> the default (on), because it is not a decision
 */
export const parseNsPref = (stored: string | null | undefined): boolean => {
  if (stored === "1") {
    return true;
  }
  if (stored === "0") {
    return false;
  }
  return NS_DEFAULT_ENABLED;
};

/** What to store for a given choice. */
export const nsPrefValue = (enabled: boolean): "1" | "0" => (enabled ? "1" : "0");
