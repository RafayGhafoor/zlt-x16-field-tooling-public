"use client";

import { useTranslation } from "react-i18next";
import {
  CheckCircle2Icon,
  CircleSlashIcon,
  SparklesIcon,
  MicIcon,
  MicOffIcon,
  PhoneCallIcon,
  RefreshCcwIcon,
  TriangleAlertIcon,
} from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import type { CallTerminal } from "@/hooks/use-call-terminal";
import { cn } from "@/lib/utils";

import {
  CARD_HEAD,
  CARD_PAD,
  CARD_SHELL,
  CARD_TITLE,
  CHIP_GLYPH,
  LINK_BADGE,
  LINK_GLYPH,
  METER,
  METER_TONE,
  NOTICE,
  SECTION_LABEL,
} from "./shapes";

// =============================================================================
// AudioCard — the browser↔device audio link, and the two meters that prove it
// =============================================================================
// This card owns the one control the page cannot work without: Connect. It is a
// real WebRTC peer (PCMU/8 kHz) between this browser and the bridge.
//
// -----------------------------------------------------------------------------
// LISTENING AND SPEAKING ARE DIFFERENT CAPABILITIES
// -----------------------------------------------------------------------------
// The link opens from any origin. What changes with the origin is the
// microphone: `getUserMedia` does not exist outside a secure context, so on
// http:// there is no permission prompt to grant — the API is absent. Rather than
// hide the card behind that fact, the card connects receive-only and says, in the
// one place the user is looking, that speaking needs the HTTPS front
// (:8444, certificate installable once from /ca.crt).
//
// A connected chip only proves the SDP was exchanged. Sound moving in both lanes
// is the only thing that proves the call carries audio, which is why the meters
// read live analysers rather than the bridge's counters.
// =============================================================================

const K = "calls";

interface AudioCardProps {
  terminal: CallTerminal;
}

