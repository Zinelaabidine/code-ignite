# PR 7 — Playground UI: route group, editor, polling hook, output pane

**Branch:** `feat/playground-ui`
**Commit:** `feat(frontend): add playground route, editor, and run polling`
**Stage:** 5 of `docs/code-playground-implementation-plan.md`.
**Status:** done, verified locally — `build`, `lint`, `typecheck`, `test`,
`format:check`, and `npm audit --audit-level=high` all pass. Not yet pushed.
No hosted API in this environment (or anywhere yet), so the actual
submit-code-see-output flow is verified only through `useRun`'s unit tests
against fakes, not against a running `backend/`. See "Verification".

## What this is

The first consumer of PR 6's `env.apiBaseUrl`: an authenticated `/playground`
route with a CodeMirror editor, a language picker, a run button, and an
output pane that submits code to the API and polls for its result. This is
also where `types/runs.ts` is born — the TypeScript mirror of the backend's
Pydantic models the plan calls for, kept in this PR so any drift between
them is visible in this one diff.

Per the plan's note on `AuthGate`: it now lives in a new `app/(app)/layout.tsx`
group layout rather than only inside `app/page.tsx`, so it mounts once per
authenticated segment instead of once per page. `app/page.tsx` (the landing
route) is untouched.

## Files

### Added

| Path | Purpose |
| --- | --- |
| `frontend/types/runs.ts` | `RunStatus`, `RunResult`, `RunRequest`, `SubmitRunResponse`, `RunOutcome` — mirror `codeignite.api.routes_runs`/`runner.base` field-for-field; `SUPPORTED_LANGUAGES` (hand-mirrors `domain/languages.py`, one entry: python) |
| `frontend/lib/runs/client.ts` | `submitRun`, `getRun`, `RunApiError`, `isAbortError` — typed fetch wrapper; takes a bearer token as a parameter rather than fetching one itself |
| `frontend/lib/runs/useRun.ts` | `runAndPoll` (dependency-injected state machine) + `useRun` (the React hook wrapping it) — submit, then poll at 500ms/1500ms with a 60s give-up, per stage 5 |
| `frontend/lib/runs/useRun.test.ts` | 6 tests: success, give-up-after-60s honoring the 10s backoff, clean abort mid-poll, no-session → unauthenticated, 401-from-API → unauthenticated, rate-limit/network-error mapping |
| `frontend/components/playground/PlaygroundShell.tsx` | `"use client"` layout: language state, code state, wires `useRun`, dynamically imports `EditorPane` |
| `frontend/components/playground/EditorPane.tsx` | CodeMirror (`@uiw/react-codemirror` + `@codemirror/lang-python`), loaded via `next/dynamic(..., { ssr: false })` by its caller |
| `frontend/components/playground/LanguageSelect.tsx` | Native `<select>` over `SUPPORTED_LANGUAGES` |
| `frontend/components/playground/RunButton.tsx` | Wraps `components/ui/button.tsx`; disabled + spinner while submitting/polling |
| `frontend/components/playground/OutputPane.tsx` | Renders the four run outcomes distinctly, plus the UI-level states (still-running, unauthenticated, rate-limited, invalid, network-error); `stdout`/`stderr` in `<pre>`, never `dangerouslySetInnerHTML` |
| `frontend/components/playground/StatusBadge.tsx` | One label/tone/icon per reachable state — the single source of truth `OutputPane` and `RunButton` both read from |
| `frontend/app/(app)/layout.tsx` | `<AuthGate>` for the authenticated route group |
| `frontend/app/(app)/playground/page.tsx` | Server Component; renders the "not available in this environment" panel when `env.apiBaseUrl` is `null`, otherwise `<PlaygroundShell>` |
| `docs/prs/07-playground-ui.md` | This file |

### Modified

