# Code playground — implementation plan

Companion to `code-playground-plan.md`, which sets the architecture. This file
is the execution plan: what to build, in what order, in which files, and what
"done" means for each step.

**Scope of phase 1:** API and worker run locally via Docker Compose against
**real** AWS SQS and S3. The deployed site keeps its current behaviour until an
API is actually hosted (stage 6). Credentials come from the existing local-dev
IAM role — no access keys are created and nothing new is committed.

**Current state:** static Next.js export + Cognito. No backend, no API, no
queue. `backend/` contains only a README.

---

## 0. Ground rules for this work

Carried from `CLAUDE.md`; repeated because every stage below depends on them.

- Application code goes in `backend/`. AWS resources go in `infra/`, one `.tf`
  file per service. Never inline logic into Terraform.
- New AWS surface → new module under `infra/modules/`, wired from the
  environment roots. Do not bolt SQS/S3-for-jobs onto `static-site` — that
  module is about serving a website.
- No wildcards in IAM `actions`. No wildcard `resources` where an ARN is
  knowable at plan time; any genuine exception carries a comment saying why.
- Every new S3 bucket gets all four companions (public access block, ownership
  controls, SSE, versioning) plus a TLS-only deny.
- Nothing identifying is committed. New config follows the existing
  `terraform.tfvars` / `TF_VAR_*` pattern; new backend config follows a
  `.env.example` pattern.
- Every stage ends green on `./scripts/pre-commit-check.sh`.

### Two risks to name up front

**The Docker socket is the trust boundary.** A worker that can talk to
`/var/run/docker.sock` is effectively root on the host. It runs untrusted code
by design. Therefore: the worker never listens on a port, never parses an
HTTP request, and is never exposed to the network. Its only input is a job ID
pulled from SQS, and its only authority is what the container flags allow.
This is why the split in stage 2 is not optional busywork — it keeps the
socket-holding process off the request path.

**There is no Content-Security-Policy** (see `CLAUDE.md` §5 for why). Cognito
tokens live in JS-readable cookies, so every new frontend dependency is a
potential token-exfiltration path. The editor library added in stage 5 is the
largest new dependency surface this project has taken on — pin it exactly,
review its transitive tree, and keep `npm audit --audit-level=high` passing.

---

## 1. Stage 1 — sandbox skeleton, no queue

**Goal:** `curl` → `print("hi")` → `"hi"`, executed inside a locked-down
container. No auth, no queue, no S3, no frontend.

**Why first:** it proves the sandbox flags work on your machine (Docker
Desktop on macOS behaves differently from Linux for `--memory` and cgroups)
before any distributed machinery hides the failure.

### Stack choice

Python 3.12, FastAPI + Uvicorn, `uv` for dependency management, `ruff` for
lint+format, `mypy --strict` for types, `pytest` for tests. The strictness
mirrors the frontend's `strict: true` contract, so the two halves feel the
same. `boto3` arrives in stage 2, not now.

### Files

```
backend/
├── pyproject.toml              # deps, ruff, mypy, pytest config
├── .env.example                # documented, committed
├── .python-version
├── Dockerfile.api
├── Dockerfile.worker           # stage 2
├── docker-compose.yml          # stage 2
├── README.md                   # rewrite: how to run it
├── src/codeignite/
│   ├── __init__.py
│   ├── config.py               # env contract — the lib/env.ts of the backend
│   ├── domain/
│   │   ├── models.py           # RunRequest, RunResult, RunStatus
│   │   └── languages.py        # LANGUAGES registry
│   ├── runner/
│   │   ├── base.py             # Runner Protocol + RunResult
│   │   └── local_docker.py     # LocalDockerRunner
│   └── api/
│       ├── app.py              # create_app() factory
│       └── routes_runs.py
└── tests/
    ├── test_languages.py
    ├── test_local_docker.py    # @pytest.mark.docker
    └── test_routes_runs.py     # fake Runner, no Docker
```

### The interface (write this before the implementation)