const AudioCard = ({ terminal }: AudioCardProps) => {
  const { t } = useTranslation("common");
  const { phase, ice, levels, speak, available, micError } = terminal;
  const ns = terminal.noiseSuppression;

  const LinkGlyph = LINK_GLYPH[phase];
  const upPct = Math.min(100, Math.round(levels.up * 100));
  const downPct = Math.min(100, Math.round(levels.down * 100));

  const secureURL = `https://${window.location.hostname}:8444${window.location.pathname}`;

  return (
    <Card className={cn(CARD_SHELL, CARD_PAD)}>
      <CardHeader className={CARD_HEAD.ROOT}>
        <div className={CARD_HEAD.TITLES}>
          <CardTitle className={CARD_TITLE}>{t(`${K}.audio.title`)}</CardTitle>
          <p className={CARD_HEAD.DESC}>{t(`${K}.audio.description`)}</p>
        </div>
        <div className={CARD_HEAD.ACTIONS}>
          <Badge variant={LINK_BADGE[phase]}>
            <LinkGlyph className={CHIP_GLYPH} aria-hidden="true" />
            {t(`${K}.audio.phase.${phase}`)}
          </Badge>
        </div>
      </CardHeader>

      <CardContent className="flex flex-col gap-5 px-0">
        {!available ? (
          <div className={NOTICE.ROOT}>
            <div className={NOTICE.DISC}>
              <TriangleAlertIcon className={NOTICE.GLYPH} aria-hidden="true" />
            </div>
            <p className={NOTICE.TITLE}>{t(`${K}.blocker.no-service.title`)}</p>
            <p className={NOTICE.BODY}>{t(`${K}.blocker.no-service.body`)}</p>
            <Button
              type="button"
              variant="tonal"
              size="action"
              className={NOTICE.ACTION}
              onClick={() => {
                window.location.href = secureURL;
              }}
            >
              {t(`${K}.blocker.insecure.action`)}
            </Button>
          </div>
        ) : (
          <>
            {!speak ? (
              <div className={NOTICE.ROOT}>
                <div className={NOTICE.DISC}>
                  <MicOffIcon className={NOTICE.GLYPH} aria-hidden="true" />
                </div>
                <p className={NOTICE.TITLE}>{t(`${K}.blocker.insecure.title`)}</p>
                <p className={NOTICE.BODY}>{t(`${K}.blocker.insecure.body`)}</p>
                <Button
                  type="button"
                  variant="tonal"
                  size="action"
                  className={NOTICE.ACTION}
                  onClick={() => {
                    window.location.href = secureURL;
                  }}
                >
                  {t(`${K}.blocker.insecure.action`)}
                </Button>
              </div>
            ) : null}

            <div className="flex flex-wrap items-center gap-2.5">
              {phase === "live" ? (
                <Button
                  type="button"
                  variant="tonal-neutral"
                  size="action"
                  onClick={terminal.disconnect}
                >
                  <CircleSlashIcon className="size-4" />
                  {t(`${K}.audio.disconnect`)}
                </Button>
              ) : (
                <Button
                  type="button"
                  variant="default"
                  size="action"
                  onClick={() => {
                    void terminal.connect();
                  }}
                  disabled={phase === "connecting"}
                >
                  {phase === "connecting" ? (
                    <RefreshCcwIcon className="size-4 animate-spin" />
                  ) : speak ? (
                    <MicIcon className="size-4" />
                  ) : (
                    <PhoneCallIcon className="size-4" />
                  )}
                  {t(`${K}.audio.connect`)}
                </Button>
              )}
              <span className={SECTION_LABEL}>
                {ice ? `${t(`${K}.audio.ice`)}: ${ice}` : t(`${K}.audio.ice_none`)}
              </span>
            </div>

            <div className={METER.ROW}>
              <div className={METER.LABEL}>
                <span className={METER.NAME}>
                  {speak ? t(`${K}.audio.meter_up`) : t(`${K}.audio.meter_up_muted`)}
                </span>
                <span className={METER.VALUE}>{upPct}%</span>
              </div>
              <div className={METER.TRACK}>
                <div
                  className={cn(METER.FILL, METER_TONE.up)}
                  style={{ width: `${upPct}%` }}
                />
              </div>
            </div>

            <div className={METER.ROW}>
              <div className={METER.LABEL}>
                <span className={METER.NAME}>
                  {terminal.squelched
                    ? t(`${K}.audio.meter_down_gated`)
                    : t(`${K}.audio.meter_down`)}
                </span>
                <span className={METER.VALUE}>{downPct}%</span>
              </div>
              <div className={METER.TRACK}>
                <div
                  className={cn(METER.FILL, METER_TONE.down)}
                  style={{ width: `${downPct}%` }}
                />
              </div>
            </div>

            {/* Noise suppression sits next to the uplink meter because that is the
                meter it changes: switching it on should visibly lower this bar in
                a quiet room, which is the operator's own proof that it works. */}
            <div className="flex flex-wrap items-center gap-2.5 border-t border-border pt-3">
              <Button
                type="button"
                variant={ns.enabled ? "tonal" : "tonal-neutral"}
                size="action"
                onClick={() => terminal.noiseSuppression.setEnabled(!ns.enabled)}
                aria-pressed={ns.enabled}
                disabled={!speak}
                title={
                  !speak
                    ? t(`${K}.audio.ns_needs_https`)
                    : ns.enabled
                      ? t(`${K}.audio.ns_on_hint`)
                      : t(`${K}.audio.ns_off_hint`)
                }
              >
                <SparklesIcon className="size-4" />
                {ns.enabled ? t(`${K}.audio.ns_on`) : t(`${K}.audio.ns_off`)}
              </Button>
              <span className={cn(METER.NAME, "text-on-surface-variant")}>
                {ns.state === "on"
                  ? t(`${K}.audio.ns_state_on`)
                  : ns.state === "off" && ns.enabled
                    ? t(`${K}.audio.ns_state_armed`)
                  : ns.state === "starting"
                    ? t(`${K}.audio.ns_state_starting`)
                    : ns.state === "failed"
                      ? t(`${K}.audio.ns_state_failed`, { reason: ns.detail ?? "?" })
                      : ns.state === "unavailable"
                        ? t(`${K}.audio.ns_needs_https`)
                        : t(`${K}.audio.ns_state_off`)}
              </span>
            </div>

            {micError ? (
              <p className={cn(METER.NAME, "text-destructive normal-case")}>
                {t(`${K}.blocker.no-mic.body`)}
              </p>
            ) : null}

            <p className={cn(METER.NAME, "gap-1.5")}>
              {phase === "live" ? (
                <CheckCircle2Icon
                  className="mr-1.5 inline size-3.5 text-success"
                  aria-hidden="true"
                />
              ) : null}
              {t(`${K}.audio.hint`)}
            </p>
          </>
        )}
      </CardContent>
    </Card>
  );
};

export default AudioCard;
