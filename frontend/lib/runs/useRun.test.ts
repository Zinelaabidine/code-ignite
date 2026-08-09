import { describe, expect, it, vi } from "vitest";

import { RunApiError } from "@/lib/runs/client";
import {
  BACKOFF_AFTER_MS,
  FAST_POLL_MS,
  GIVE_UP_AFTER_MS,
  runAndPoll,
  SLOW_POLL_MS,
  type RunAndPollDeps,
  type RunHookState,
} from "@/lib/runs/useRun";
import type { RunResult } from "@/types/runs";

const RESULT: RunResult = {
  stdout: "hi\n",
  stderr: "",
  exit_code: 0,
  duration_ms: 42,
  status: "ok",
  truncated: false,
};

/** A fake clock that advances by `stepMs` every time `now()` is read. */
function fakeClock(stepMs: number) {
  let t = 0;
  return () => {
    t += stepMs;
    return t;
  };
}

function baseDeps(overrides: Partial<RunAndPollDeps> = {}): RunAndPollDeps {
  return {
    getAccessToken: vi.fn().mockResolvedValue("test-token"),
    submitRun: vi.fn().mockResolvedValue({ job_id: "abc123" }),
    getRun: vi.fn().mockResolvedValue({ kind: "pending" }),
    sleep: vi.fn().mockResolvedValue(undefined),
    now: fakeClock(100),
    ...overrides,
  };
}

async function collectStates(
  run: (onState: (s: RunHookState) => void) => Promise<void>,
): Promise<RunHookState[]> {
  const states: RunHookState[] = [];
  await run((s) => states.push(s));
  return states;
}

describe("runAndPoll", () => {
  it("submits then polls to a finished result", async () => {
    const getRun = vi
      .fn()
      .mockResolvedValueOnce({ kind: "pending" })
      .mockResolvedValueOnce({ kind: "pending" })
      .mockResolvedValueOnce({ kind: "finished", result: RESULT });
    const deps = baseDeps({ getRun });

    const states = await collectStates((onState) =>
      runAndPoll(
        "http://api.test",
        "python",
        "print(1)",
        new AbortController().signal,
        onState,
        deps,
      ),
    );

    expect(states).toEqual([
      { status: "submitting" },
      { status: "polling" },
      { status: "finished", result: RESULT },
    ]);
    expect(deps.submitRun).toHaveBeenCalledTimes(1);
    expect(getRun).toHaveBeenCalledTimes(3);
  });

  it("gives up after 60s of pending polls, honoring the 10s fast/slow backoff", async () => {
    // Advances the clock by 4s per `now()` read, so it crosses the 10s
    // backoff threshold partway through and the 60s give-up threshold after
    // a bounded number of iterations — no real waiting required.
    const deps = baseDeps({ now: fakeClock(4_000) });

    const states = await collectStates((onState) =>
      runAndPoll(
        "http://api.test",
        "python",
        "print(1)",
        new AbortController().signal,
        onState,
        deps,
      ),
    );

    expect(states.at(-1)).toEqual({ status: "still-running" });

    const sleepCalls = (deps.sleep as ReturnType<typeof vi.fn>).mock.calls.map(
      (call) => call[0],
    );
    expect(sleepCalls).toContain(FAST_POLL_MS);
    expect(sleepCalls).toContain(SLOW_POLL_MS);
    expect(Math.max(...sleepCalls)).toBe(SLOW_POLL_MS);
    // Sanity check on the constants the test relies on.
    expect(BACKOFF_AFTER_MS).toBe(10_000);
    expect(GIVE_UP_AFTER_MS).toBe(60_000);
  });

  it("stops cleanly when aborted mid-poll, without emitting a final state", async () => {
    const controller = new AbortController();
    let pollCount = 0;
    const getRun = vi.fn().mockImplementation(() => {
      pollCount += 1;
      if (pollCount === 1) {
        // Simulate the abort happening while this poll was in flight.
        controller.abort();
      }
      return Promise.resolve({ kind: "pending" });
    });
    const sleep = vi
      .fn()
      .mockImplementation((_ms: number, signal: AbortSignal) => {
        if (signal.aborted) {
          return Promise.reject(new DOMException("Aborted", "AbortError"));
        }
        return Promise.resolve();
      });
    const deps = baseDeps({ getRun, sleep });

    const states = await collectStates((onState) =>
      runAndPoll(
        "http://api.test",
        "python",
        "print(1)",
        controller.signal,
        onState,
        deps,
      ),
    );

    expect(states).toEqual([{ status: "submitting" }, { status: "polling" }]);
    expect(getRun).toHaveBeenCalledTimes(1);
  });

  it("resolves to unauthenticated when there is no signed-in session", async () => {
    const getAccessToken = vi.fn().mockResolvedValue(null);
    const deps = baseDeps({ getAccessToken });

    const states = await collectStates((onState) =>
      runAndPoll(
        "http://api.test",
        "python",
        "print(1)",
        new AbortController().signal,
        onState,
        deps,
      ),
    );

    expect(states).toEqual([
      { status: "submitting" },
      { status: "unauthenticated" },
    ]);
    expect(deps.submitRun).not.toHaveBeenCalled();
  });

  it("maps a 401 from the API to unauthenticated, not a generic error", async () => {
    const submitRun = vi
      .fn()
      .mockRejectedValue(new RunApiError("nope", "unauthenticated", 401));
    const deps = baseDeps({ submitRun });

    const states = await collectStates((onState) =>
      runAndPoll(
        "http://api.test",
        "python",
        "print(1)",
        new AbortController().signal,
        onState,
        deps,
      ),
    );

    expect(states.at(-1)).toEqual({ status: "unauthenticated" });
  });

  it("maps rate-limit and network errors to their own states", async () => {
    const rateLimited = await collectStates((onState) =>
      runAndPoll(
        "http://api.test",
        "python",
        "print(1)",
        new AbortController().signal,
        onState,
        baseDeps({
          submitRun: vi
            .fn()
            .mockRejectedValue(
              new RunApiError("slow down", "rate-limited", 429),
            ),
        }),
      ),
    );
    expect(rateLimited.at(-1)).toEqual({ status: "rate-limited" });

    const forbidden = await collectStates((onState) =>
      runAndPoll(
        "http://api.test",
        "python",
        "print(1)",
        new AbortController().signal,
        onState,
        baseDeps({
          submitRun: vi
            .fn()
            .mockRejectedValue(
              new RunApiError("POST /runs failed with 403", "forbidden", 403),
            ),
        }),
      ),
    );
    expect(forbidden.at(-1)).toEqual({
      status: "forbidden",
      message: "POST /runs failed with 403",
    });

    const networkError = await collectStates((onState) =>
      runAndPoll(
        "http://api.test",
        "python",
        "print(1)",
        new AbortController().signal,
        onState,
        baseDeps({
          submitRun: vi
            .fn()
            .mockRejectedValue(
              new RunApiError(
                "Could not reach the code-playground API.",
                "network-error",
              ),
            ),
        }),
      ),
    );
    expect(networkError.at(-1)).toEqual({
      status: "network-error",
      message: "Could not reach the code-playground API.",
    });
  });
});