| Path | Change |
| --- | --- |
| `frontend/components/home/SignedInHome.tsx` | Adds an "Open playground" link (`Button` composed with `next/link` via Base UI's `render` prop) — the landing page's only way to reach the new route |
| `frontend/app/globals.css` | Two new tokens, `--nord-warning`/`--nord-warning-tint`, for the timeout/rate-limit/invalid states — the existing palette only had success/danger, not enough to keep "timed out" visually distinct from "crashed" |
| `frontend/package.json`, `frontend/package-lock.json` | Adds `@uiw/react-codemirror@4.25.11` and `@codemirror/lang-python@6.2.1`, both exact-pinned per the plan's §0 note on this being the largest new dependency surface so far |

## Design notes worth flagging on review

- **`runAndPoll` is a plain, dependency-injected async function; `useRun` is
  a thin wrapper around it.** `vitest.config.ts` runs with
  `environment: "node"` — no DOM — and this repo has no
  `@testing-library/react`/jsdom today. Rather than add that infrastructure
  for one hook, the submit-then-poll state machine takes every effectful
  dependency as a parameter (`getAccessToken`, `submitRun`, `getRun`,
  `sleep`, `now`), so the test file drives it directly with instant fakes —
  including a fake clock for `now()`, which is what makes the 60s
  give-up-polling and 10s backoff cases assertable without real waiting or
  fake-timer/DOM machinery. `useRun` itself (the `"use client"` hook a
  component actually calls) is three lines of glue over it.
- **Fresh token per HTTP call, not per run.** `getAccessToken()` (wrapping
  `fetchAuthSession()`) is called before *every* `submitRun`/`getRun`, not
  cached once at the top of `run()` — a poll loop that runs for up to a
  minute must not send a token that expired partway through. Per the plan:
  "never cache a token in component state."
- **`getRun` distinguishes pending from finished by HTTP status, not response
  shape.** `codeignite.api.routes_runs.get_run` returns 202 for pending and
  200 for a result — checking `response.status === 202` matches the actual
  contract; checking for an `exit_code` field in the body would work today
  but silently break if the pending/finished shapes ever converge.
- **Base UI's `Button` uses a `render` prop, not `asChild`.** Composing the
  "Open playground" button with `next/link` needed
  `render={<Link href="/playground" />}` plus `nativeButton={false}` (Base
  UI's own naming — see `@base-ui/react/internals/types.d.ts`), not the
  Radix-style `asChild` prop shadcn docs elsewhere might suggest; this
  project's `components/ui/button.tsx` wraps `@base-ui/react/button`, a
  different headless library with a different composition API.
- **`LanguageSelect` is a native `<select>`, not a new shadcn component.**
  `SUPPORTED_LANGUAGES` has exactly one entry — installing/theming a full
  combobox for one option would be premature. Revisit when stage 6 (more
  languages) actually adds a second one.
- **The "not available in this environment" check lives in a Server
  Component, not inside `PlaygroundShell`.** `env.apiBaseUrl` is a
  build-time constant, inlined identically into the server and client
  bundles — unlike Cognito's `authStatus` in `AuthGate`, which genuinely
  differs between server and client and must defer past hydration, this
  check has no hydration-mismatch risk and needs no client-side deferral.
  `app/(app)/playground/page.tsx` branches on it directly and only mounts
  the `"use client"` shell when an API is actually configured.
- **`EditorPane.tsx` itself is not marked `ssr: false`** — that flag belongs
  to whoever calls `next/dynamic`, not the component. `PlaygroundShell`
  dynamically imports it; the file stays a plain (if browser-only)
  `"use client"` component so it can also be imported directly if a test
  ever needs to.
- **Two badge colors carry four distinct statuses.** `ok`/`timeout`/`oom`/
  `error` each get their own label and icon (`CheckCircle2`, `Clock`, `Zap`,
  `Bug`), but `oom` and `error` share the danger red — the stage 5 checklist
  asks each to "render distinctly and be reachable in manual test," which a
  distinct icon + label already satisfies without inventing a fifth
  semantic color for one rare state. `timeout` got the new warning token
  instead of sharing danger, since "timed out" reads more like a caution
  than a crash.

## Verification

Ran from `frontend/` on Node v24.19.0 (the shell's default v22.11.0 throws
`ERR_REQUIRE_ESM` loading `vitest.config.ts` — same environment note as
PR 6):

```bash
nvm use 24.19.0
npm run test             # 3 files, 18 passed (12 pre-existing + 6 new)
npm run typecheck        # clean
npm run lint             # clean
npm run format:check     # clean
npm audit --audit-level=high   # found 0 vulnerabilities
NEXT_PUBLIC_AWS_REGION=us-east-1 \
NEXT_PUBLIC_USER_POOL_ID=us-east-1_ciplaceholder \
NEXT_PUBLIC_CLIENT_ID=ciplaceholderclientid000000 \
npm run build             # succeeds, /playground prerendered as static —
                           # this is the "not available" panel path (ci.yml's case)
# Repeated with NEXT_PUBLIC_API_BASE_URL=http://localhost:8000 set too —
# also succeeds, /playground still prerendered static (the PlaygroundShell
# path, dynamic-imported CodeMirror included).
```

**Not verified at all:** an actual signed-in browser session hitting a
running `backend/` — no Cognito pool, no `docker compose up`, no AWS
credentials in this environment. Please run both stacks together and walk
through the stage 5 checklist by hand before merging:

```bash
cd backend && docker compose up
cd frontend && NEXT_PUBLIC_API_BASE_URL=http://localhost:8000 npm run dev
```

Then, signed in: edit Python, click Run, confirm each of the four output
states is reachable (an infinite loop for timeout, a large allocation for
oom, a raised exception for error, `print(...)` for ok), confirm the
truncation notice appears for a program that prints past the 64 KiB cap, and
confirm no token appears in `localStorage`/`sessionStorage` at any point.

## What's deliberately not here

- **No new languages.** `SUPPORTED_LANGUAGES` has one entry because
  `domain/languages.py` has one entry — stage 6 (`feat/more-languages`)
  adds both sides together.
- **No `GET /languages` endpoint.** The frontend list is hand-maintained
  against the backend registry rather than fetched, per `types/runs.ts`'s
  comment; revisit if keeping them in sync by hand ever actually drifts.
- **No run history / past-runs list.** Explicitly deferred in the
  implementation plan §8 ("a database... arrives with history, not now").
- **No WebSocket upgrade.** Polling only, per §8's explicit rejection of
  WebSockets until connection count is a real cost.
- **`CLAUDE.md`'s architecture section still says "no backend API."** Still
  flagged, still not this PR's job — PR 9 (`docs/update-architecture`).

## Next

PR 8 (`feat/more-languages`): add Node (and optionally Go) to
`domain/languages.py`, pin images by digest, and add the matching entries to
`SUPPORTED_LANGUAGES` and `EditorPane`'s language-extension map in the same
commit so the two registries can't drift, per stage 6 checklist.