`runner/base.py` holds exactly the `Runner` Protocol and `RunResult` from
`code-playground-plan.md`. Nothing imports `local_docker` except the composition
root in `config.py` / `app.py`. Every test outside `test_local_docker.py` uses a
fake `Runner`. This is what makes stage 6's `KubernetesJobRunner` a one-line
swap, and it is also what keeps the test suite fast.

### `LocalDockerRunner` — the details that matter

- Build the argv as a **list**. Never `shell=True`, never string interpolation
  of user input into a command.
- `language` is a key lookup into `LANGUAGES`; an unknown key is a 400, never a
  value that reaches Docker.
- Write the source to a fresh temp dir, mount it `:ro`, delete it in a
  `finally`.
- Flags exactly as in the architecture doc: `--rm --network none --memory 256m
  --memory-swap 256m --cpus 0.5 --read-only --tmpfs /tmp:size=16m --user 65534
  --pids-limit 64 --cap-drop ALL --security-opt no-new-privileges`.
  (`--memory-swap` equal to `--memory` prevents swapping around the limit;
  `--pids-limit` stops a fork bomb; both map onto Kubernetes later.)
- **Two timeout layers.** `timeout 8` inside the container, and
  `subprocess.run(..., timeout=15)` outside it. The inner one handles a
  runaway program; the outer one handles a wedged Docker daemon. If the outer
  one fires, kill the container by name — hence give every run a
  `--name job-{job_id}`.
- **Cap the output.** Read at most 64 KiB each of stdout/stderr and mark the
  result truncated. A program that prints in a loop will otherwise fill memory
  in the worker, not in the sandbox.
- Map exit codes: `124` → `timeout`, `137` → `oom` (verify against
  `docker inspect .State.OOMKilled` where available; `137` is also plain
  SIGKILL), non-zero otherwise → `error` with the program's own exit code
  preserved in `exit_code`.
- Never let a runner exception escape as a 500 — convert to
  `RunResult(status="error")` so callers always get a shaped result.

### API

`POST /runs` → runs synchronously, returns the `RunResult` as JSON.
`GET /healthz` → `{"status":"ok"}`.
Request body validated by Pydantic with a hard `max_length` on `code`
(64 KiB) and `language` as a `Literal` of registry keys.

### Definition of done

- [ ] `docker compose run api` (or `uv run uvicorn`) serves on `:8000`
- [ ] `curl -X POST :8000/runs -d '{"language":"python","code":"print(\"hi\")"}'`
      returns `stdout: "hi\n"`, `status: "ok"`
- [ ] An infinite loop returns `status: "timeout"` in under 10 s
- [ ] A 512 MB allocation returns `status: "oom"`
- [ ] `import socket; socket.create_connection(("1.1.1.1",80))` fails —
      network really is off
- [ ] `open("/etc/passwd","w")` fails — root filesystem really is read-only
- [ ] `ruff format --check`, `ruff check`, `mypy --strict`, `pytest` all pass

Commit: `feat(backend): add sandboxed local docker runner and sync run endpoint`

---

## 2. Stage 2 — split via SQS + S3

**Goal:** identical behaviour, now asynchronous. Same API surface the EKS
version will have.

### 2a. Terraform first

New module `infra/modules/run-pipeline/`, file-per-concern:

| File | Contents |
| --- | --- |
| `versions.tf` | provider constraints, matching the other modules |
| `variables.tf` | `project_name`, `environment`, plus the knobs below |
| `locals.tf` | `name_prefix` |
| `sqs.tf` | runs queue |
| `sqs-dlq.tf` | dead-letter queue + redrive policy |
| `s3-jobs.tf` | jobs bucket + the four required companions + lifecycle |
| `s3-jobs-policy.tf` | TLS-only deny |
| `iam-runtime.tf` | `run-api` and `run-worker` managed policies |
| `outputs.tf` | queue URL, queue ARN, bucket name, policy ARNs |

Settings that are decisions, not defaults:

- `visibility_timeout_seconds = 60` — comfortably above the 10 s execution
  ceiling, per the architecture doc.
