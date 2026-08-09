import {
  AlertTriangle,
  Bug,
  CheckCircle2,
  Circle,
  Clock,
  Gauge,
  HelpCircle,
  Loader2,
  Lock,
  WifiOff,
  Zap,
} from "lucide-react";
import type { ComponentType } from "react";

import { cn } from "@/lib/utils";
import type { RunHookState } from "@/lib/runs/useRun";

type Tone = "neutral" | "info" | "success" | "warning" | "danger";

const TONE_CLASSES: Record<Tone, string> = {
  neutral:
    "bg-[var(--nord-tint)] text-[var(--nord-slate)] border-[var(--nord-hairline)]",
  info: "bg-[var(--nord-teal-tint)] text-[var(--nord-teal)] border-transparent",
  success:
    "bg-[var(--nord-success-tint)] text-[var(--nord-success)] border-transparent",
  warning:
    "bg-[var(--nord-warning-tint)] text-[var(--nord-warning)] border-transparent",
  danger:
    "bg-[var(--nord-danger-tint)] text-[var(--nord-danger)] border-transparent",
};

type Presentation = {
  label: string;
  tone: Tone;
  icon: ComponentType<{ className?: string }>;
  spin?: boolean;
};

/**
 * Every reachable state gets its own label, tone, and icon — "finished
 * (ok)", "timed out", "out of memory", and "crashed" (error) must each read
 * distinctly per the stage 5 checklist, not just share one generic
 * "finished"/"failed" pair.
 */
function present(state: RunHookState): Presentation {
  switch (state.status) {
    case "idle":
      return { label: "Idle", tone: "neutral", icon: Circle };
    case "submitting":
      return { label: "Submitting…", tone: "info", icon: Loader2, spin: true };
    case "polling":
      return { label: "Running…", tone: "info", icon: Loader2, spin: true };
    case "still-running":
      return {
        label: "Still running (giving up on polling)",
        tone: "warning",
        icon: HelpCircle,
      };
    case "unauthenticated":
      return { label: "Sign-in required", tone: "danger", icon: Lock };
    case "forbidden":
      return {
        label: "Request forbidden",
        tone: "danger",
        icon: AlertTriangle,
      };
    case "rate-limited":
      return {
        label: "Rate limited — slow down",
        tone: "warning",
        icon: Gauge,
      };
    case "invalid":
      return {
        label: "Request rejected",
        tone: "warning",
        icon: AlertTriangle,
      };
    case "network-error":
      return {
        label: "Could not reach the API",
        tone: "danger",
        icon: WifiOff,
      };
    case "finished":
      switch (state.result.status) {
        case "ok":
          return { label: "Finished", tone: "success", icon: CheckCircle2 };
        case "timeout":
          return { label: "Timed out", tone: "warning", icon: Clock };
        case "oom":
          return { label: "Out of memory", tone: "danger", icon: Zap };
        case "error":
          return { label: "Crashed", tone: "danger", icon: Bug };
      }
  }
}

export default function StatusBadge({ state }: { state: RunHookState }) {
  const { label, tone, icon: Icon, spin } = present(state);
  return (
    <span
      className={cn(
        "inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs font-medium",
        TONE_CLASSES[tone],
      )}
    >
      <Icon className={cn("h-3.5 w-3.5", spin && "animate-spin")} />
      {label}
    </span>
  );
}
