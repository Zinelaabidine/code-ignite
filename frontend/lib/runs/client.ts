import type {
  RunOutcome,
  RunRequest,
  RunResult,
  SubmitRunResponse,
} from "@/types/runs";

/**
 * Typed fetch wrapper for the code-playground API. Every function here takes
 * a bearer token as a parameter rather than fetching one itself — `useRun.ts`
 * owns getting a fresh token per call via `fetchAuthSession()`, this module
 * only knows how to talk to `/runs`.
 */

export type RunApiErrorKind =
  "unauthenticated" | "rate-limited" | "invalid" | "network-error";

export class RunApiError extends Error {
  readonly kind: RunApiErrorKind;
  readonly status: number | undefined;

  constructor(message: string, kind: RunApiErrorKind, status?: number) {
    super(message);
    this.name = "RunApiError";
    this.kind = kind;
    this.status = status;
  }
}

/** True for the `DOMException` a `fetch` call rejects with on abort. */
export function isAbortError(error: unknown): boolean {
  return error instanceof DOMException && error.name === "AbortError";
}

function classifyStatus(status: number): RunApiErrorKind {
  if (status === 401) return "unauthenticated";
  if (status === 429) return "rate-limited";
  // 422: pydantic validation (unsupported language, code over the length
  // cap). 400 is not currently returned by the API but is treated the same.
  if (status === 422 || status === 400) return "invalid";
  return "network-error";
}

async function doFetch(url: string, init: RequestInit): Promise<Response> {
  try {
    return await fetch(url, init);
  } catch (error) {
    if (isAbortError(error)) throw error;
    throw new RunApiError(
      "Could not reach the code-playground API.",
      "network-error",
    );
  }
}

export async function submitRun(
  baseUrl: string,
  token: string,
  payload: RunRequest,
  signal: AbortSignal,
): Promise<SubmitRunResponse> {
  const response = await doFetch(`${baseUrl}/runs`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(payload),
    signal,
  });
  if (!response.ok) {
    throw new RunApiError(
      `POST /runs failed with ${response.status}`,
      classifyStatus(response.status),
      response.status,
    );
  }
  return (await response.json()) as SubmitRunResponse;
}

export async function getRun(
  baseUrl: string,
  token: string,
  jobId: string,
  signal: AbortSignal,
): Promise<RunOutcome> {
  const response = await doFetch(`${baseUrl}/runs/${jobId}`, {
    headers: { Authorization: `Bearer ${token}` },
    signal,
  });
  // 202 is the API's explicit "not finished yet" signal — checked by status
  // code, not response body shape, since that's what the contract actually
  // guarantees (see codeignite.api.routes_runs.get_run).
  if (response.status === 202) {
    return { kind: "pending" };
  }
  if (!response.ok) {
    throw new RunApiError(
      `GET /runs/${jobId} failed with ${response.status}`,
      classifyStatus(response.status),
      response.status,
    );
  }
  const result = (await response.json()) as RunResult;
  return { kind: "finished", result };
}
