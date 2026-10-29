"use client";

import { useState } from "react";
import { useCallback } from "react";
import { useTranslation } from "react-i18next";
import {
  DeleteIcon,
  MicIcon,
  MicOffIcon,
  PhoneCallIcon,
  PhoneIcon,
  PhoneOffIcon,
  Volume2Icon,
} from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Kbd } from "@/components/ui/kbd";
import type { CallTerminal } from "@/hooks/use-call-terminal";
import { useDialKeys } from "@/hooks/use-dial-keys";
import { cn } from "@/lib/utils";

import {
  CARD_HEAD,
  CARD_PAD,
  CARD_SHELL,
  CARD_TITLE,
  CALL_BADGE,
  CALL_GLYPH,
  CHIP_GLYPH,
  FIELD_ROW,
  KEYPAD,
  NUMBER_FIELD,
  SECTION_LABEL,
} from "./shapes";

// =============================================================================
// DialerCard — place the call, end the call, and touch-tone during it
// =============================================================================
// The dial path is the vendor's own: the bridge runs `ATD<number>;` through
// /bin/atcmd, exactly as the reference script did, because that is what this
// modem accepts. The call state that comes back is the modem's (AT+CLCC), so the
// chip here is a report, not an intention — "ringing" means the far end's phone
// is ringing, not that we asked it to.
//
// -----------------------------------------------------------------------------
// WHY CALL AND HANG UP ARE SEPARATE CONTROLS, NOT ONE TOGGLE
// -----------------------------------------------------------------------------
// Dial and ATH are different commands with different failure modes, and the two
// states they leave the modem in are not symmetric: a dial can be rejected
// (busy, barred, no service) while a hang-up essentially cannot. One switch would
// have to guess which of the two the user meant from a state that lags reality by
// up to a second.
//
// -----------------------------------------------------------------------------
// DTMF IS OFFERED DURING A CALL ONLY
// -----------------------------------------------------------------------------
// `AT+VTS` outside an active call is rejected by this modem, so the keypad is
// disabled rather than left to produce errors. The keypad also types into the
// number field while idle — typing a destination and pressing a tone key are the
// same gesture to a user, and only the call state decides which one happens.
// =============================================================================

const K = "calls";
const KEYS = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"] as const;

interface DialerCardProps {
  terminal: CallTerminal;
}

