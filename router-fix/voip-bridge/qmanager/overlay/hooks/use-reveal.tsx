"use client";

// =============================================================================
// use-reveal — one eye per surface, not one per row
// =============================================================================
// Phone numbers and contact names are masked by default (lib/mask.ts). Revealing
// them is a decision about a *screen*, not about a value: a reader who wants to
// see who called wants to see the whole list, and per-row toggles would mean
// clicking five eyes to read one history table.
//
// So the state lives at the surface (Calls page, dashboard dialog) and every
// masked value inside it follows the same eye. It is deliberately NOT persisted:
// a fresh page load is hidden again, so a revealed screen cannot leak into the
// next person who opens the router UI. That is the whole point of the default.
// =============================================================================

import { createContext, useCallback, useContext, useMemo, useState } from "react";
import type { ReactNode } from "react";

interface RevealState {
  revealed: boolean;
  toggle: () => void;
  hide: () => void;
}

const RevealContext = createContext<RevealState | null>(null);

export const RevealProvider = ({ children }: { children: ReactNode }) => {
  const [revealed, setRevealed] = useState(false);
  const toggle = useCallback(() => setRevealed((v) => !v), []);
  const hide = useCallback(() => setRevealed(false), []);
  const value = useMemo(() => ({ revealed, toggle, hide }), [revealed, toggle, hide]);
  return <RevealContext.Provider value={value}>{children}</RevealContext.Provider>;
};

/**
 * Read the surface's reveal state. Outside a provider every value stays masked:
 * a component that forgot to be wrapped must hide, never leak.
 */
export const useReveal = (): RevealState => {
  const ctx = useContext(RevealContext);
  return ctx ?? HIDDEN;
};

const HIDDEN: RevealState = {
  revealed: false,
  toggle: () => {},
  hide: () => {},
};
