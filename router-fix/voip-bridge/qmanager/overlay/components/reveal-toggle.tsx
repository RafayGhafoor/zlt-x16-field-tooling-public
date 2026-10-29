"use client";

// =============================================================================
// RevealToggle — the one eye for a surface
// =============================================================================
// Paired with the RevealProvider on the Calls page and in the dashboard dialog.
// It is a real toggle, not a momentary "peek": numbers stay visible until it is
// pressed again or the page is reloaded, because a reader checking a call log
// against a note needs both hands.
// =============================================================================

import { useTranslation } from "react-i18next";
import { EyeIcon, EyeOffIcon } from "lucide-react";

import { Button } from "@/components/ui/button";
import { useReveal } from "@/hooks/use-reveal";

interface RevealToggleProps {
  className?: string;
  /** Controlled use, for surfaces that are not wrapped in a RevealProvider. */
  revealed?: boolean;
  onToggle?: () => void;
}

const RevealToggle = ({ className, revealed: r, onToggle }: RevealToggleProps) => {
  const { t } = useTranslation("common");
  const ctx = useReveal();
  const revealed = r ?? ctx.revealed;
  const toggle = onToggle ?? ctx.toggle;
  const label = revealed ? t("calls.reveal.hide") : t("calls.reveal.show");

  return (
    <Button
      type="button"
      variant={revealed ? "tonal-destructive" : "tonal-neutral"}
      size="action"
      onClick={toggle}
      aria-pressed={revealed}
      aria-label={label}
      title={label}
      className={className}
    >
      {revealed ? <EyeOffIcon className="size-4" /> : <EyeIcon className="size-4" />}
      {label}
    </Button>
  );
};

export default RevealToggle;