- `receive_wait_time_seconds = 20` — long polling. Short polling burns through
  the 1M-request free tier for nothing.
- `redrive_policy { maxReceiveCount = 2 }` → DLQ. A job that kills the worker
  must not be redelivered forever.
- `message_retention_seconds`: 4 hours on the main queue (a job nobody
  collected is worthless), 14 days on the DLQ (that is the debugging record).
- `sqs_managed_sse_enabled = true`.
- Jobs bucket: lifecycle expiration at 7 days on `jobs/`, plus
  `abort_incomplete_multipart_upload`. Jobs are ephemeral; this is both hygiene
  and cost control.
- Do **not** put `prevent_destroy` on the jobs bucket. It holds no durable
  state, and the rule in `CLAUDE.md` is about stateful resources.

**IAM — two policies, not one.** The API and the worker have genuinely
different rights, and writing them separately now is what makes the EKS task
roles correct later:

| | S3 | SQS |
| --- | --- | --- |
| `run-api` | `PutObject`, `GetObject` on `<bucket>/jobs/*` | `SendMessage`, `GetQueueUrl` |
| `run-worker` | `GetObject`, `PutObject` on `<bucket>/jobs/*` | `ReceiveMessage`, `DeleteMessage`, `ChangeMessageVisibility`, `GetQueueAttributes` |

Both scoped to the exact queue ARN and the exact `jobs/*` prefix. No `s3:*`,
no `sqs:*`, no bucket-level `Delete`.

**Wiring:** call the module from `infra/envs/dev/main.tf` only, for now. Add a
`attach_runtime_policies_to_local_dev_role` variable following the exact
pattern and warning of the existing `attach_deploy_policies_to_local_dev_role`
— account-global role, so exactly one environment may own the attachment.
Staging and prod get the module when there is somewhere to run the worker.

Commit: `feat(infra): add run pipeline module with sqs queue, dlq and jobs bucket`

### 2b. Backend split

New files:

```
src/codeignite/storage/objects.py   # put_input, get_input, put_result, get_result
src/codeignite/storage/queue.py     # send_job, receive_jobs, delete_job, extend_visibility
src/codeignite/worker/loop.py       # the poll loop
src/codeignite/worker/__main__.py   # entrypoint
```

Key layout, fixed now because the EKS version inherits it verbatim:

```
jobs/{job_id}/input.json    {code, language, submitted_at, user_sub}
jobs/{job_id}/result.json   {stdout, stderr, exit_code, duration_ms, status, truncated}
```

Flow, per the architecture doc:

```
POST /runs         → job_id = uuid4()
                   → S3 PUT input.json
                   → SQS SEND {job_id}          ← in this order, always
                   → 202 {job_id}

worker             → SQS RECEIVE (long poll)
                   → S3 GET input.json
                   → runner.run(...)
                   → S3 PUT result.json
                   → SQS DELETE

GET /runs/{job_id} → S3 GET result.json → 200
                   → 404 on S3 → 202 {"status":"pending"}
```

Ordering is load-bearing: S3 write **before** SQS send. The reverse loses the
race — the worker can receive a job whose input does not exist yet.

Worker rules:

- Wrap the whole per-message body in `try/except`. On any unexpected failure,
  **write a `result.json` with `status:"error"` before deleting the message.**
  Without this the frontend polls forever on a crash. The DLQ then only
  catches failures so bad the worker died mid-handler.
- If `input.json` is missing (expired, or a poisoned message), write an error
  result and delete — do not retry into the DLQ.
- Handle `SIGTERM` by finishing the current job and then exiting. This is the
  same code path a Kubernetes pod eviction will take.
- Structured JSON logging with `job_id` on every line, never the user's code.

Config in `config.py`, all required, failing loudly at startup the way
`lib/env.ts` does: `AWS_REGION`, `JOBS_BUCKET`, `RUNS_QUEUE_URL`,
`RUNNER_BACKEND` (default `local_docker`), `MAX_EXECUTION_SECONDS`.

### 2c. Docker Compose

Two services from one image or two thin Dockerfiles:

