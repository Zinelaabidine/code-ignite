# PR 6 — Frontend env plumbing: optional API base URL

**Branch:** `feat/frontend-env-api-url`
**Commit:** `feat(frontend): add optional api base url to the env contract`
**Stage:** 4 of `docs/code-playground-implementation-plan.md`.
**Status:** done, verified locally — `test`, `typecheck`, `lint`,
`format:check`, and `build` all pass. Not yet committed or pushed. No
hosted API in this environment (or anywhere yet — see PR 5's "what's
deliberately not here"), so `NEXT_PUBLIC_API_BASE_URL` is exercised only
against a fake value in `env.test.ts` and left unset for the real build.

## What this is

The small, boring step the implementation plan calls out as its own PR
specifically because it's "where the build breaks": adds an **optional**
`NEXT_PUBLIC_API_BASE_URL` to the frontend's env contract, alongside the
three variables (`region`, `userPoolId`, `userPoolClientId`) that are
already required. Making it required today would break `ci.yml`'s build
step and `deploy.yml` immediately — there's no hosted API for the deployed
site to point at yet (PR 5's "what's deliberately not here" says as much).
`lib/env.ts` gets a new `optional()` helper, parallel to `required()`, that
resolves a missing value to `null` instead of failing the build.

This PR does not touch the playground UI — there's no route to render an
"not available in this environment" panel yet. That's PR 7. This PR only
makes `env.apiBaseUrl: string | null` exist and be wired through CI/deploy,
so PR 7 has something to read.

## Files

### Added

| Path | Purpose |
| --- | --- |
| `frontend/lib/env.test.ts` | 4 tests: all-required-missing throws naming every var, one-required-missing throws naming it, `apiBaseUrl` resolves to `null` when unset, resolves to the string when set |
| `docs/prs/06-frontend-env-api-url.md` | This file |

### Modified

| Path | Change |
| --- | --- |
| `frontend/lib/env.ts` | New `optional()` helper; `PublicEnv.apiBaseUrl: string \| null`; reads `NEXT_PUBLIC_API_BASE_URL` |
| `frontend/.env.example` | Documents the new optional var, with a comment pointing it at the local backend (`docker compose up` in `backend/`) |
| `.github/workflows/ci.yml` | Frontend build step's `env:` block documents the var and leaves it unset — proves the optional path builds clean with no hosted API |
| `.github/workflows/deploy.yml` | Build step reads `NEXT_PUBLIC_API_BASE_URL` from a new `vars.API_BASE_URL` repo variable (empty until there's somewhere to point it); header comment documents it alongside the other optional per-environment overrides |

## Design notes worth flagging on review

- **`optional()` treats an empty string the same as unset.** Same as
  `required()`'s `if (!value)` check — a repo variable that exists but is
  blank (the common case for `vars.API_BASE_URL` until stage 6 gives it a
  real value) must resolve to `null`, not to `""`, or the playground would
  render a broken fetch target instead of the "not available" panel.
- **No default value, ever.** `optional()` has no second parameter for a
  fallback string. Inventing a URL — even `http://localhost:8000` — as a
  silent default would mean a misconfigured deploy quietly tries to reach
  a backend that isn't there, instead of the caller being able to tell
  "not configured" from "configured wrong."
- **Testing a module that throws at import time.** `env.ts` runs its
  validation at module load, not inside a function, so `env.test.ts` can't
  just call something and assert a thrown error — it has to force a fresh
  module evaluation per test. Each test calls `vi.stubEnv(...)` to set
  `process.env`, then `vi.resetModules()` + a fresh dynamic `import("./env")`,
  and asserts on the resulting promise (`rejects.toThrow(...)` for the
  missing-required cases, the resolved `env` object otherwise).
  `afterEach` calls `vi.unstubAllEnvs()` so one test's stubbed env never
  leaks into the next.
- **`vi.stubEnv(name, "")`, not `undefined`.** `vitest`'s env stubbing
  writes a real string into `process.env`; there's no clean way to make a
  key actually absent mid-suite. An empty string exercises the identical
  `if (!value)` branch as a genuinely missing variable, so the test still
  proves the right thing without fighting the API.
- **`ci.yml` and `deploy.yml` both got a comment, not just a value.** Per
  the plan: update `.env.example`, both workflows, and the test file "in
  the same commit so they cannot drift." The var doesn't need a value in
  either workflow today (CI has no API to point at; deploy has no
  `API_BASE_URL` variable configured), so the comments are what keeps the
  contract visible — a future PR adding a real required var next to this
  one will see the pattern already there instead of rediscovering it.

## Verification

Ran from `frontend/`. The default shell `node` here is v22.11.0
(`nvm`'s configured default), but `vitest.config.ts` requires Node's
native ESM loader for `vite` — v22 throws `ERR_REQUIRE_ESM` before a
single test runs, unrelated to this PR. Switched to the `.nvmrc`-pinned
v24.19.0 (already installed via `nvm`, no download needed) for everything
below:

```bash
nvm use 24.19.0
npm run test           # 2 files, 12 passed (8 pre-existing + 4 new)
npm run typecheck       # clean
npm run lint            # clean
npm run format:check    # clean
NEXT_PUBLIC_AWS_REGION=us-east-1 \
NEXT_PUBLIC_USER_POOL_ID=us-east-1_ciplaceholder \
NEXT_PUBLIC_CLIENT_ID=ciplaceholderclientid000000 \
npm run build            # succeeds with NEXT_PUBLIC_API_BASE_URL unset —
                          # the exact case ci.yml's build step exercises
```

**Not verified at all:** an actual `ci.yml`/`deploy.yml` run on GitHub
Actions (no CI trigger from this environment) and a real
`vars.API_BASE_URL` value flowing through `deploy.yml` end to end — there
is nothing to point it at yet. Please confirm the PR's CI run is green
before merging, per the gate in `docs/code-playground-implementation-plan.md`'s
PR table (`CI green`).

## What's deliberately not here

- **No playground UI.** `apiBaseUrl` has no reader yet; the "not available
  in this environment" panel the plan describes for stage 4 is stage 5's
  `PlaygroundShell`/`OutputPane` work, in PR 7.
- **No real `API_BASE_URL` value.** `vars.API_BASE_URL` is referenced in
  `deploy.yml` but not configured in any GitHub environment — there's no
  hosted API for it to point at (see PR 5's "what's deliberately not
  here" and the implementation plan's §8, "a hosted API").
- **`CLAUDE.md`'s architecture section still says "no backend API."**
  Unchanged since PR 4/5 flagged it; still explicitly PR 9's job
  (`docs/update-architecture`), not this one's.

## Next

PR 7 (`feat/playground-ui`): the route group behind `<AuthGate>`, the
CodeMirror editor, the submit/poll hook, and the output pane — the first
consumer of `env.apiBaseUrl`, rendering the honest "not available in this
environment" panel when it's `null`.
