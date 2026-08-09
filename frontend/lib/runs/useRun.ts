"use client";

import { fetchAuthSession } from "aws-amplify/auth";
import { useCallback, useEffect, useRef, useState } from "react";

import {
  getRun,
  isAbortError,
  RunApiError,
  submitRun,
} from "@/lib/runs/client";
import type { RunResult } from "@/types/runs";

// Polling cadence from docs/code-playground-implementation-plan.md stage 5:
// 500ms for the first 10s, then back off to 1500ms, give up at 60s.
export const FAST_POLL_MS = 500;
export const SLOW_POLL_MS = 1500;
export const BACKOFF_AFTER_MS = 10_000;
export const GIVE_UP_AFTER_MS = 60_000;

export type RunHookState =
  | { status: "idle" }
  | { status: "submitting" }
  | { status: "polling" }
  | { status: "finished"; result: RunResult }
  | { status: "still-running" }
  | { status: "unauthenticated" }
  | { status: "forbidden"; message: string }
  | { status: "rate-limited" }
  | { status: "invalid"; message: string }
  | { status: "network-error"; message: string };

/** Rejects when `signal` aborts, otherwise resolves after `ms`. */
function realSleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(new DOMException("Aborted", "AbortError"));
      return;
    }
    const timer = setTimeout(() => {
      signal.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    function onAbort(): void {
      clearTimeout(timer);
      reject(new DOMException("Aborted", "AbortError"));
    }
    signal.addEventListener("abort", onAbort, { once: true });
  });
}

/**
 * Never cache a token in component state — Amplify's own session cache
 * already handles refresh, and holding a copy here risks sending a stale one
 * on a long-running poll. Returns `null` when there is no signed-in session,
 * which the caller treats identically to a 401 from the API.
 */
async function realGetAccessToken(): Promise<string | null> {
  const session = await fetchAuthSession();
  return session.tokens?.accessToken?.toString() ?? null;
}

function stateForError(error: unknown): RunHookState {
  if (error instanceof RunApiError) {
    switch (error.kind) {
      case "unauthenticated":
        return { status: "unauthenticated" };
      case "forbidden":
        return { status: "forbidden", message: error.message };
      case "rate-limited":
        return { status: "rate-limited" };
      case "invalid":
        return { status: "invalid", message: error.message };
      case "network-error":
        return { status: "network-error", message: error.message };
    }
  }
  return {
    status: "network-error",
    message: error instanceof Error ? error.message : "Unknown error",
  };
}

/**
 * The submit-then-poll state machine, factored out of the `useRun` hook so it
 * can be unit-tested without a DOM or a React renderer: every effectful
 * dependency (getting a token, the two HTTP calls, sleeping, the clock) is
 * injected, so tests substitute instant, deterministic fakes for all of them
 * — including a fake clock for `now`, which is what makes the 60s
 * give-up-polling case and the 10s backoff threshold testable without
 * actually waiting.
 */
export type RunAndPollDeps = {
  getAccessToken: () => Promise<string | null>;
  submitRun: typeof submitRun;
  getRun: typeof getRun;
  sleep: (ms: number, signal: AbortSignal) => Promise<void>;
  now: () => number;
};

const defaultDeps: RunAndPollDeps = {
  getAccessToken: realGetAccessToken,
  submitRun,
  getRun,
  sleep: realSleep,
  now: () => Date.now(),
};

export async function runAndPoll(
  apiBaseUrl: string,
  language: string,
  code: string,
  signal: AbortSignal,
  onState: (state: RunHookState) => void,
  deps: RunAndPollDeps = defaultDeps,
): Promise<void> {
  onState({ status: "submitting" });
  try {
    const token = await deps.getAccessToken();
    if (signal.aborted) return;
    if (!token) {
      onState({ status: "unauthenticated" });
      return;
    }

    const { job_id: jobId } = await deps.submitRun(
      apiBaseUrl,
      token,
      { language, code },
      signal,
    );
    if (signal.aborted) return;

    onState({ status: "polling" });
    const startedAt = deps.now();

    for (;;) {
      const elapsed = deps.now() - startedAt;
      if (elapsed >= GIVE_UP_AFTER_MS) {
        onState({ status: "still-running" });
        return;
      }

      const pollToken = await deps.getAccessToken();
      if (signal.aborted) return;
      if (!pollToken) {
        onState({ status: "unauthenticated" });
        return;
      }

      const outcome = await deps.getRun(apiBaseUrl, pollToken, jobId, signal);
      if (signal.aborted) return;
      if (outcome.kind === "finished") {
        onState({ status: "finished", result: outcome.result });
        return;
      }

      const interval = elapsed < BACKOFF_AFTER_MS ? FAST_POLL_MS : SLOW_POLL_MS;
      await deps.sleep(interval, signal);
    }
  } catch (error) {
    if (isAbortError(error) || signal.aborted) return;
    onState(stateForError(error));
  }
}

/**
 * Submits code to the playground API and polls for its result. Lives in its
 * own hook, not inside a component, per stage 5 of the implementation plan —
 * this is a thin React wrapper around `runAndPoll`'s state machine.
 */
export function useRun(apiBaseUrl: string) {
  const [state, setState] = useState<RunHookState>({ status: "idle" });
  const controllerRef = useRef<AbortController | null>(null);

  // Cancel any in-flight submit/poll on unmount so a late response never
  // calls setState after the component is gone.
  useEffect(() => {
    return () => controllerRef.current?.abort();
  }, []);

  const cancel = useCallback(() => {
    controllerRef.current?.abort();
    controllerRef.current = null;
    setState({ status: "idle" });
  }, []);

  const run = useCallback(
    (language: string, code: string) => {
      controllerRef.current?.abort();
      const controller = new AbortController();
      controllerRef.current = controller;
      void runAndPoll(apiBaseUrl, language, code, controller.signal, setState);
    },
    [apiBaseUrl],
  );

  return { state, run, cancel };
}