- `api` — publishes `:8000`, mounts `~/.aws:/home/app/.aws:ro`, gets
  `AWS_PROFILE` and `AWS_REGION`. **No Docker socket.**
- `worker` — no published ports, mounts `~/.aws` read-only **and**
  `/var/run/docker.sock`.

The local-dev role requires MFA, so the profile in `~/.aws/config` should be a
`role_arn` + `mfa_serial` profile; run `aws sso login`/`aws sts` as usual on the
host and the containers inherit the cached session through the mounted
directory. Document this in `backend/README.md` — it is the step most likely to
waste an hour.

### Definition of done

- [ ] `terraform plan` in `infra/envs/dev` shows only additions
- [ ] Trivy config scan passes on the new module (fix findings; do not extend
      `.trivyignore` without a written justification in the file)
- [ ] `POST /runs` returns 202 and a job ID in well under a second
- [ ] `GET /runs/{id}` returns 202 then 200 with the same output stage 1 gave
- [ ] Killing the worker mid-job leaves the message on the queue; restarting it
      completes the job
- [ ] A deliberately poisoned message lands in the DLQ after 2 receives
- [ ] A job whose handler raises still produces a `status:"error"` result

Commit: `feat(backend): move execution behind sqs and s3 with a standalone worker`

---

## 3. Stage 3 — Cognito JWT at the API

**Verify the access token, not the ID token.** The ID token is about who the
user is, for the UI; the access token is the API credential and carries
`client_id` and `scope`. Send `Authorization: Bearer <accessToken>`.

`api/auth.py`:

- `PyJWT[crypto]` with `PyJWKClient` against
  `https://cognito-idp.{region}.amazonaws.com/{pool_id}/.well-known/jwks.json`,
  with the JWKS cached in-process. Do not fetch it per request.
- Assert all of: RS256 signature, `iss` matches the pool, `token_use ==
  "access"`, `client_id` matches the app client, `exp`/`nbf` valid.
  Missing any one of these is the classic Cognito verification bug.
- FastAPI dependency returning `sub`; 401 on any failure, with no detail about
  *which* check failed.

**Ownership, not just authentication.** `user_sub` goes into `input.json` and
is copied into `result.json`. `GET /runs/{job_id}` compares it against the
caller and returns **404** (not 403) on mismatch — job IDs are UUIDs, but
leaking existence is free information.

**CORS:** explicit origin allowlist (`http://localhost:3000` plus the real
domain), methods `GET, POST, OPTIONS`, `allow_credentials=False`. The bearer
token is a header, not a cookie; enabling credentials would be a needless
CSRF surface.

**Rate limiting:** a simple in-process token bucket keyed on `sub`
(e.g. 10 runs/minute) with a `RateLimiter` interface. Shared-state limiting
lands with EKS; the interface is what matters now.

### Definition of done

- [ ] No token → 401; expired token → 401; ID token in place of access token → 401
- [ ] Token from a different user pool → 401
- [ ] User A cannot read user B's job (404)
- [ ] `user_sub` present in both `input.json` and `result.json`
- [ ] Unit tests use locally-signed JWTs against a fake JWKS — no network in CI

Commit: `feat(backend): verify cognito access tokens and scope runs to their owner`

---

## 4. Stage 4 — frontend env plumbing

Do this as its own step, before touching UI. It is small and it is where the
build breaks.

`lib/env.ts` currently throws on any missing variable. Adding a **required**
`NEXT_PUBLIC_API_BASE_URL` would break `ci.yml`'s build step and `deploy.yml`
immediately, and there is no hosted API to point the deployed site at yet.

**Recommended:** add an `optional()` helper alongside `required()`, returning
`string | null`, and expose `env.apiBaseUrl: string | null`. The playground
route renders an honest "not available in this environment" panel when it is
null. This keeps the "fail the build rather than ship `undefined`" contract for
everything that is genuinely required, while letting the deployed site build
without inventing a URL for an API that does not exist.

Also update, in the same commit so they cannot drift:

