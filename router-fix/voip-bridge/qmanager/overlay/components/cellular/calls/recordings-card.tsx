"use client";

import { useMemo } from "react";
import { useTranslation } from "react-i18next";
import { DownloadIcon, Trash2Icon } from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import type { CallTerminal } from "@/hooks/use-call-terminal";
import { displayName } from "@/lib/phone";
import { cn } from "@/lib/utils";

import {
  CARD_HEAD,
  CARD_PAD,
  CARD_SHELL,
  CARD_TITLE,
  CHIP_GLYPH,
  FOOTNOTE,
  NOTICE,
  RECORDING_ROW,
  SECTION_LABEL,
  TABLE,
} from "./shapes";

// =============================================================================
// RecordingsCard — one stereo WAV per answered call
// =============================================================================
// The device writes the file, not the browser: the recording has to survive a
// closed tab, and it has to cover calls that were made from somewhere else.
//
// Left channel is the far end, right channel is this browser's microphone — a
// mixdown would be unlistenable the moment both sides talk, and two files would
// have to be re-aligned by hand.
//
// Recording is a per-device setting on purpose: it is the kind of switch that
// should not silently flip because one browser forgot it.
// =============================================================================

const K = "calls";

interface RecordingsCardProps {
  terminal: CallTerminal;
}

const bytesLabel = (n: number): string => {
  if (n > 1024 * 1024) {
    return `${(n / 1024 / 1024).toFixed(1)} MB`;
  }
  return `${Math.max(1, Math.round(n / 1024))} kB`;
};

const clock = (unix: number): string =>
  new Date(unix * 1000).toLocaleString([], {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });

const mmss = (sec: number): string => {
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
};

const RecordingsCard = ({ terminal }: RecordingsCardProps) => {
  const { t } = useTranslation("common");
  const { recordings, recordingsEnabled, contacts } = terminal;

  // The newest first, and named by contact where one matches — a list of raw
  // numbers is not a list anybody scans.
  const rows = useMemo(
    () =>
      recordings.map((r) => ({
        ...r,
        label: displayName(contacts, r.number),
        when: clock(r.started_at),
        length: mmss(r.seconds),
      })),
    [recordings, contacts]
  );

  return (
    <Card className={cn(CARD_SHELL, CARD_PAD)}>
      <CardHeader className={CARD_HEAD.ROOT}>
        <div className={CARD_HEAD.TITLES}>
          <CardTitle className={CARD_TITLE}>{t(`${K}.recordings.title`)}</CardTitle>
          <p className={CARD_HEAD.DESC}>{t(`${K}.recordings.description`)}</p>
        </div>
        <div className={CARD_HEAD.ACTIONS}>
          <Badge variant={recordingsEnabled ? "success" : "muted"}>
            {recordingsEnabled
              ? t(`${K}.recordings.on`)
              : t(`${K}.recordings.off`)}
          </Badge>
          <Button
            type="button"
            variant="tonal-neutral"
            size="sm"
            onClick={() => void terminal.setRecording(!recordingsEnabled)}
          >
            {recordingsEnabled
              ? t(`${K}.recordings.disable`)
              : t(`${K}.recordings.enable`)}
          </Button>
        </div>
      </CardHeader>

      <CardContent className="flex flex-col gap-3 px-0">
        {rows.length === 0 ? (
          <div className={NOTICE.ROOT}>
            <p className={NOTICE.TITLE}>{t(`${K}.recordings.empty_title`)}</p>
            <p className={NOTICE.BODY}>{t(`${K}.recordings.empty_body`)}</p>
          </div>
        ) : (
          <div className="flex flex-col gap-2">
            {rows.map((r) => (
              <div key={r.name} className={RECORDING_ROW.ROOT}>
                <div className={RECORDING_ROW.TEXT}>
                  <span className={RECORDING_ROW.NAME}>{r.label}</span>
                  <span className={RECORDING_ROW.META}>
                    {r.when} · {t(`${K}.recordings.${r.direction === "incoming" ? "incoming" : "outgoing"}`)} · {r.length} · {bytesLabel(r.bytes)}
                  </span>
                </div>
                <a
                  className="flex flex-none items-center"
                  href={`${terminal.apiBase}/recordings/${encodeURIComponent(r.name)}`}
                  download={r.name}
                  aria-label={t(`${K}.recordings.download`)}
                >
                  <Button type="button" variant="tonal-neutral" size="icon-sm">
                    <DownloadIcon className="size-4" />
                  </Button>
                </a>
                <audio
                  controls
                  preload="none"
                  className="h-9 w-36"
                  src={`${terminal.apiBase}/recordings/${encodeURIComponent(r.name)}`}
                  aria-label={t(`${K}.recordings.play`, { who: r.label })}
                />
                <Button
                  type="button"
                  variant="tonal-destructive"
                  size="icon-sm"
                  aria-label={t(`${K}.recordings.delete`)}
                  onClick={() => void terminal.deleteRecording(r.name)}
                >
                  <Trash2Icon className="size-4" />
                </Button>
              </div>
            ))}
          </div>
        )}

        <p className={FOOTNOTE}>{t(`${K}.recordings.footnote`)}</p>
      </CardContent>
    </Card>
  );
};

export default RecordingsCard;
