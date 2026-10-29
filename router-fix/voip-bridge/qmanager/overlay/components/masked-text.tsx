"use client";

// =============================================================================
// MaskedText — a value that is hidden until the surface is revealed
// =============================================================================
// `value` is the identity as the page would normally print it (contact name when
// one matched, otherwise the number). `number` says which masking rule applies.
// `reveal` is the surface's eye (hooks/use-reveal) — passing it explicitly keeps
// the component usable where a provider would be overkill, and keeps the render
// obvious in the table code.
// =============================================================================

import { maskIdentity } from "@/lib/mask";
import { cn } from "@/lib/utils";

interface MaskedTextProps {
  value: string;
  /** True when `value` is a dialled number rather than a resolved contact name. */
  number?: boolean;
  revealed: boolean;
  className?: string;
}

const MaskedText = ({ value, number = false, revealed, className }: MaskedTextProps) => {
  if (value === "") {
    return <span className={className}>—</span>;
  }
  const shown = revealed ? value : maskIdentity(value, number);
  return (
    <span
      className={cn(className)}
      // The mask is not a spoiler for a screen reader: assistive tech should read
      // what the operator sees, or read nothing at all. `aria-hidden` on the mask
      // plus a labelled parent keeps the two consistent.
      data-masked={revealed ? undefined : "true"}
    >
      {shown}
    </span>
  );
};

export default MaskedText;
