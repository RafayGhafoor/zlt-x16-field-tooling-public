"use client";

import { useMemo } from "react";
import { useTranslation } from "react-i18next";
import {
  ArrowDownLeftIcon,
  ArrowUpRightIcon,
  CheckCircle2Icon,
  ClockIcon,
  PhoneMissedIcon,
  PhoneIcon,
  Trash2Icon,
  TriangleAlertIcon,
} from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import MaskedText from "@/components/masked-text";
import type { CallTerminal } from "@/hooks/use-call-terminal";
import { useReveal } from "@/hooks/use-reveal";
import { displayName } from "@/lib/phone";
import { cn } from "@/lib/utils";

import {
  CARD_HEAD,
  CARD_PAD,
  CARD_SHELL,
  CARD_TITLE,
  CHIP_GLYPH,
  FOOTNOTE,
  HISTORY,
  NOTICE,
  OUTCOME_BADGE,
} from "./shapes";

// =============================================================================
// HistoryCard — the call log
// =============================================================================
// Read from the device, not from this tab. The bridge writes one entry when a
// call finishes, so the log also contains calls placed from the vendor app or
// received while nobody had this page open — which is the only version of a call
// log worth having.
//
// Every row answers the three questions a log is opened for: WHO, WHEN and HOW
// LONG — plus the one that is usually missing, HOW IT ENDED. A call that was never
// answered shows a duration of zero and an outcome chip that says which kind of
// nothing it was: `no_answer` (we dialled, nobody picked up) and `missed`
// (they called, we did not answer) are different facts and get different chips.
// =============================================================================

const K = "calls";

interface HistoryCardProps {
  terminal: CallTerminal;
}

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
  return m > 0 ? `${m}:${String(s).padStart(2, "0")}` : `${s}s`;
};

const OUTCOME_GLYPH = {
  answered: CheckCircle2Icon,
  no_answer: ClockIcon,
  missed: PhoneMissedIcon,
  failed: TriangleAlertIcon,
} as const;

const HistoryCard = ({ terminal }: HistoryCardProps) => {
  const { t } = useTranslation("common");
  const { revealed } = useReveal();
  const { calls, contacts } = terminal;

  const rows = useMemo(
    () =>
      calls.map((c) => {
        const label = displayName(contacts, c.number);
        return {
          ...c,
          label,
          // A resolved contact shows a NAME, so the name is what gets masked; an
          // unknown caller has no name and shows a masked number instead.
          labelIsNumber: label === c.number,
          when: clock(c.started_at),
          length: c.seconds > 0 ? mmss(c.seconds) : "—",
        };
      }),
    [calls, contacts]
  );

  return (
    <Card className={cn(CARD_SHELL, CARD_PAD)}>
      <CardHeader className={CARD_HEAD.ROOT}>
        <div className={CARD_HEAD.TITLES}>
          <CardTitle className={CARD_TITLE}>{t(`${K}.history.title`)}</CardTitle>
          <p className={CARD_HEAD.DESC}>{t(`${K}.history.description`)}</p>
        </div>
        <div className={CARD_HEAD.ACTIONS}>
          {rows.length > 0 ? (
            <Button
              type="button"
              variant="tonal-neutral"
              size="sm"
              onClick={() => void terminal.clearCalls()}
            >
              <Trash2Icon className="size-4" />
              {t(`${K}.history.clear`)}
            </Button>
          ) : null}
        </div>
      </CardHeader>

      <CardContent className="flex flex-col gap-3 px-0">
        {rows.length === 0 ? (
          <div className={NOTICE.ROOT}>
            <p className={NOTICE.TITLE}>{t(`${K}.history.empty_title`)}</p>
            <p className={NOTICE.BODY}>{t(`${K}.history.empty_body`)}</p>
          </div>
        ) : (
          <div className="w-full overflow-x-auto">
            <table className={HISTORY.TABLE}>
              <thead>
                <tr>
                  <th className={cn(HISTORY.HEAD, HISTORY.COLS.WHO_INSET)}>
                    {t(`${K}.history.col_who`)}
                  </th>
                  <th className={cn(HISTORY.HEAD, HISTORY.COLS.TIME)}>
                    {t(`${K}.history.col_when`)}
                  </th>
                  <th className={cn(HISTORY.HEAD, HISTORY.COLS.LEN)}>
                    {t(`${K}.history.col_length`)}
                  </th>
                  <th className={cn(HISTORY.HEAD, HISTORY.COLS.OUT)}>
                    {t(`${K}.history.col_outcome`)}
                  </th>
                  <th className={cn(HISTORY.HEAD, HISTORY.COLS.ACT)}>
                    <span className="sr-only">{t(`${K}.history.col_redial`)}</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => {
                  const Glyph = OUTCOME_GLYPH[r.outcome as keyof typeof OUTCOME_GLYPH];
                  const DirIcon =
                    r.direction === "incoming" ? ArrowDownLeftIcon : ArrowUpRightIcon;
                  return (
                    <tr key={r.id} className={HISTORY.ROW}>
                      <td className={HISTORY.CELL}>
                        <span className="flex min-w-0 items-center gap-2">
                          <DirIcon
                            className={cn(
                              "size-4 flex-none",
                              r.direction === "incoming"
                                ? "text-success"
                                : "text-on-surface-variant"
                            )}
                            aria-hidden="true"
                          />
                          <span className="min-w-0">
                            <MaskedText
                              className={HISTORY.NAME}
                              value={r.label}
                              number={r.labelIsNumber}
                              revealed={revealed}
                            />
                            {!r.labelIsNumber && r.number !== "" ? (
                              <MaskedText
                                className={HISTORY.SUB}
                                value={r.number}
                                number
                                revealed={revealed}
                              />
                            ) : null}
                          </span>
                        </span>
                      </td>
                      <td className={cn(HISTORY.CELL, HISTORY.COLS.TIME)}>{r.when}</td>
                      <td className={cn(HISTORY.NUM, HISTORY.COLS.LEN)}>{r.length}</td>
                      <td className={cn(HISTORY.CELL, HISTORY.COLS.OUT)}>
                        <Badge variant={OUTCOME_BADGE[r.outcome] ?? "muted"}>
                          {Glyph ? <Glyph className={CHIP_GLYPH} aria-hidden="true" /> : null}
                          {t(`${K}.history.outcome.${r.outcome}`)}
                        </Badge>
                      </td>
                      <td className={cn(HISTORY.CELL, HISTORY.COLS.ACT)}>
                        <Button
                          type="button"
                          variant="tonal-neutral"
                          size="icon-sm"
                          aria-label={t(`${K}.history.redial`, { who: r.label })}
                          title={t(`${K}.history.redial`, { who: r.label })}
                          disabled={!r.number || terminal.state?.call !== ""}
                          onClick={() => void terminal.dial(r.number)}
                        >
                          <PhoneIcon className="size-4" aria-hidden="true" />
                        </Button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
        <p className={FOOTNOTE}>{t(`${K}.history.footnote`)}</p>
      </CardContent>
    </Card>
  );
};

export default HistoryCard;