- `frontend/.env.example` — with a comment saying it points at the local API
- `.github/workflows/ci.yml` — the build step's `env:` block
- `.github/workflows/deploy.yml` — same
- `frontend/lib/env.test.ts` — new, covering required vs optional

Commit: `feat(frontend): add optional api base url to the env contract`

---

## 5. Stage 5 — the playground UI

### Routing

Create the route group the current `app/page.tsx` comment already anticipates:

```
app/(app)/layout.tsx          # <AuthGate> wraps the segment
app/(app)/playground/page.tsx
```

Leave `app/page.tsx` as the landing route. Note that `AuthGate` currently sits
inside `page.tsx`; moving it into a group layout means the provider mounts once
across the segment rather than per page.

### Components

```
components/playground/PlaygroundShell.tsx   # layout, "use client"
components/playground/EditorPane.tsx        # next/dynamic, ssr:false
components/playground/LanguageSelect.tsx
components/playground/RunButton.tsx
components/playground/OutputPane.tsx
components/playground/StatusBadge.tsx
lib/runs/client.ts                          # typed fetch wrapper
lib/runs/useRun.ts                          # submit + poll hook
types/runs.ts                               # RunStatus, RunResult — shared types
```

`types/runs.ts` mirrors the Pydantic models exactly. Keep them in the same PR
so the drift is visible in one diff. If they later diverge, generate the TS
types from the OpenAPI schema FastAPI already produces.

### Editor

`@uiw/react-codemirror` + the language packs, loaded through
`next/dynamic(..., { ssr: false })`. The build is a static export — a
CodeMirror import at module scope will break it. Pin the exact version and
check the transitive tree (see the CSP note in §0).

### Polling

In `useRun.ts`, not in a component:

- 500 ms interval, per the architecture doc
- back off to 1500 ms after 10 s, give up at 60 s with a "still running"
  message rather than an infinite spinner
- `AbortController`, cancelled on unmount and on a new run
- fresh token per request via `fetchAuthSession()` — never cache a token in
  component state
- 401 → prompt re-authentication rather than retrying

### Output

Render the four statuses distinctly and honestly: **finished** (exit code
shown), **timed out**, **out of memory**, **crashed**. Show `duration_ms`.
Show a truncation notice when the result says so. Render stdout/stderr as
text in a `<pre>` — never `dangerouslySetInnerHTML`; program output is
untrusted input.

Build on `components/ui/` primitives, `cn()` for conditional classes, and
`--nord-*` tokens for colour, per `CLAUDE.md` §5.

### Definition of done

- [ ] Signed-in user edits Python, clicks Run, sees output
- [ ] Each of the four statuses renders distinctly and is reachable in manual test
- [ ] `npm run build`, `lint`, `typecheck`, `test`, `format:check` all clean
- [ ] Vitest covers `useRun` polling: success, timeout-of-polling, abort, 401
- [ ] No token in `localStorage`/`sessionStorage`; auth UI still defers past hydration

Commits: `feat(frontend): add playground route behind the auth gate` and
`feat(frontend): add run submission and polling client`

---

## 6. Stage 6 — more languages

`domain/languages.py` is already a registry; adding Node and Go is one entry
each:

```python
LANGUAGES = {
    "python": Language(image="python:3.12-alpine", cmd=["python", "/sandbox/main.py"], ext="py"),
    "node":   Language(image="node:22-alpine",     cmd=["node",   "/sandbox/main.js"], ext="js"),
    ...
}
```

Pin images by digest, not tag — a moving `:alpine` tag changes the sandbox
underneath you. Pre-pull in `docker-compose` or a `make` target so the first
run of a language is not a 30-second image download charged to the user's
timeout. Add a parametrised `@pytest.mark.docker` test asserting hello-world
per language. Compiled languages (Go, Rust) need a compile step inside the
timeout — treat that as its own decision, not a registry entry.

Later this dict becomes a ConfigMap; that is the Argo CD demo.

Commit: `feat(backend): add node and go to the language registry`

---

## 7. Cross-cutting: CI, tooling, hygiene

