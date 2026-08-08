# PR 2 — Local Docker runner and synchronous `/runs` endpoint

**Branch:** `feat/local-docker-runner`
**Commit:** `feat(backend): implement local docker runner and synchronous runs endpoint`
**Stage:** 1 (sandbox skeleton), part 2 of 2 — see
`docs/code-playground-implementation-plan.md`.
**Status:** done. Ruff, mypy, and the non-Docker test suite verified locally;
the Docker-marked tests could not run in this environment (no Docker daemon
available) and need a run on a machine that has one before merge — see
"Verification" below.

## What this is

The sandbox itself: `LocalDockerRunner`, the first (and for now only)
implementation of the `Runner` Protocol shipped in PR 1, plus a synchronous
`POST /runs` FastAPI endpoint that puts it behind HTTP. This is the "half a
day, proves the Docker sandboxing works" milestone from
`docs/code-playground-plan.md`'s build order — `curl` → `print("hi")` →
`"hi"`, executed inside a container with no network, a read-only root
filesystem, and hard resource ceilings.

Nothing here is asynchronous yet. The API calls `runner.run()` inline and
returns the result in the same request/response cycle. SQS, S3, and the
worker process arrive in the next PR (`feat/run-pipeline-infra` /
`feat/async-runs`).

## Why this is its own PR

Called out explicitly when PR 1 was scoped: this is the highest-risk code in
the whole project — it runs arbitrary, untrusted code — and it deserves a
diff with nothing else competing for attention in review. PR 1 already
absorbed all the scaffolding (tooling, CI, the interface). This one is just
the sandbox and the thin HTTP layer in front of it.

## Files

### Added

| Path | Purpose |
| --- | --- |
| `backend/src/codeignite/runner/local_docker.py` | `LocalDockerRunner` — builds the `docker run` argv, executes it, maps the result to a `RunResult` |
| `backend/src/codeignite/api/app.py` | `create_app()` factory; `GET /healthz` |
| `backend/src/codeignite/api/routes_runs.py` | `POST /runs` — `RunRequest`/`RunResponse` models, language validation, the runner composition root (`get_runner`) |
| `backend/tests/conftest.py` | `FakeRunner` + `client`/`fake_runner` fixtures shared across route tests |
| `backend/tests/test_local_docker.py` | Argv-construction and exit-code-classification unit tests (no Docker needed) + `@pytest.mark.docker` integration tests (real containers) |
| `backend/tests/test_routes_runs.py` | Route-level tests against `FakeRunner` — validation, response shaping, status pass-through |
| `docs/prs/02-local-docker-runner.md` | This file |

### Modified

| Path | Change |
| --- | --- |
| `backend/pyproject.toml` | Added `fastapi`, `uvicorn[standard]` to dependencies; `httpx` to dev deps (FastAPI's `TestClient` is httpx-based); added `[tool.ruff.lint.flake8-bugbear] extend-immutable-calls` so `Depends(...)` in an argument default doesn't trip bugbear's B008 |
| `backend/README.md` | Added "Run it" (`uvicorn` + `curl`) and "Running the Docker-backed tests" sections; updated the stage description |

## Design notes worth flagging on review

- **CLI, not the Docker SDK.** `LocalDockerRunner` shells out to `docker run`
  rather than using `docker-py`. The architecture doc's flag table is written
  against the CLI invocation verbatim, and `argv` is built as a plain list —
  never a shell string, never string-interpolated — so there's no path from
  user code to a command injection.
- **Every flag from the architecture doc's table is present and has its own
  test** in `TestBuildArgv`: `--network none`, `--memory`/`--memory-swap`
  256m, `--cpus 0.5`, `--pids-limit 64`, `--read-only` + `--tmpfs`, `--user
  65534`, `--cap-drop ALL`, `--security-opt no-new-privileges`, the read-only
  workspace mount, and the named container (needed for force-kill). A flag
  silently dropped here is a sandbox with a hole in it — that's why each one
  gets its own assertion instead of one test checking the whole list.
- **Two timeout layers**, per the plan: the inner `timeout N` inside the
  container stops a runaway *program*; the outer `subprocess.run(...,
  timeout=timeout + 5)` stops a *wedged Docker daemon* from hanging the
  request forever. If the outer one fires, `_force_kill` sends `docker kill`
  to the named container, best-effort.
- **Output is capped at 64 KiB per stream, post-capture.** A print loop
  inside the sandbox streams through a pipe into the API process, and the
  container's own 256m limit doesn't bound that pipe. This PR truncates after
  `subprocess.run` returns rather than streaming with a live cap — simpler,
  and bounded in the worst case by the container's own `timeout` ceiling (10s
  default) times whatever throughput a pipe sustains in that window. Flagged
  as a known simplification, not a design I'd defend at higher scale.
