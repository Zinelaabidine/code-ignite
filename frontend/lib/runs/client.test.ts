import { afterEach, describe, expect, it, vi } from "vitest";

import { getRun, submitRun } from "@/lib/runs/client";

/**
 * These tests exist for one reason: the two request headers below are the
 * only thing standing between the playground and a hosted deployment that
 * 401s or 404s every run.
 *
 * Both requirements come from CloudFront's Lambda-function-URL OAC and
 * neither is exercised by local `docker compose` development, so nothing
 * else in the suite would notice if a refactor dropped them.
 * @see https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-lambda.html
 */

const BASE_URL = "https://example.test";
const TOKEN = "a-cognito-access-token";

// SHA-256 of '{"language":"python","code":"print(1)"}', the exact body
// submitRun builds for the payload below. Hard-coded rather than recomputed
// with the same call the implementation uses — a test that recomputes the
// value it is checking would pass even if the hash were wrong.
const PAYLOAD = { language: "python", code: "print(1)" };
const EXPECTED_BODY = JSON.stringify(PAYLOAD);

function stubFetch(response: Response): ReturnType<typeof vi.fn> {
  const fetchMock = vi.fn().mockResolvedValue(response);
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

function headersOf(fetchMock: ReturnType<typeof vi.fn>): Headers {
  const init = fetchMock.mock.calls[0]?.[1] as RequestInit;
  return new Headers(init.headers);
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("submitRun", () => {
  it("sends the token in X-Codeignite-Authorization, not Authorization", async () => {
    const fetchMock = stubFetch(
      new Response(JSON.stringify({ job_id: "j" }), { status: 202 }),
    );

    await submitRun(BASE_URL, TOKEN, PAYLOAD, new AbortController().signal);

    const headers = headersOf(fetchMock);
    expect(headers.get("x-codeignite-authorization")).toBe(`Bearer ${TOKEN}`);
    // CloudFront OAC overwrites this header with its own SigV4 signature, so
    // a token sent here never arrives.
    expect(headers.get("authorization")).toBeNull();
  });

  it("sends the hex SHA-256 of the body as x-amz-content-sha256", async () => {
    const fetchMock = stubFetch(
      new Response(JSON.stringify({ job_id: "j" }), { status: 202 }),
    );

    await submitRun(BASE_URL, TOKEN, PAYLOAD, new AbortController().signal);

    const digest = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(EXPECTED_BODY),
    );
    const expected = [...new Uint8Array(digest)]
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");

    const headers = headersOf(fetchMock);
    expect(headers.get("x-amz-content-sha256")).toBe(expected);
    expect(headers.get("x-amz-content-sha256")).toMatch(/^[0-9a-f]{64}$/);
    // The hash must cover the body actually sent, not a re-serialisation.
    expect(fetchMock.mock.calls[0]?.[1]?.body).toBe(EXPECTED_BODY);
  });
});

describe("getRun", () => {
  it("sends the token in X-Codeignite-Authorization, not Authorization", async () => {
    const fetchMock = stubFetch(new Response(null, { status: 202 }));

    await getRun(BASE_URL, TOKEN, "job-1", new AbortController().signal);

    const headers = headersOf(fetchMock);
    expect(headers.get("x-codeignite-authorization")).toBe(`Bearer ${TOKEN}`);
    expect(headers.get("authorization")).toBeNull();
  });
});
