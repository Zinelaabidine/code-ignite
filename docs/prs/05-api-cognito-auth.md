# PR 5 — Cognito access-token verification, ownership, CORS, and rate limiting

**Branch:** `feat/api-cognito-auth`
**Commit:** `feat(backend): verify cognito access tokens and scope runs to their owner`
**Stage:** 3 of `docs/code-playground-implementation-plan.md`.
**Status:** done, verified locally — ruff, mypy `--strict`, and the full
non-Docker test suite all pass (one pre-existing, unrelated failure noted
below). Not yet committed or pushed. No real Cognito pool or deployed API in
this environment — the two new config values are exercised only through unit
tests against a locally-signed JWT and a monkeypatched JWKS lookup; see
"Verification".

## What this is

Closes the two gaps PR 4 flagged explicitly under "what's deliberately not
here": `POST /runs` and `GET /runs/{job_id}` now require a verified Cognito
**access** token (not the ID token), `user_sub` goes from always-`None` to
the token's real `sub`, and `GET /runs/{job_id}` returns `404` — not the
result — for a job that either doesn't exist or belongs to someone else.
Also added: an explicit CORS origin allowlist on the FastAPI app, and a
per-`sub` in-process rate limit on job submission.

Nothing here touches the worker, the storage layer, or Terraform — the
Cognito User Pool and app client already exist
(`infra/modules/static-site/auth.tf`); this PR only reads their IDs.

## Files

### Added

| Path | Purpose |
| --- | --- |
| `backend/src/codeignite/api/auth.py` | `get_current_sub` — the FastAPI dependency that verifies the bearer token via `PyJWKClient` and returns its `sub` |
| `backend/src/codeignite/api/rate_limit.py` | `RateLimiter` Protocol, `InProcessTokenBucketLimiter`, `enforce_rate_limit` (composes auth + throttling for `POST /runs`) |
| `backend/tests/test_auth.py` | 9 tests: valid token, missing header, wrong scheme, garbage token, expired, wrong pool, ID token instead of access, wrong client, missing `sub` |
| `docs/prs/05-api-cognito-auth.md` | This file |

### Modified

| Path | Change |
| --- | --- |
| `backend/src/codeignite/config.py` | `cognito_user_pool_id`, `cognito_client_id` now required (no default, same pattern as the SQS/S3 fields); `cors_allowed_origins` added with a `localhost:3000` default |
| `backend/src/codeignite/api/routes_runs.py` | `submit_run` depends on `enforce_rate_limit` and stamps the real `sub` into `JobInput`; `get_run` depends on `get_current_sub`, fetches the stored input via a new `RunsGateway.get_input`, and 404s before ever calling `get_result` if the input is missing or owned by someone else |
| `backend/src/codeignite/api/app.py` | `CORSMiddleware`: explicit origin allowlist from config, `GET/POST/OPTIONS`, `allow_credentials=False` |
| `backend/pyproject.toml` | Added `pyjwt[crypto]`; `pytest-env` placeholders for the two new required settings |
| `backend/docker-compose.yml` | Both `api` and `worker` services now require the two Cognito env vars — see the design note below on why the worker needs them too |
| `backend/tests/conftest.py` | `FakeRunsGateway.get_input`; the shared `client` fixture now overrides `get_current_sub` (fixed fake `sub`) and `get_rate_limiter` (fresh, high-capacity limiter) so existing route tests don't need real tokens |
| `backend/tests/test_routes_runs.py` | Existing `get_run` tests updated to seed an owned `JobInput` first (ownership is now checked before "pending" is even possible); 8 new tests for 401/404/429 built on their own `TestClient`s that leave the real auth/rate-limit dependencies wired in |
| `backend/.env.example`, `backend/README.md` | Document the two new required vars and the auth/CORS/rate-limit behavior |

## Design notes worth flagging on review

