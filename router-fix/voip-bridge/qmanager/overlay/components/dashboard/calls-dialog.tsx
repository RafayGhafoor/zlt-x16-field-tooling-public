"use client";

import { useCallback, useState } from "react";
import { useTranslation } from "react-i18next";
import {
  DeleteIcon,
  MicIcon,
  MicOffIcon,
  PhoneCallIcon,
  PhoneIcon,
  PhoneIncomingIcon,
  PhoneOffIcon,
  Volume2Icon,
} from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Kbd } from "@/components/ui/kbd";
import MaskedText from "@/components/masked-text";
import RevealToggle from "@/components/reveal-toggle";
import { useCallTerminal } from "@/hooks/use-call-terminal";

import { useDialKeys } from "@/hooks/use-dial-keys";
import { displayName } from "@/lib/phone";
import { cn } from "@/lib/utils";

import { CALL_METER, CALL_METER_TONE, CALL_NOTE, CALL_SHEET } from "./shapes";

// =============================================================================
// CallsDialog — the dialler, behind a phone icon in the page header
// =============================================================================
// The dashboard is a reading surface. A permanent dialler card took a whole band
// of it to serve an action that is used for seconds at a time, so the dialler
// moved into a popup that opens from the header — and the band went back to the
// cards that are actually read.
//
// -----------------------------------------------------------------------------
// WHAT STAYS OUTSIDE THE POPUP: THE TRIGGER'S OWN STATE
// -----------------------------------------------------------------------------
// `useCallTerminal` is mounted HERE, not inside the dialog, because the icon has
// to tell the truth while the popup is closed: a badge shows an active call, a
// ringing badge shows an incoming one, and the ring itself is the `pulse` on the
// trigger. That costs nothing extra — the hook already polls once a second, and
// it is the only thing on this page that talks to the call API.
//
// The dialog is the system's own `DialogContent` (fade + zoom on the measured
// durations), so the motion is inherited rather than invented.
// =============================================================================

const K = "calls_card";

/** A real keypad's letter groups, so the pad reads as a phone and not a grid. */
const KEYS: { digit: string; letters: string }[] = [
  { digit: "1", letters: "" },
  { digit: "2", letters: "ABC" },
  { digit: "3", letters: "DEF" },
  { digit: "4", letters: "GHI" },
  { digit: "5", letters: "JKL" },
  { digit: "6", letters: "MNO" },
  { digit: "7", letters: "PQRS" },
  { digit: "8", letters: "TUV" },
  { digit: "9", letters: "WXYZ" },
  { digit: "*", letters: "" },
  { digit: "0", letters: "+" },
  { digit: "#", letters: "" },
];

