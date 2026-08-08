# PR 4 — Async runs: storage layer, worker, and the SQS/S3 split

**Branch:** `feat/async-runs`
**Commit:** `feat(backend): move execution behind sqs and s3 with a standalone worker`
**Stage:** 2b/2c of `docs/code-playground-implementation-plan.md`.
**Status:** mostly verified — see "Verification" below for exactly what
passed and what I could not confirm from this environment. **Do not merge
without running the flagged tests locally first.**

## What this is

The split the whole architecture doc is organized around: `POST /runs` no
longer executes code inline. It writes the job to S3, sends the job ID to
SQS, and returns `202 {job_id}` immediately. A separate worker process pulls
the job off the queue, runs it through `LocalDockerRunner` (unchanged since
PR 2), and writes the result back to S3. `GET /runs/{job_id}` reads the
result — `200` if it's there, `202 {"status":"pending"}` if not yet.

This is also the point where `config.py`'s three required fields
(`aws_region`, `jobs_bucket`, `runs_queue_url`) go from promised to real —
PR 3's `infra/modules/run-pipeline` outputs are what they're pointed at.

## Files

### Added

| Path | Purpose |
| --- | --- |
| `backend/src/codeignite/domain/models.py` | `JobInput` — the `input.json` shape |
| `backend/src/codeignite/storage/objects.py` | S3 read/write for `jobs/{job_id}/input.json` and `.../result.json` |
| `backend/src/codeignite/storage/queue.py` | SQS `send_job`/`receive_jobs`/`delete_job`/`extend_visibility` |
| `backend/src/codeignite/worker/loop.py` | `run_forever`, `handle_message`, `GracefulShutdown` |
| `backend/src/codeignite/worker/__main__.py` | `python -m codeignite.worker` entrypoint |
| `backend/Dockerfile.api`, `Dockerfile.worker`, `docker-compose.yml` | Local stage 2 topology |
| `backend/tests/test_storage_objects.py` | S3 round-trip tests against moto |
| `backend/tests/test_storage_queue.py` | SQS round-trip tests against moto — **hangs in this environment, see below** |
| `backend/tests/test_worker_loop.py` | Worker failure-handling tests against moto — **hangs in this environment, see below** |
| `docs/prs/04-async-runs.md` | This file |

### Modified

| Path | Change |
| --- | --- |
| `backend/src/codeignite/config.py` | `aws_region`, `jobs_bucket`, `runs_queue_url` are now required (no default) — the fields PR 1's docstring promised would land here |
| `backend/src/codeignite/api/routes_runs.py` | Rewritten for async: `SubmitRunResponse`, `PendingResponse`, `RunsGateway` Protocol replacing `Runner`/`get_runner`; `job_id` path parameter constrained to `^[0-9a-f]{32}$` |
| `backend/pyproject.toml` | Added `boto3`; dev-only `boto3-stubs[s3,sqs]`, `moto[s3,sqs]`, `pytest-env`; new `[tool.mypy] plugins = ["pydantic.mypy"]`; `env = [...]` block under `[tool.pytest.ini_options]` |
| `backend/tests/conftest.py` | `FakeRunsGateway` replaces `FakeRunner`; new autouse fixture clearing both storage modules' cached boto3 clients between tests |
| `backend/tests/test_routes_runs.py` | Rewritten for the async endpoints and `FakeRunsGateway` |
| `backend/tests/test_config.py` | Updated for the three now-required fields, plus a new test asserting they still have no fallback |
| `backend/.env.example`, `backend/README.md` | Document the three required vars, Docker Compose usage, the async `curl` example |

## The API no longer imports `Runner`

`routes_runs.py` has no reference to `Runner` or `LocalDockerRunner` at all
now — that moved to `worker/loop.py`'s `get_runner()`, which is the
composition root the architecture doc's diagram always implied: only the
worker executes code. The API's only job from here on is enqueueing, via a
new `RunsGateway` Protocol (`put_input`, `send_job`, `get_result`) — the same
"depend on the Protocol, override with a fake in tests" pattern
`get_runner`/`Runner` established in PR 2, just covering three storage
operations instead of one execution call.

## Design notes worth flagging on review

- **Ordering is enforced, not just documented.** `submit_run` calls
  `gateway.put_input(...)` before `gateway.send_job(...)`, and
  `test_submit_run_writes_input_before_sending_to_the_queue` asserts that
  order via a call log on `FakeRunsGateway` — not just a comment someone
  could invalidate by reordering two lines later.
- **`job_id` is regex-constrained on the way in.** `Path(..., pattern=r"^[0-9a-f]{32}$")`
  on `GET /runs/{job_id}` rejects anything that isn't exactly what
  `uuid.uuid4().hex` produces, before it can become part of an S3 key. Without
  this, a crafted `job_id` is a path-traversal vector into the jobs bucket's
  key namespace.
