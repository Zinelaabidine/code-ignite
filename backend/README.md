# Backend

The code playground's API and worker. Sandboxed code execution behind SQS and
S3 — see `docs/code-playground-plan.md` for the architecture and
`docs/code-playground-implementation-plan.md` for the build order this folder
follows stage by stage.

This is stage 3: asynchronous and authenticated. `POST /runs` verifies a
Cognito access token, rate-limits on its `sub`, writes the job to S3, sends
its ID to SQS, and returns `202 {job_id}` immediately — a separate worker
process pulls the job off the queue, runs it, and writes the result back to
S3. `GET /runs/{job_id}` verifies the token, checks the job belongs to the
caller (404 otherwise), and returns `202 {"status":"pending"}` until the
worker's finished, then `200` with the result.

## Boundaries

- **Application logic** lives here (not in Terraform `user_data`, inline
  Lambda strings, or `local-exec` provisioners).
- **AWS resources** for this code are defined in `infra/`, one `.tf` file per
  service — `infra/modules/run-pipeline` provisions the queue, DLQ, and jobs
  bucket this stage depends on.
- **Browser UI** stays in `frontend/`.

See `.cursor/rules/backend.mdc` for AI coding conventions in this folder.

## Setup

```bash
cd backend
python3.12 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev,server]"
cp .env.example .env
```

Fill in the five required values in `.env` from Terraform outputs (see the
comment in `.env.example`) — `codeignite.config.Settings` throws at startup
if any is missing. The two Cognito ones are the same pool and app client the
frontend already uses (`frontend/.env.example`).

Pre-pull the sandbox images so the first run of a language isn't a cold
image download charged against that job's own timeout:

```bash
scripts/pull-images.sh
```

Re-run it whenever `src/codeignite/domain/languages.py` gains a new entry or
re-pins an existing one.

## Commands

```bash
ruff format --check .   # ruff format . to fix
ruff check .
mypy --strict src
pytest -m "not docker"  # full suite (needs a Docker daemon): pytest -m docker
```