const CallsDialog = () => {
  const { t } = useTranslation("dashboard");
  const [number, setNumber] = useState("");
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  // Opening the phone popup is the user's intent to use it: ask for the mic at
  // that moment, not on dashboard load. Once granted by the browser the saved
  // site permission is reused on later openings without a second prompt.
  const terminal = useCallTerminal({ autoConnect: open });

  // The dialog is the other surface that shows numbers, so it owns its own eye.
  const [revealed, setRevealed] = useState(false);
  const call = terminal.state?.call ?? "";
  const inCall = call !== "";
  const answered = call === "0";
  const incoming = call === "4";
  const label = terminal.state?.call_label ?? "idle";
  const reachable = terminal.available;

  const activeNumber =
    terminal.state?.call_number || terminal.state?.number || number;
  const who = displayName(terminal.contacts, activeNumber);

  const upPct = Math.min(100, Math.round(terminal.levels.up * 100));
  const downPct = Math.min(100, Math.round(terminal.levels.down * 100));

  const dial = async () => {
    if (number.trim() === "") {
      return;
    }
    setBusy(true);
    setNote(null);
    const res = await terminal.dial(number.trim());
    setBusy(false);
    if (!res.ok) {
      setNote(res.error ?? res.at ?? "dial failed");
    }
  };

  const hangup = async () => {
    setBusy(true);
    const res = await terminal.hangup();
    setBusy(false);
    if (!res.ok) {
      setNote(res.error ?? "hang-up failed");
    }
  };

  const press = useCallback(
    async (digit: string) => {
      if (answered) {
        const res = await terminal.sendDtmf(digit);
        if (!res.ok) {
          setNote(res.error ?? res.at ?? null);
        }
        return;
      }
      setNumber((n) => (n.length < 20 ? n + digit : n));
    },
    [answered, terminal]
  );

  const backspace = useCallback(() => setNumber((n) => n.slice(0, -1)), []);

  // Typing works without clicking anything, but only while this popup is open —
  // otherwise the dashboard's other inputs would feed the dialler.
  useDialKeys({
    enabled: open,
    onDigit: (digit) => void press(digit),
    onBackspace: backspace,
    onDial: () => void dial(),
  });

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button
          type="button"
          variant={inCall ? "default" : "tonal-neutral"}
          size="icon"
          className="relative"
          aria-label={t(`${K}.open`)}
          title={t(`${K}.open`)}
        >
          {incoming ? (
            <PhoneIncomingIcon className="size-4 animate-pulse" />
          ) : (
            <PhoneIcon className="size-4" />
          )}
          {/* A dot, not a chip: the header is a row of status already, and the
              icon only has to say "something is on this line". */}
          {inCall ? (
            <span
              className={cn(
                "absolute -top-0.5 -right-0.5 size-2.5 rounded-full ring-2 ring-surface",
                incoming ? "bg-warning animate-pulse" : "bg-success"
              )}
            />
          ) : null}
        </Button>
      </DialogTrigger>

      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            {t(`${K}.title`)}
            <Badge
              variant={
                label === "active" || label === "ended"
                  ? label === "active"
                    ? "success"
                    : "muted"
                  : label === "incoming"
                    ? "info"
                    : label === "idle"
                      ? "muted"
                      : "warning"
              }
            >
              {label === "incoming" || label === "ringing" ? (
                <PhoneIncomingIcon className="size-3" aria-hidden="true" />
              ) : (
                <PhoneCallIcon className="size-3" aria-hidden="true" />
              )}
              {t(`${K}.state.${label}`)}
            </Badge>
            {(terminal.state?.peers ?? 0) > 0 ? (
              <Badge variant="muted">
                {t(`${K}.joined_devices`, { count: terminal.state?.peers ?? 0 })}
              </Badge>
            ) : null}
          </DialogTitle>
          <DialogDescription>{t(`${K}.description`)}</DialogDescription>
        </DialogHeader>

        <div className="flex justify-end">
          <RevealToggle
            revealed={revealed}
            onToggle={() => setRevealed((v) => !v)}
          />
        </div>

        {incoming ? (
          <div className="flex flex-wrap items-center gap-2.5 rounded-tile bg-primary-container px-4 py-3 text-on-primary-container">
            <PhoneIncomingIcon className="size-5 flex-none" aria-hidden="true" />
            <div className="flex min-w-0 flex-1 flex-col">
              <span className="text-[0.6875rem] font-semibold uppercase tracking-[0.06em]">
                {t(`${K}.incoming`)}
              </span>
              <MaskedText
                className="truncate text-[0.9375rem] font-semibold"
                value={who}
                number={who === activeNumber}
                revealed={revealed}
              />
            </div>
            <Button type="button" variant="default" size="action" onClick={() => void terminal.answer()}>
              <PhoneCallIcon className="size-4" />
              {t(`${K}.answer`)}
            </Button>
            <Button
              type="button"
              variant="tonal-destructive"
              size="action"
              onClick={() => void terminal.reject()}
            >
              <PhoneOffIcon className="size-4" />
              {t(`${K}.reject`)}
            </Button>
          </div>
        ) : null}

        {/* The number: this is the one line the user reads back before dialling,
            so it is the largest type in the popup and in the machine voice. */}
        <div className={CALL_SHEET.DISPLAY}>
          <span
            className={cn(
              "truncate font-mono text-2xl tabular-nums tracking-[0.08em]",
              activeNumber === "" && "text-on-surface-variant"
            )}
          >
            {activeNumber === "" ? (
              t(`${K}.placeholder`)
            ) : (
              <MaskedText
                value={activeNumber}
                number={who === activeNumber}
                revealed={revealed}
              />
            )}
          </span>
          {answered ? (
            <Button
              type="button"
              variant="tonal-neutral"
              size="icon-sm"
              aria-label={t(`${K}.backspace`)}
              onClick={() => void terminal.sendDtmf("#")}
              className="opacity-0 pointer-events-none"
              tabIndex={-1}
            >
              <DeleteIcon className="size-4" />
            </Button>
          ) : (
            <Button
              type="button"
              variant="tonal-neutral"
              size="icon-sm"
              aria-label={t(`${K}.backspace`)}
              onClick={backspace}
              disabled={inCall || number === ""}
            >
              <DeleteIcon className="size-4" />
            </Button>
          )}
        </div>

        {!inCall ? (
          <div className={CALL_SHEET.KEYPAD}>
            {KEYS.map((k) => (
              <button
                key={k.digit}
                type="button"
                onClick={() => void press(k.digit)}
                className={CALL_SHEET.KEY}
              >
                <span className="font-mono text-xl leading-none tabular-nums">
                  {k.digit}
                </span>
                {k.letters ? (
                  <span className="text-on-surface-variant text-[0.625rem] leading-none tracking-[0.14em]">
                    {k.letters}
                  </span>
                ) : null}
              </button>
            ))}
          </div>
        ) : (
          <div className="grid grid-cols-6 gap-1.5">
            {KEYS.map((k) => (
              <Button
                key={k.digit}
                type="button"
                variant="tonal-neutral"
                size="sm"
                className="font-mono tabular-nums"
                onClick={() => void press(k.digit)}
                disabled={!answered}
              >
                {k.digit}
              </Button>
            ))}
          </div>
        )}

        <div className="flex flex-wrap items-center gap-2">
          <Button
            type="button"
            variant="default"
            size="action"
            className="flex-1"
            onClick={() => void dial()}
            disabled={!reachable || inCall || busy || number.trim() === ""}
          >
            <PhoneCallIcon className="size-4" />
            {t(`${K}.call`)}
          </Button>
          <Button
            type="button"
            variant="tonal-destructive"
            size="action"
            onClick={() => void hangup()}
            disabled={!reachable || !inCall || busy}
          >
            <PhoneOffIcon className="size-4" />
            {t(`${K}.hangup`)}
          </Button>
          <Button
            type="button"
            variant={terminal.outputRoute === "speakerphone" ? "tonal" : "tonal-neutral"}
            size="action"
            onClick={() => void terminal.switchOutputRoute()}
            disabled={!terminal.canRouteOutput}
            aria-pressed={terminal.outputRoute === "speakerphone"}
            title={
              terminal.outputRouteSupported
                ? t(`${K}.route_hint`)
                : t(`${K}.route_unavailable`)
            }
          >
            {terminal.outputRoute === "speakerphone" ? (
              <Volume2Icon className="size-4" />
            ) : (
              <PhoneIcon className="size-4" />
            )}
            {terminal.outputRoute === "speakerphone"
              ? t(`${K}.speakerphone`)
              : t(`${K}.handset`)}
          </Button>
          <Button
            type="button"
            variant={terminal.muted ? "tonal-destructive" : "tonal-neutral"}
            size="action"
            onClick={terminal.toggleMute}
            disabled={!terminal.canMute}
            aria-pressed={terminal.muted}
            aria-keyshortcuts="M"
            title={
              terminal.canMute
                ? t(`${K}.mute_hint`)
                : terminal.phase === "live"
                  ? t(`${K}.mute_unavailable`)
                  : t(`${K}.mute_connect_first`)
            }
          >
            {terminal.muted ? (
              <MicOffIcon className="size-4" />
            ) : (
              <MicIcon className="size-4" />
            )}
            {terminal.muted ? t(`${K}.unmute`) : t(`${K}.mute`)}
            <Kbd className="ml-1 hidden @sm/card:inline-flex">M</Kbd>
          </Button>
        </div>

        {/* Audio link: two lanes, because "connected" only proves the SDP moved. */}
        <div className="flex flex-wrap items-end gap-4">
          <div className={CALL_METER.ROOT}>
            <div className={CALL_METER.LABEL}>
              <span className={CALL_METER.NAME}>{t(`${K}.meters.up`)}</span>
              <span className={CALL_METER.VALUE}>{upPct}%</span>
            </div>
            <div className={CALL_METER.TRACK}>
              <div
                className={cn(CALL_METER.FILL, CALL_METER_TONE.up)}
                style={{ width: `${upPct}%` }}
              />
            </div>
          </div>
          <div className={CALL_METER.ROOT}>
            <div className={CALL_METER.LABEL}>
              <span className={CALL_METER.NAME}>{t(`${K}.meters.down`)}</span>
              <span className={CALL_METER.VALUE}>{downPct}%</span>
            </div>
            <div className={CALL_METER.TRACK}>
              <div
                className={cn(CALL_METER.FILL, CALL_METER_TONE.down)}
                style={{ width: `${downPct}%` }}
              />
            </div>
          </div>
          <Button
            type="button"
            variant={terminal.phase === "live" ? "tonal-neutral" : "tonal"}
            size="sm"
            onClick={() =>
              terminal.phase === "live" ? terminal.disconnect() : void terminal.connect()
            }
            disabled={!reachable || terminal.phase === "connecting"}
          >
            {terminal.phase === "live"
              ? t(`${K}.audio.disconnect`)
              : t(`${K}.audio.connect`)}
          </Button>
        </div>

        {note ? (
          <p className="text-destructive text-[0.8125rem] leading-relaxed">{note}</p>
        ) : null}

        <p className="text-on-surface-variant text-[0.6875rem]">
          {t(`${K}.keys_hint`)}
        </p>

        <p className={CALL_NOTE}>
          {!reachable
            ? t(`${K}.note.no_service`)
            : !terminal.speak
              ? t(`${K}.note.listen_only`, {
                  url: `https://${window.location.hostname}:8444${window.location.pathname}`,
                })
              : terminal.micError
                ? t(`${K}.note.mic_blocked`)
                : inCall
                  ? t(`${K}.note.in_call`, { state: label, who })
                  : t(`${K}.note.ready`)}
        </p>
      </DialogContent>
    </Dialog>
  );
};

export default CallsDialog;
