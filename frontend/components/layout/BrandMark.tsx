import Link from "next/link";
import { Boxes } from "lucide-react";

import { cn } from "@/lib/utils";

type BrandMarkProps = {
  href?: string;
  className?: string;
  wordmarkClassName?: string;
};

/**
 * Logo lockup used in the auth shell. Swap the icon and wordmark when you
 * fork this template into a real project.
 */
export default function BrandMark({
  href = "/",
  className,
  wordmarkClassName,
}: BrandMarkProps) {
  return (
    <Link
      href={href}
      className={cn("group flex items-center gap-2.5", className)}
    >
      <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-[var(--nord-teal)] text-[var(--nord-cta-fg)] shadow-[0_2px_10px_rgba(78,130,124,0.35)] transition-transform group-hover:scale-105">
        <Boxes className="h-[18px] w-[18px]" strokeWidth={2.25} />
      </span>
      <span
        className={cn(
          "text-[17px] font-semibold tracking-tight text-[var(--nord-ink)]",
          wordmarkClassName,
        )}
      >
        App Template
      </span>
    </Link>
  );
}