Do this incrementally alongside the stages, not as a big-bang at the end.

**`.github/workflows/ci.yml`** — new `backend` job mirroring the frontend one:
`ruff format --check`, `ruff check`, `mypy --strict`, `pytest -m "not docker"`.
Docker-dependent tests are marked and skipped unless the runner has a daemon;
the runner is self-hosted, so enable them there if it does.

**`scripts/pre-commit-check.sh`** — mirror those steps. The file says it
mirrors CI; keep that true.

**`.github/dependabot.yml`** — add the `pip` (or `uv`) ecosystem for
`backend/`, and `docker` for the new Dockerfiles.

**`.github/workflows/codeql.yml`** — currently a single
`languages: javascript-typescript` value. Convert it to a matrix over
`[javascript-typescript, python]` (the `category` string has to follow).

**`CODEOWNERS`** — the `*` catch-all already covers `backend/`. Add an explicit
entry only if ownership is ever split.

**`CLAUDE.md`** — once stage 2 lands the architecture diagram in §1 is wrong
(it says "no backend API, no compute layer — by design"). Update it in the same
PR that makes it false, along with the repository structure tree and a §
covering Python standards. An architectural memory file that lies is worse
than none.

**`.gitignore`** — `__pycache__/`, `.venv/`, `.pytest_cache/`, `.mypy_cache/`,
`.ruff_cache/`. (`.env` is already ignored at every level, so `backend/.env` is
covered.)

---

## 8. Deliberately not doing yet

Each of these is a real temptation with a real reason to wait:

- **A database.** S3 is the result store until there is a query that S3 cannot
  answer. "List my past runs" is that query — it arrives with history, not now.
- **WebSockets.** Polling at 500 ms is fine for a handful of users and needs no
  connection-state layer. Revisit when the API is hosted and connection count
  is a cost.
- **LocalStack.** Explicitly rejected in the architecture doc, and the reason
  holds: it adds an "is it failing because of LocalStack?" question to every
  debugging session.
- **Lambda for the runner.** No nested containers, and the sandbox flags do not
  map onto it. The whole migration story depends on those flags surviving.
- **A hosted API.** The API needs a home (ECS/App Runner + a CloudFront `/api`
  behaviour, or ALB) before staging and prod get the module. That is a genuine
  design decision and it belongs after stage 5, when there is something worth
  hosting.
- **Deep hardening** — seccomp profiles, gVisor/Kata, per-user egress policy.
  The current flags are the floor, not the ceiling; harden when the thing is
  reachable from the internet, and treat that as a blocking task before it is.

---

## 9. Suggested PR sequence

| # | Branch | Contents | Gate |
| --- | --- | --- | --- |
| 1 | `feat/backend-scaffold` | `backend/` tooling, config, CI job, ignores | CI green |
| 2 | `feat/local-docker-runner` | Runner interface + `LocalDockerRunner` + sync `POST /runs` | stage 1 checklist |
| 3 | `feat/run-pipeline-infra` | `infra/modules/run-pipeline` + dev wiring | `plan` shows only adds; Trivy clean |
| 4 | `feat/async-runs` | storage layer, worker, compose, async API | stage 2 checklist |
| 5 | `feat/api-cognito-auth` | JWT verification, ownership, CORS, rate limit | stage 3 checklist |
| 6 | `feat/frontend-env-api-url` | `lib/env.ts` + workflows + `.env.example` | CI green |
| 7 | `feat/playground-ui` | route group, editor, polling hook, output pane | stage 5 checklist |
| 8 | `feat/more-languages` | registry entries + per-language tests | stage 6 checklist |
| 9 | `docs/update-architecture` | `CLAUDE.md`, `README.md`, `backend/README.md` | review |

PRs 1–2 are the half-day the architecture doc describes. Everything after is
the machinery that makes the EKS swap mechanical.

---

## Next action

PR 1: scaffold `backend/` with `pyproject.toml`, `config.py`, `runner/base.py`
(the Protocol only, no implementation), and the CI job. Small, boring, and it
means PR 2 is nothing but the sandbox.
