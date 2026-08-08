import { AlertTriangle } from "lucide-react";

import StatusBadge from "@/components/playground/StatusBadge";
import type { RunHookState } from "@/lib/runs/useRun";

function Pre({ label, text }: { label: string; text: string }) {
  if (!text) return null;
  return (
    <div>
      <p className="mb-1 text-xs font-medium tracking-wide text-[var(--nord-slate)] uppercase">
        {label}
      </p>
      {/* Program output is untrusted input — rendered as text content only,
          never dangerouslySetInnerHTML. */}
      <pre className="max-h-64 overflow-auto rounded-lg bg-[var(--nord-bg-2)] p-3 font-mono text-sm whitespace-pre-wrap text-[var(--nord-ink)]">
        {text}
      </pre>
    </div>
  );
}

function helperMessage(state: RunHookState): string | null {
  switch (state.status) {
    case "idle":
      return "Run your code to see output here.";
    case "still-running":
      return "This run is taking longer than 60 seconds, so we stopped polling. It may still finish — check back, or run again.";
    case "unauthenticated":
      return "Your session has expired. Sign in again and re-run.";
    case "rate-limited":
      return "You're submitting runs too quickly. Wait a moment and try again.";
    case "invalid":
      return state.message;
    case "network-error":
      return state.message;
    default:
      return null;
  }
}

export default function OutputPane({ state }: { state: RunHookState }) {
  const message = helperMessage(state);
  const isProblem =
    state.status === "unauthenticated" ||
    state.status === "rate-limited" ||
    state.status === "invalid" ||
    state.status === "network-error";

  return (
    <div className="flex h-full flex-col gap-3 rounded-xl border border-[var(--nord-hairline)] bg-[var(--nord-surface)] p-4">
      <div className="flex items-center justify-between gap-2">
        <h2 className="text-sm font-semibold text-[var(--nord-ink)]">Output</h2>
        <StatusBadge state={state} />
      </div>

      {message && (
        <p
          className={
            isProblem
              ? "flex items-start gap-2 rounded-lg bg-[var(--nord-danger-tint)] p-3 text-sm text-[var(--nord-danger)]"
              : "text-sm text-[var(--nord-slate)]"
          }
        >
          {isProblem && <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />}
          {message}
        </p>
      )}

      {state.status === "finished" && (
        <div className="flex flex-col gap-3">
          <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-[var(--nord-slate)]">
            <span>
              Exit code:{" "}
              <strong className="text-[var(--nord-ink)]">
                {state.result.exit_code}
              </strong>
            </span>
            <span>
              Duration:{" "}
              <strong className="text-[var(--nord-ink)]">
                {state.result.duration_ms}ms
              </strong>
            </span>
            {state.result.truncated && (
              <span className="rounded-full bg-[var(--nord-warning-tint)] px-2 py-0.5 font-medium text-[var(--nord-warning)]">
                Output truncated
              </span>
            )}
          </div>
          <Pre label="stdout" text={state.result.stdout} />
          <Pre label="stderr" text={state.result.stderr} />
          {!state.result.stdout && !state.result.stderr && (
            <p className="text-sm text-[var(--nord-slate)]">(no output)</p>
          )}
        </div>
      )}
    </div>
  );
}
