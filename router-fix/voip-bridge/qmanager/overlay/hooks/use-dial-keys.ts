"use client";

import { useEffect } from "react";

// =============================================================================
// useDialKeys — type on a phone pad without aiming at a field
// =============================================================================
// Two surfaces need this and for the same reason: a dialler is used with the
// keyboard the way a telephone is used with fingers. Requiring a click into a
// text field first is what made "typing does not work" the reported behaviour —
// the field exists on the calls page but has no focus on load, and the dashboard
// popup has no field at all (its number is a read-back line, deliberately, so the
// digits can be typeset large and tabular).
//
// The guard list is the important part, not the mapping: typing must be ignored
// while a real field has focus. On the calls page the contacts card, the number
// input and QManager's own searches are all inputs, and a global digit handler
// that fires over them would turn "type a contact's name" into a phone call.
//
// M (mute) is NOT here — it belongs to the terminal, which knows whether a
// microphone exists, and lives in use-call-terminal so both surfaces share it.
// =============================================================================

const DIALABLE = "0123456789*#+";

export interface DialKeyHandlers {
  /** Switch the handler off entirely (e.g. the dialog is closed). */
  enabled?: boolean;
  onDigit: (digit: string) => void;
  onBackspace: () => void;
  onDial: () => void;
}

export function useDialKeys({ enabled = true, onDigit, onBackspace, onDial }: DialKeyHandlers) {
  useEffect(() => {
    if (!enabled) {
      return;
    }

    const onKeyDown = (event: KeyboardEvent) => {
      // Leave every browser/OS shortcut alone.
      if (event.metaKey || event.ctrlKey || event.altKey) {
        return;
      }

      // Never steal a keystroke from a field the user is actually typing into.
      const el = event.target as HTMLElement | null;
      const tag = el?.tagName;
      if (
        tag === "INPUT" ||
        tag === "TEXTAREA" ||
        tag === "SELECT" ||
        el?.isContentEditable
      ) {
        return;
      }

      if (event.key.length === 1 && DIALABLE.includes(event.key)) {
        event.preventDefault();
        onDigit(event.key);
        return;
      }
      if (event.key === "Backspace") {
        event.preventDefault();
        onBackspace();
        return;
      }
      if (event.key === "Enter") {
        event.preventDefault();
        onDial();
      }
    };

    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [enabled, onDigit, onBackspace, onDial]);
}

export default useDialKeys;
