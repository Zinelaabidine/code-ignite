import { ChevronDown } from "lucide-react";

import { cn } from "@/lib/utils";
import { SUPPORTED_LANGUAGES } from "@/types/runs";

type LanguageSelectProps = {
  value: string;
  onChange: (language: string) => void;
  disabled?: boolean;
  className?: string;
};

/**
 * A native `<select>`, not a full shadcn combobox: `SUPPORTED_LANGUAGES`
 * (see `types/runs.ts`) has five entries as of stage 6's language additions,
 * and a native element is still fully keyboard- and screen-reader-accessible
 * for free at that size. Revisit for a richer picker (search, grouping) if
 * the list grows enough that scanning a plain dropdown stops being fast.
 */
export default function LanguageSelect({
  value,
  onChange,
  disabled,
  className,
}: LanguageSelectProps) {
  return (
    <div className={cn("relative inline-flex items-center", className)}>
      <select
        aria-label="Language"
        value={value}
        disabled={disabled}
        onChange={(event) => onChange(event.target.value)}
        className={cn(
          "h-8 appearance-none rounded-lg border border-[var(--nord-hairline)] bg-[var(--nord-surface)] py-1 pr-8 pl-3 text-sm font-medium text-[var(--nord-ink)] outline-none transition-colors",
          "focus-visible:border-[var(--nord-teal)] focus-visible:ring-3 focus-visible:ring-[var(--nord-teal-tint)]",
          "disabled:pointer-events-none disabled:opacity-50",
        )}
      >
        {SUPPORTED_LANGUAGES.map((language) => (
          <option key={language.value} value={language.value}>
            {language.label}
          </option>
        ))}
      </select>
      <ChevronDown className="pointer-events-none absolute right-2.5 h-3.5 w-3.5 text-[var(--nord-slate)]" />
    </div>
  );
}