- **`verify_aud` is off, `client_id` is checked by hand.** Cognito access
  tokens carry no `aud` claim — ID tokens do, access tokens put the audience
  equivalent in `client_id` instead. Leaving `verify_aud` on with no `aud`
  to check would either silently no-op or reject every valid token depending
  on PyJWT's version behavior; turning it off and checking `claims["client_id"]
  == settings.cognito_client_id` explicitly makes the intent visible instead
  of relying on that behavior.
- **`_unauthenticated()` returns a fresh `HTTPException` per call, not a
  module-level constant.** The first draft had one shared instance; `raise
  ... from error` mutates `__cause__` on the exception object, and under
  concurrent requests two overlapping 401s sharing one instance could race
  on that mutation. A one-line factory function avoids it entirely.
- **`RunsGateway` gained `get_input`, not just `auth.py`.** The ownership
  check needs the job's stored `user_sub`, but `objects.get_result` only
  ever persisted the `RunResult` fields — `user_sub` lives in `input.json`,
  not `result.json`. This was the one non-obvious ripple: `get_run` now
  reads the input first and 404s before it ever asks whether a result
  exists, so a job that's still pending and a job that was never submitted
  are indistinguishable from the outside.
- **404, never 403, for both "no such job" and "not your job."** Per the
  implementation plan directly: job IDs are 128-bit UUIDs, effectively
  unguessable, but a 403 would confirm a guessed ID is live. Both branches
  of `get_run`'s ownership check raise the identical `HTTPException(404)`.
- **Only `POST /runs` is rate-limited.** `GET /runs/{job_id}` is polled every
  500 ms by the (future) frontend; metering it would make normal polling
  trip the limiter. `enforce_rate_limit` wraps `get_current_sub` and is used
  only on submission — `get_run` depends on `get_current_sub` directly.
- **The rate limiter is a `Protocol` + one in-process implementation,
  deliberately.** Per the plan: "shared-state limiting lands with EKS; the
  interface is what matters now." `InProcessTokenBucketLimiter` is
  per-replica and resets on restart — known and accepted for a
  single-instance local deployment.
- **`docker-compose.yml` needed both Cognito vars on the *worker* too**,
  even though the worker never checks them. `codeignite.config.Settings()`
  is instantiated eagerly at module import time, and every process —
  worker included — transitively imports `codeignite.config`. Missing
  either var would fail the worker container at startup with a validation
  error that has nothing to do with what the worker actually does; easy to
  miss until you actually try `docker compose up`.
- **`conftest.py`'s `client` fixture overrides `get_current_sub` and
  `get_rate_limiter`, not `enforce_rate_limit` itself.** Overriding the
  latter would bypass its logic entirely; overriding its two sub-dependencies
  instead means the real rate-limit check still runs in every existing
  route test, just against a fixed fake `sub` and a limiter with enough
  headroom (capacity 1000) that no ordinary test suite run empties it.
  `test_submit_run_is_rejected_once_the_rate_limit_bucket_is_empty` is the
  one test that deliberately uses a small, explicitly shared limiter
  instance to prove the block actually happens — the first version of that
  test used `lambda: InProcessTokenBucketLimiter(capacity=2)` as the
  override, which hands every request a *brand-new* bucket and never
  triggers a 429; fixed by constructing the limiter once and returning that
  same instance from the override.

## Verification

Ran from `backend/`, in a scratch venv (this repo's own `backend/.venv` has a
Python symlink pointing at a different machine's path and doesn't run here —
unrelated to this PR, left untouched):

```bash
ruff format --check .   # 31 files already formatted
ruff check .            # All checks passed!
mypy --strict src       # Success: no issues found in 19 source files
pytest -m "not docker"  # 72 passed, 1 failed, 5 deselected
```

The one failure, `test_worker_loop.py::test_a_poisoned_message_is_left_on_the_queue_for_redelivery`,
is in a file this PR does not touch (`worker/loop.py` and `storage/queue.py`
are unchanged) and reproduces identically against unmodified `HEAD` — a
pre-existing moto/SQS-version quirk, not a regression from this PR. Left as
noted rather than fixed, since `worker/loop.py` is outside stage 3's scope.

**Not verified at all:** a real `docker compose up` against a real Cognito
pool and a browser-issued access token — no deployed pool or AWS credentials
in this environment. Please run the `curl` sequence in `backend/README.md`
with a real `Authorization: Bearer <accessToken>` header (from
`fetchAuthSession()` in a browser console against the actual frontend, since
there's no CLI flow for it) before merging.

## What's deliberately not here

- **No infra changes.** The User Pool and app client already exist; this PR
  only consumes their IDs via two new required config fields.
- **No shared/distributed rate limiting.** In-process only, per the plan —
  real shared state is an EKS-era concern.
- **No frontend changes.** The frontend doesn't attach an `Authorization`
  header yet — every request from stage 4/5's not-yet-built UI would 401
  against this PR's API until the frontend work (`feat/frontend-env-api-url`,
  `feat/playground-ui`) lands. Expected: stages 4/5 come after this one in
  the plan's numbering specifically because they need a real API to talk to.
- **`CLAUDE.md`'s architecture section still says "no backend API."** That's
  been stale since PR 4 (stage 2) and is explicitly PR 9's job
  (`docs/update-architecture`) in the suggested sequence, not this one's —
  noting it here so it doesn't get lost, not fixing it out of scope.

## Next

PR 6 (`feat/frontend-env-api-url`): add an optional `NEXT_PUBLIC_API_BASE_URL`
to `frontend/lib/env.ts` (via an `optional()` helper alongside `required()`)
so the frontend can start pointing at this API without breaking the deployed
site's build, which has nowhere to point yet.