- **Exit-code mapping has a documented ambiguity, not a silent one.** 124 →
  `timeout` is unambiguous (`timeout`'s own reserved code). 137 → `oom` is a
  pragmatic call: it's also plain SIGKILL from any other source, and
  `docker inspect .State.OOMKilled` races against `--rm` auto-removing the
  container. The architecture doc hedges on exactly this point; the
  `_classify` docstring says so explicitly rather than presenting the mapping
  as more certain than it is.
- **`get_runner()` is the composition root for this module** — the only
  place `LocalDockerRunner` is imported. Routes depend on `Runner` (the
  Protocol) via FastAPI's `Depends`, so `test_routes_runs.py` overrides
  `app.dependency_overrides[get_runner]` with `FakeRunner` and never touches
  Docker. `test_local_docker.py`'s non-`docker`-marked tests reach the real
  module to test `_build_argv`/`_classify`/`_decode_capped` directly, since
  those are pure functions worth testing on their own regardless of the
  Docker boundary.
- **Language validation happens in the pydantic model, before the runner is
  ever called.** `RunRequest.language_must_be_registered` rejects anything
  outside `LANGUAGES` — FastAPI turns that into a `422`, not a `400`;
  documented in the field validator's comment as the "never a value that
  reaches Docker" guarantee from the architecture doc, with the caveat that
  FastAPI's standard validation status is 422 rather than 400.
- **`code`'s length cap is approximate.** `Field(max_length=65536)` counts
  Unicode characters, not bytes, so multi-byte source could exceed 64 KiB of
  actual storage before hitting the cap. Noted as a known approximation
  rather than silently treating "characters" and "bytes" as interchangeable.

## Verification

Ran from `backend/` (Python 3.12.13, since no local `docker` daemon exists in
this environment):

```bash
ruff format --check .   # 18 files already formatted
ruff check .            # All checks passed!
mypy --strict src       # Success: no issues found in 10 source files
pytest -m "not docker"  # 33 passed, 5 deselected
```

Coverage on `local_docker.py` is 56% with only the non-Docker tests running —
expected, since the container-launching code paths (`run()`'s live subprocess
call, `_job_workspace`, `_force_kill`) are exercised exclusively by the
`@pytest.mark.docker` tests in `TestLocalDockerRunnerLive`, which need an
actual daemon.

**Not verified here, needs a machine with Docker before this merges:**

```bash
pytest -m docker tests/test_local_docker.py
```

This runs the stage 1 "Definition of done" checklist as tests rather than
manual steps: hello-world, an infinite loop actually timing out, a 512 MB
allocation actually getting OOM-killed, a live network connection actually
being refused, and a write to `/etc` actually being blocked by the read-only
root filesystem. Please run this — and the `curl` example in
`backend/README.md`'s "Run it" section — locally before merging; I could not
exercise the part of this PR that matters most in this sandbox.

## What's deliberately not here

- No SQS, no S3, no worker process — `POST /runs` is synchronous.
- No Cognito/auth — anyone who can reach the API can submit code. Fine for
  local-only stage 1; stage 3 closes this before anything is deployed.
- No `Dockerfile.api` / `docker-compose.yml` — nothing to containerize until
  the worker exists and compose needs to wire the two together (stage 2).
- No rate limiting — same reasoning as auth.

## Next

PR 3 (`feat/run-pipeline-infra`): the `infra/modules/run-pipeline` Terraform
module — SQS queue + DLQ, jobs S3 bucket, and the two IAM policies
(`run-api`, `run-worker`) described in stage 2 of
`docs/code-playground-implementation-plan.md`. No application code changes;
this is the infrastructure the async split needs before `feat/async-runs` can
build on it.