const DialerCard = ({ terminal }: DialerCardProps) => {
  const { t } = useTranslation("common");
  const [number, setNumber] = useState("");
  // Without /callapi there is no dial either — the AT command is issued by the
  // bridge, not by QManager's CGI. Say it once instead of letting the button
  // fail with a bare HTTP code.
  const reachable = terminal.available;
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);

  const call = terminal.state?.call ?? "";
  const inCall = call !== "";
  const answered = call === "0";
  const CallGlyph = CALL_GLYPH[call];
  const label = terminal.state?.call_label ?? "idle";

  const dial = async () => {
    if (number.trim() === "") {
      return;
    }
    setBusy(true);
    setNote(null);
    const res = await terminal.dial(number.trim());
    setBusy(false);
    setNote(res.ok ? null : (res.error ?? res.at ?? "dial failed"));
  };

  const hangup = async () => {
    setBusy(true);
    const res = await terminal.hangup();
    setBusy(false);
    setNote(res.ok ? null : (res.error ?? "hang-up failed"));
  };

  const press = async (key: string) => {
    if (answered) {
      const res = await terminal.sendDtmf(key);
      setNote(res.ok ? null : (res.error ?? res.at ?? null));
      return;
    }
    setNumber((n) => (n.length < 20 ? n + key : n));
  };

  // The number input works, but only once it has focus; this makes the keyboard
  // work the moment the page is open, and stays out of the way of every real
  // field on the page (the input itself included).
  useDialKeys({
    onDigit: (digit) => void press(digit),
    onBackspace: () => setNumber((n) => n.slice(0, -1)),
    onDial: () => {
      if (!inCall && number.trim() !== "") {
        void dial();
      }
    },
  });

  return (
    <Card className={cn(CARD_SHELL, CARD_PAD)}>
      <CardHeader className={CARD_HEAD.ROOT}>
        <div className={CARD_HEAD.TITLES}>
          <CardTitle className={CARD_TITLE}>{t(`${K}.dialer.title`)}</CardTitle>
          <p className={CARD_HEAD.DESC}>{t(`${K}.dialer.description`)}</p>
        </div>
        <div className={CARD_HEAD.ACTIONS}>
          <Badge variant={CALL_BADGE[call]}>
            <CallGlyph className={CHIP_GLYPH} aria-hidden="true" />
            {t(`${K}.call_state.${label}`)}
          </Badge>
        </div>
      </CardHeader>

      <CardContent className="flex flex-col gap-5 px-0">
        <div className={FIELD_ROW}>
          <Input
            className={NUMBER_FIELD}
            value={number}
            inputMode="tel"
            autoComplete="off"
            spellCheck={false}
            placeholder={t(`${K}.dialer.placeholder`)}
            aria-label={t(`${K}.dialer.placeholder`)}
            onChange={(e) => setNumber(e.target.value.replace(/[^0-9*#+]/g, ""))}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                void dial();
              }
            }}
            disabled={inCall}
          />
          <div className="flex flex-none items-center gap-2">
            <Button
              type="button"
              variant="default"
              size="action"
              onClick={() => {
                void dial();
              }}
              disabled={!reachable || inCall || busy || number.trim() === ""}
            >
              <PhoneCallIcon className="size-4" />
              {t(`${K}.dialer.call`)}
            </Button>
            <Button
              type="button"
              variant="tonal-destructive"
              size="action"
              onClick={() => {
                void hangup();
              }}
              disabled={!reachable || !inCall || busy}
            >
              <PhoneOffIcon className="size-4" />
              {t(`${K}.dialer.hangup`)}
            </Button>
            <Button
              type="button"
              variant={terminal.outputRoute === "speakerphone" ? "tonal" : "tonal-neutral"}
              size="action"
              onClick={() => void terminal.switchOutputRoute()}
              disabled={!terminal.canRouteOutput}
              title={
                terminal.outputRouteSupported
                  ? t(`${K}.dialer.route_hint`)
                  : t(`${K}.dialer.route_unavailable`)
              }
              aria-pressed={terminal.outputRoute === "speakerphone"}
            >
              {terminal.outputRoute === "speakerphone" ? (
                <Volume2Icon className="size-4" />
              ) : (
                <PhoneIcon className="size-4" />
              )}
              {terminal.outputRoute === "speakerphone"
                ? t(`${K}.dialer.speakerphone`)
                : t(`${K}.dialer.handset`)}
            </Button>
            {/* Mute lives with Call and Hang up because that is where a hand goes
                mid-sentence, and it is ALWAYS in the row — disabled with the
                reason in its tooltip rather than hidden. A control that only
                appears once the audio link is live reads as a missing feature on
                a freshly loaded page, which is exactly how it was reported. */}
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
                  ? t(`${K}.dialer.mute_hint`)
                  : terminal.phase === "live"
                    ? t(`${K}.dialer.mute_unavailable`)
                    : t(`${K}.dialer.mute_connect_first`)
              }
            >
              {terminal.muted ? (
                <MicOffIcon className="size-4" />
              ) : (
                <MicIcon className="size-4" />
              )}
              {terminal.muted ? t(`${K}.dialer.unmute`) : t(`${K}.dialer.mute`)}
              <Kbd className="ml-1 hidden @xl/card:inline-flex">M</Kbd>
            </Button>
          </div>
        </div>

        {!reachable ? (
          <p className="text-on-surface-variant text-[0.8125rem] leading-relaxed">
            {t(`${K}.blocker.no-service.title`)}
          </p>
        ) : null}

        {note ? (
          <p className="text-destructive text-[0.8125rem] leading-relaxed">{note}</p>
        ) : null}

        <div className="flex flex-col gap-2.5">
          <span className={SECTION_LABEL}>
            {answered ? t(`${K}.dialer.dtmf_live`) : t(`${K}.dialer.dtmf_idle`)}
          </span>
          <div className={KEYPAD.GRID}>
            {KEYS.map((key) => (
              <Button
                key={key}
                type="button"
                variant="tonal-neutral"
                className={KEYPAD.KEY}
                onClick={() => {
                  void press(key);
                }}
                disabled={inCall && !answered}
              >
                {key}
              </Button>
            ))}
          </div>
          <div className="flex items-center gap-2">
            <Button
              type="button"
              variant="tonal-neutral"
              size="action"
              onClick={() => setNumber((n) => n.slice(0, -1))}
              disabled={inCall || number === ""}
            >
              <DeleteIcon className="size-4" />
              {t(`${K}.dialer.backspace`)}
            </Button>
            <span className={SECTION_LABEL}>
              {inCall ? t(`${K}.dialer.state`, { state: label }) : t(`${K}.dialer.idle_hint`)}
            </span>
          </div>
        </div>
      </CardContent>
    </Card>
  );
};

export default DialerCard;
