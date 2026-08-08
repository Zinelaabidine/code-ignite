import { Loader2, Play } from "lucide-react";

import { Button } from "@/components/ui/button";
import type { RunHookState } from "@/lib/runs/useRun";

const BUSY_STATUSES = new Set<RunHookState["status"]>([
  "submitting",
  "polling",
]);

type RunButtonProps = {
  state: RunHookState;
  onRun: () => void;
};

export default function RunButton({ state, onRun }: RunButtonProps) {
  const busy = BUSY_STATUSES.has(state.status);
  return (
    <Button onClick={onRun} disabled={busy} className="min-w-28">
      {busy ? (
        <>
          <Loader2 className="h-4 w-4 animate-spin" />
          {state.status === "submitting" ? "Submitting…" : "Running…"}
        </>
      ) : (
        <>
          <Play className="h-4 w-4" />
          Run
        </>
      )}
    </Button>
  );
}