- **A poisoned SQS message is never deleted by the worker.** If a message
  body doesn't parse into a job ID, `ReceivedMessage.job_id` is `None` and
  `handle_message` returns without touching the queue — SQS's own
  redelivery and `max_receive_count` → DLQ handling (PR 3) takes over,
  because the worker has no job ID to write an error result against.
- **Every other failure gets a written result.** Missing `input.json`
  (expired, or a job whose message outlived it) and an unhandled exception
  from the runner both produce a `status: "error"` `RunResult`, written
  before the message is deleted. Without this, a bug in the worker leaves a
  caller polling `GET /runs/{job_id}` forever.
- **`run_forever`'s shutdown handling got simpler than first written.** The
  first version had a per-message `if shutdown.requested: break` inside the
  per-batch loop — redundant, since `max_messages=1` means that loop body
  runs at most once anyway, and `mypy --strict` correctly flagged the
  `break` as unreachable. Removed rather than suppressed; the outer `while
  not shutdown.requested` already gives "finish the current job, then exit."
- **`Settings()` needed the pydantic mypy plugin, not a `type: ignore`.**
  Adding three required fields to `Settings` broke `mypy --strict` on
  `settings = Settings()` — mypy, without the plugin, has no way to know
  pydantic-settings resolves required fields from the environment at
  runtime rather than the constructor call. `plugins = ["pydantic.mypy"]`
  teaches it that `BaseSettings` subclasses are special-cased this way; a
  per-line ignore would have been the same bug repeated at every future
  required field.
- **`boto3-stubs[s3,sqs]`, not blanket `Any`.** boto3 ships no types of its
  own — importing it under `mypy --strict` with no stubs installed would
  either fail outright or force every client to `Any`. The stubs give
  `S3Client`/`SQSClient` as real, checked types.

## Verification

**Confirmed clean**, run from `backend/` against Python 3.12.13:

```bash
ruff format --check .   # clean
ruff check .            # All checks passed!
mypy --strict src       # Success: no issues found in 17 source files
```

**Confirmed passing** — 45 of the suite's tests, everything except the two
files noted below:

```bash
pytest -m "not docker" --ignore=tests/test_storage_queue.py --ignore=tests/test_worker_loop.py
# 45 passed, 5 deselected
```

That covers `test_config.py`, `test_languages.py`, `test_local_docker.py`
(non-Docker subset), `test_routes_runs.py`, `test_runner_base.py`, and —
importantly — `test_storage_objects.py`, which exercises moto's S3 mock
successfully (8 passing tests, real round-trips through `put_input`/
`get_input`/`put_result`/`get_result`).

**Not confirmed — flagging clearly, please verify before merging:**
`tests/test_storage_queue.py` and `tests/test_worker_loop.py` hang
indefinitely in this sandbox. I traced it to moto's mocked SQS client itself:
even a minimal reproduction outside pytest —

```python
import boto3
from moto import mock_aws
with mock_aws():
    c = boto3.client("sqs", region_name="us-east-1")
    c.create_queue(QueueName="q")  # never returns here
```

— hangs on `create_queue` specifically. `boto3.client()` construction and
entering `mock_aws()` both return immediately; moto's S3 mock (`create_bucket`
and everything downstream) works correctly in the same environment. This
looks like an SQS-specific interaction between moto and this sandbox
(possibly a network call moto's SQS backend attempts that S3's doesn't), not
a bug in `storage/queue.py` or `worker/loop.py` — but I could not get far
enough to confirm that with certainty, and I'm not willing to claim these
files are correct without having actually seen them pass.

Please run, on a normal machine:

```bash
pytest tests/test_storage_queue.py tests/test_worker_loop.py -v
```

If they hang for you too, that's a real moto/environment bug worth
reporting upstream rather than something in this PR's code — but that's a
call I can't make from here. If they pass, `codeignite.storage.queue` and
`codeignite.worker.loop` are exactly as untested-in-CI-so-far as everything
else was before this PR, and this note can come out in a follow-up.

**Not verified at all:** `docker compose up` against a real Docker daemon
and real AWS (no Docker, no AWS credentials in this sandbox) — please run
the `curl` sequence in `backend/README.md`'s "Try it" section locally too.

## What's deliberately not here

- No Cognito auth — `user_sub` is always `None` in `JobInput` until stage 3
  verifies a token. `GET /runs/{job_id}` has no ownership check yet; any
  caller who knows (or brute-forces, though the 128-bit ID space makes that
  impractical) a job ID can read its result. Closed in
  `feat/api-cognito-auth`, the next PR.
- No rate limiting — same reasoning, same PR.
- No frontend changes — the playground UI (stage 5) is still two PRs out.

## Next

PR 5 (`feat/api-cognito-auth`): verify the Cognito access token on both
routes, populate `user_sub` in `submit_run`, and add the ownership check
`GET /runs/{job_id}` is currently missing — 404, not 403, on a mismatch, per
`docs/code-playground-implementation-plan.md` stage 3.
