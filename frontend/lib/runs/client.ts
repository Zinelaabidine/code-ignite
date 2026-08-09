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
  | "unauthenticated"
  | "forbidden"
  | "rate-limited"
  | "invalid"
  | "network-error";

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
  // CloudFront OAC → Lambda function URL rejects a signed POST whose body
  // hash is missing or wrong with 403. Without this branch that surfaces as
  // a generic network-error (and with the distribution's 403→404 rewrite it
  // can look like a 404 instead — see cloudfront.tf custom_error_response).
  if (status === 403) return "forbidden";
  if (status === 429) return "rate-limited";
  // 422: pydantic validation (unsupported language, code over the length
  // cap). 400 is not currently returned by the API but is treated the same.
  if (status === 422 || status === 400) return "invalid";
  return "network-error";
}

/**
 * Hex SHA-256 of `body`. Required when POSTing through CloudFront OAC to a
 * Lambda function URL — OAC signs with SigV4 but does not hash the payload,
 * and Lambda URLs reject UNSIGNED-PAYLOAD. Local docker-compose has no
 * CloudFront in front, so the header is simply ignored there.
 * @see https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-lambda.html
 */
async function sha256Hex(body: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(body),
  );
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * The Cognito access token travels in this header, not `Authorization`.
 *
 * CloudFront's Lambda-function-URL OAC signs every origin request with SigV4
 * and writes that signature into `Authorization`, discarding whatever the
 * viewer sent — so a perfectly valid token sent the conventional way never
 * reaches the API and every request 401s. Must stay in sync with
 * `backend/src/codeignite/api/auth.py`.
 * @see https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-lambda.html
 */
const AUTH_HEADER = "X-Codeignite-Authorization";

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
  const body = JSON.stringify(payload);
  const payloadHash = await sha256Hex(body);
  const response = await doFetch(`${baseUrl}/runs`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      [AUTH_HEADER]: `Bearer ${token}`,
      "x-amz-content-sha256": payloadHash,
    },
    body,
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
    headers: { [AUTH_HEADER]: `Bearer ${token}` },
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
