import type { LucideIcon } from "lucide-react";
import { CheckCircle2Icon, CircleSlashIcon, PhoneCallIcon, TriangleAlertIcon } from "lucide-react";

import type { BadgeVariant } from "@/components/ui/badge";
import type { LinkPhase } from "@/hooks/use-call-terminal";
import type { CallStateCode } from "@/types/calls";

// The history/recordings/contacts blocks at the end of this file use BadgeVariant
// for their outcome chips, exactly as the call-state chips do.

// =============================================================================
// Call terminal — shared geometry and tone contract
// =============================================================================
// The `/cellular/calls` family's shapes module. Geometry is restated per family
// rather than imported across siblings — the `/local-network/` families each do
// the same — so this file is the one place the numbers live for these three
// cards, and the skeletons mirror them by reference.
//
// The values are the system's, verbatim:
//
//   40px readout row   42px page action   48px keypad key   16px card
//
// -----------------------------------------------------------------------------
// COLOUR: ONLY THE CALL STATE AND THE LINK STATE MOVE
// -----------------------------------------------------------------------------
// Cards are neutral. Two slots carry a verdict and both are filled status chips
// keyed onto `BadgeVariant`, each with its own glyph — colour alone never carries
// the state on this system (the two container fills sit 1.03:1 apart, i.e.
// identical to the eye under deuteranopia).
//
//   CALL  2 dialing, 3 ringing → warning; 0 answered → success; ended → muted.
//   LINK  live → success; connecting → warning; failed → destructive.
// =============================================================================

/** The route wrapper's layout. `@container/main` is declared at the route root. */
export const PAGE_ROOT = "mx-auto flex flex-col gap-5 p-2";

/** Header: display title, one-sentence description, actions on the right edge. */
export const PAGE_HEAD = {
  ROOT: "flex flex-col gap-5 @3xl/main:flex-row @3xl/main:items-end",
  TITLES: "flex max-w-[41rem] flex-col gap-1.5",
  TITLE: "text-3xl font-bold tracking-[-0.02em]",
  DESC: "text-on-surface-variant text-sm leading-relaxed text-pretty",
  ACTIONS: "flex flex-wrap items-center gap-2.5 @3xl/main:ml-auto",
} as const;

/** The card shell: 16px radius, whisper shadow, no hairline on a tonal surface. */
export const CARD_SHELL =
  "@container/card flex flex-col gap-5 rounded-card border-0 bg-surface py-6 shadow-[var(--shadow-whisper)]!";

/** Card padding: 28px, matching every sibling surface. */
export const CARD_PAD = "px-7";

/** The card's title; `CardTitle` ships only the weight. */
export const CARD_TITLE = "min-w-0 text-lg font-semibold leading-tight";

/** Header layout: titles left, one chip or action group pushed right. */
export const CARD_HEAD = {
  ROOT: "flex flex-wrap items-start gap-x-4 gap-y-3",
  TITLES: "flex min-w-0 flex-col gap-1.5",
  DESC: "text-on-surface-variant text-sm leading-relaxed text-pretty",
  ACTIONS: "flex flex-none items-center gap-2 @lg/card:ml-auto",
} as const;

/** Section label inside a card — the one sanctioned inner-level marker. */
export const SECTION_LABEL =
  "text-on-surface-variant text-[0.6875rem] font-semibold uppercase tracking-[0.06em]";

/** A quiet footnote under a card's content: the sentence that keeps it honest. */
export const FOOTNOTE = "text-on-surface-variant text-[0.8125rem] leading-relaxed";

/** Read-only figures: key on the left, value on the right, 40px pill. */
export const READOUT = {
  GRID: "grid grid-cols-1 gap-1.5 @xl/card:grid-cols-2",
  ROOT: "flex h-10 min-w-0 items-center gap-3 rounded-pill bg-surface-container px-4",
  KEY: "truncate text-[0.8125rem] font-semibold text-on-surface-variant",
  VALUE: "ml-auto flex-none text-[0.8125rem] font-semibold tabular-nums",
  VALUE_MONO:
    "ml-auto min-w-0 truncate font-mono text-[0.75rem] font-semibold tabular-nums",
} as const;

/** A label + control row. The consequence sentence is required, not decoration. */
export const FIELD_ROW = "flex flex-col gap-2.5 @lg/card:flex-row @lg/card:items-center";

/** The number field is typed digits: machine voice, wide enough to read back. */
export const NUMBER_FIELD =
  "font-mono text-lg tracking-[0.06em] tabular-nums h-12 @lg/card:flex-1";

/** The keypad: three columns, 48px keys — a thumb target, not a table. */
export const KEYPAD = {
  GRID: "grid w-full max-w-[17rem] grid-cols-3 gap-2",
  KEY: "h-12 font-mono text-lg font-semibold tabular-nums",
} as const;

/**
 * A level meter. Two bars, one per direction, in the same 8px lane the system
 * uses for progress: the point is a glance ("is sound moving"), not a figure.
 */
export const METER = {
  ROW: "flex flex-col gap-1.5",
  LABEL: "flex items-center justify-between gap-3",
  NAME: "text-on-surface-variant text-[0.8125rem] font-semibold",
  VALUE: "text-on-surface-variant font-mono text-[0.75rem] tabular-nums",
  TRACK: "h-2 w-full overflow-hidden rounded-pill bg-surface-container-high",
  FILL: "h-full rounded-pill transition-[width] duration-100 ease-out",
} as const;

/** The meter fills: the two directions of one conversation, never two hues. */
export const METER_TONE = {
  up: "bg-primary",
  down: "bg-success",
} as const;

