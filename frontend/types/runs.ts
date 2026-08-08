/**
 * Shared run types — mirrors the backend Pydantic models in
 * `backend/src/codeignite/api/routes_runs.py` and
 * `backend/src/codeignite/runner/base.py` field-for-field, including casing
 * (FastAPI serializes these as snake_case, not camelCase). Keep them in the
 * same PR as any backend model change so drift is visible in one diff — see
 * `docs/code-playground-implementation-plan.md` stage 5.
 */

/** Mirrors `codeignite.runner.base.RunStatus`. */
export type RunStatus = "ok" | "timeout" | "oom" | "error";

/** Mirrors `codeignite.api.routes_runs.RunRequest`. */
export type RunRequest = {
  language: string;
  code: string;
};

/** Mirrors `codeignite.api.routes_runs.SubmitRunResponse`. */
export type SubmitRunResponse = {
  job_id: string;
};

/** Mirrors `codeignite.api.routes_runs.RunResponse`. */
export type RunResult = {
  stdout: string;
  stderr: string;
  exit_code: number;
  duration_ms: number;
  status: RunStatus;
  truncated: boolean;
};

/**
 * `GET /runs/{job_id}` returns 202 with `{"status":"pending"}` (mirrored by
 * `codeignite.api.routes_runs.PendingResponse`) before a result exists, and
 * 200 with the full `RunResult` once it does. Modeled as a discriminated
 * union on HTTP status rather than response shape, since that's what the API
 * actually distinguishes on.
 */
export type RunOutcome =
  { kind: "pending" } | { kind: "finished"; result: RunResult };

/**
 * Mirrors `codeignite.domain.languages.LANGUAGES`. There is no `GET
 * /languages` endpoint (deliberately — see stage 6 of the implementation
 * plan), so this list is maintained by hand and must stay in sync with the
 * backend registry: adding a language there means adding an entry here too.
 */
export const SUPPORTED_LANGUAGES: ReadonlyArray<{
  readonly value: string;
  readonly label: string;
}> = [{ value: "python", label: "Python 3.12" }];