These four are exactly what `.github/workflows/ci.yml`'s `backend` job and
`scripts/pre-commit-check.sh` run — if they're green locally, CI will be too.
`pytest` needs no AWS credentials and no network: the S3/SQS-backed tests run
against [moto](https://github.com/getmoto/moto), the JWT tests
(`tests/test_auth.py`) sign their own tokens against a locally generated key
and monkeypatch the JWKS lookup, and the five required env vars get
placeholder values from `pytest-env` (`pyproject.toml`).

## Run it

### Docker Compose (matches how this actually runs)

```bash
docker compose up --build
```

Starts both the API (`:8000`) and the worker. Requires:

- An active session for an AWS profile the local-dev role trusts (`aws sso
  login`, or however you normally assume it) — the containers mount
  `~/.aws` read-only and read the cached session; they don't perform the MFA
  challenge themselves.
- `.env` filled in (see Setup above) — `docker-compose.yml` requires all
  five required `CODEIGNITE_*` values and `AWS_PROFILE` to be set, and fails
  fast with a clear message if any is missing rather than starting
  half-configured.

`docker compose up` from anywhere other than `backend/` will point the
worker's job-workspace bind mount (`.job-workspace/`, created automatically)
at the wrong host directory — see `docker-compose.yml`'s comments on
`CODEIGNITE_HOST_JOB_WORKSPACE_DIR` for why the worker needs it at all.

### Or run both processes directly

```bash
# terminal 1
uvicorn codeignite.api.app:app --reload --port 8000

# terminal 2 — requires a local Docker daemon; LocalDockerRunner shells out
# to `docker run` for every job
python -m codeignite.worker
```

### Running only the worker, against a hosted environment

Once `infra/modules/run-api` is deployed (`docs/code-playground-hosted-api-plan.md`),
the API runs on Lambda — you never run it locally against that environment.
The worker still does, and always will: it's the one piece deliberately kept
out of AWS entirely (see the plan doc's §0). To pick up real jobs submitted
through the hosted playground:

```bash
aws sso login   # or however you assume the local-dev role — needs
                # attach_runtime_policies_to_local_dev_role = true for the
                # target environment (already the default for dev)

cd backend
cp .env.example .env
# fill CODEIGNITE_JOBS_BUCKET / CODEIGNITE_RUNS_QUEUE_URL from
# `terraform output jobs_bucket_name` / `terraform output runs_queue_url`
# in infra/envs/dev — not a scratch local setup, the real dev queue and
# bucket

docker compose up worker   # or: python -m codeignite.worker
```

The playground only *finishes* jobs while this is running. A job submitted
through the hosted UI while it's stopped sits on the queue — the frontend's
poll loop gives up after 60s with "still running," and the job is picked up
whenever this next starts, within SQS's 4-hour message retention. That's the
deliberate shape of this architecture, not a bug.

### Try it

```bash
job_id=$(curl -sX POST localhost:8000/runs \
  -H 'content-type: application/json' \
  -d '{"language": "python", "code": "print(\"hi\")"}' | jq -r .job_id)

curl -s "localhost:8000/runs/$job_id"
# {"status":"pending"} while the worker is still working on it, then:
# {"stdout":"hi\n","stderr":"","exit_code":0,"duration_ms":...,"status":"ok","truncated":false}
```

`GET /healthz` works without any of the above — it doesn't touch S3, SQS, or
Docker.

## Layout

| Path | Purpose |
| --- | --- |
| `pyproject.toml` | Dependencies, ruff, mypy, pytest config |
| `docker-compose.yml`, `Dockerfile.api`, `Dockerfile.worker` | Local stage 2 topology — see the comments in each for the trust-boundary reasoning |
| `src/codeignite/api/lambda_handler.py` | The hosted API's entrypoint — `api/app.py` unmodified, wrapped by Mangum. Zip-packaged, not a container image; see `docs/code-playground-hosted-api-plan.md` §3 |
| `scripts/build-lambda-zip.sh` | Builds `dist/api.zip` for `infra/modules/run-api`'s Lambda function. Run before `terraform apply` whenever backend source or dependencies change; also run by `.github/workflows/deploy.yml` |
| `scripts/pull-images.sh` | Pre-pulls every image in `LANGUAGES` so a job's timeout never pays for a cold image pull |
| `src/codeignite/config.py` | Environment contract (`pydantic-settings`), mirrors `frontend/lib/env.ts` |
| `src/codeignite/domain/languages.py` | `LANGUAGES` registry — one entry per supported language |
| `src/codeignite/domain/models.py` | `JobInput` — the `input.json` shape |
| `src/codeignite/runner/base.py` | The `Runner` Protocol and `RunResult` — the interface everything else is built against |
| `src/codeignite/runner/local_docker.py` | `LocalDockerRunner` — executes code in an ephemeral, locked-down container |
| `src/codeignite/storage/objects.py` | S3 read/write for `jobs/{job_id}/input.json` and `.../result.json` |
| `src/codeignite/storage/queue.py` | SQS send/receive/delete/extend-visibility for the runs queue |
| `src/codeignite/worker/loop.py` | The poll loop: receive → get input → run → put result → delete |
| `src/codeignite/worker/__main__.py` | `python -m codeignite.worker` entrypoint |
| `src/codeignite/api/app.py` | FastAPI app factory (`create_app()`) |
| `src/codeignite/api/routes_runs.py` | `POST`/`GET /runs` — request/response models, the `RunsGateway` composition root |
| `tests/` | Unit tests; Docker-dependent tests are marked `@pytest.mark.docker`, S3/SQS-dependent ones run against moto |

## Why the `Runner` Protocol comes before any implementation

From the architecture doc: "Put execution behind a single interface. Nothing
else in the system knows what sits underneath it... today `LocalDockerRunner`,
later `KubernetesJobRunner`... That single swap is the entire EKS migration."
The interface shipped ahead of `LocalDockerRunner`, so the runner's own PR was
nothing but the sandbox — no scaffolding noise mixed into the part that
actually needs careful review. The API no longer imports `Runner` or
`LocalDockerRunner` at all now that submission is async — only the worker's
composition root (`worker/loop.py`'s `get_runner()`) does.

## Sandbox flags

Every flag `LocalDockerRunner` passes to `docker run` is explained — and
mapped onto its future Kubernetes equivalent — in
`docs/code-playground-plan.md` ("The local runner"). Don't add or remove one
without updating that table; the whole point of matching it exactly is that
the EKS migration becomes a mechanical swap rather than a redesign.

## The Docker socket is the trust boundary

The worker container is the only one that mounts `/var/run/docker.sock` (see
`docker-compose.yml` and `Dockerfile.worker`) — a process that can reach that
socket is effectively root on the host. That's why the worker never listens
on a port and the API never touches the socket: keeping the socket-holding
process off the request path is what makes "runs untrusted code" a contained
property of one process instead of the whole system.

## Running the Docker-backed tests

```bash
pytest -m docker tests/test_local_docker.py
```

These launch real containers and take a few seconds each (one runs an actual
timeout, another an actual OOM kill). They're excluded from the default
`pytest` run and from CI unless the runner has Docker available — see
`tests/test_local_docker.py`'s module docstring.