/** The resting/notice block: a filled disc, a title, one line, an optional action. */
export const NOTICE = {
  ROOT: "flex flex-col items-center gap-3 rounded-tile bg-surface-container px-6 py-8 text-center",
  DISC: "grid size-14 flex-none place-items-center rounded-pill bg-surface-container-high text-on-surface-variant",
  GLYPH: "size-[1.625rem]",
  TITLE: "text-[0.9375rem] font-semibold",
  BODY: "text-on-surface-variant max-w-[46ch] text-[0.8125rem] leading-relaxed text-pretty",
  ACTION: "mt-1",
} as const;

/** A solid tonal container for an error string, verbatim from the bridge. */
export const ERROR_BOX =
  "flex flex-col gap-1 rounded-field bg-destructive-container px-4 py-3 text-on-destructive-container";
export const ERROR_TEXT = "text-[0.8125rem] leading-relaxed text-pretty break-words";

/** The glyph inside any status chip. Matches the chip's own text step. */
export const CHIP_GLYPH = "size-3";

// -----------------------------------------------------------------------------
// Tone maps
// -----------------------------------------------------------------------------

/**
 * The modem's own call states. `""` is "no call" and takes `muted`: an idle
 * modem is not a fault. States 2 and 3 are the two that mean *the far end is
 * being asked* — the only window in which the user is waiting on someone else —
 * so they are the one warning. State 0 is the only success.
 */
export const CALL_BADGE: Record<CallStateCode, BadgeVariant> = {
  unknown: "warning",
  "": "muted",
  "0": "success",
  "1": "info",
  "2": "warning",
  "3": "warning",
  "4": "info",
  "5": "info",
};

export const CALL_GLYPH: Record<CallStateCode, LucideIcon> = {
  "": CircleSlashIcon,
  unknown: TriangleAlertIcon,
  "0": PhoneCallIcon,
  "1": PhoneCallIcon,
  "2": PhoneCallIcon,
  "3": PhoneCallIcon,
  "4": PhoneCallIcon,
  "5": PhoneCallIcon,
};

/**
 * The browser↔bridge link. `failed` is the only destructive state; `connecting`
 * is a warning because it is a wait, not a fault; `idle` is muted because a user
 * who has not pressed Connect has not failed at anything.
 */
export const LINK_BADGE: Record<LinkPhase, BadgeVariant> = {
  idle: "muted",
  connecting: "warning",
  live: "success",
  failed: "destructive",
};

export const LINK_GLYPH: Record<LinkPhase, LucideIcon> = {
  idle: CircleSlashIcon,
  connecting: PhoneCallIcon,
  live: CheckCircle2Icon,
  failed: TriangleAlertIcon,
};

// -----------------------------------------------------------------------------
// Recordings, history and contacts
// -----------------------------------------------------------------------------
// Three list surfaces added with the call-log feature. They share one row
// geometry so a call, a recording and a contact read as the same kind of object
// at a glance — the thing that differs is the trailing action, not the row.

/** One row of a list: label + meta on the left, actions on the right. */
export const RECORDING_ROW = {
  ROOT: "flex items-center gap-2 rounded-tile bg-surface-container px-4 py-3",
  TEXT: "flex min-w-0 flex-1 flex-col gap-0.5",
  NAME: "truncate text-[0.9375rem] font-semibold",
  META: "text-on-surface-variant truncate text-[0.75rem] tabular-nums",
} as const;

/** The history table reuses the system's hairline-row density. */
export const TABLE = { ROOT: "w-full border-collapse text-left" } as const;

/**
 * The call-log table.
 *
 * Alignment rules, because the previous version drifted:
 *   - every column owns a FIXED width and every cell in it repeats it, so the
 *     header and the body cannot disagree about where a column ends;
 *   - the who column starts with a direction glyph, so its header carries the
 *     same inset (`pl-6` = 1rem glyph + 0.5rem gap) instead of sitting 24px left
 *     of the names it labels;
 *   - numbers and durations are right-aligned, chips are left-aligned, and the
 *     redial column is a fixed 3.5rem that exactly fits the icon button.
 */
export const HISTORY = {
  TABLE: "w-full table-fixed border-collapse text-left",
  HEAD: "text-on-surface-variant pb-2 text-[0.6875rem] font-semibold uppercase tracking-[0.06em] align-bottom",
  ROW: "border-t border-border",
  CELL: "py-2.5 align-middle text-[0.8125rem]",
  NAME: "block truncate font-semibold",
  SUB: "text-on-surface-variant block truncate font-mono text-[0.6875rem] tabular-nums",
  NUM: "whitespace-nowrap text-[0.8125rem] font-semibold tabular-nums",
  COLS: {
    /** 1.5rem for the direction glyph + its gap, so the header lines up. */
    WHO_INSET: "pl-6",
    TIME: "w-[9rem] whitespace-nowrap",
    DIR: "w-[6.5rem] whitespace-nowrap",
    LEN: "w-[5.5rem] whitespace-nowrap text-right",
    OUT: "w-[8.5rem] whitespace-nowrap",
    ACT: "w-[3.5rem] whitespace-nowrap text-right",
  },
} as const;

/** Direction and outcome chips: a glyph always, colour never alone. */
export const OUTCOME_BADGE: Record<string, BadgeVariant> = {
  answered: "success",
  no_answer: "warning",
  missed: "destructive",
  failed: "destructive",
};

/** The contacts list keeps the same row box as a recording. */
export const CONTACT_ROW = RECORDING_ROW;

/** The import control: a file picker styled as a quiet action. */
export const IMPORT_ROW = "flex flex-wrap items-center gap-2.5";
