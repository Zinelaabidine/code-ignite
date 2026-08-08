# Backend

The code playground's API and worker. Sandboxed code execution behind SQS and
S3 — see `docs/code-playground-plan.md` for the architecture and
`docs/code-playground-implementation-plan.md` for the build order this folder
follows stage by stage.

This is stage 1: a synchronous API that runs code inside a locked-down Docker
container and returns the result in the same request. No queue, no S3, no
auth yet — those arrive in stages 2 and 3. Requires Docker to actually execute
code; the API itself runs fine without it (submitting a run will fail).

## Boundaries

- **Application logic** lives here (not in Terraform `user_data`, inline
  Lambda strings, or `local-exec` provisioners).
- **AWS resources** for this code are defined in `infra/`, one `.tf` file per
  service (`infra/modules/run-pipeline`, from stage 2 onward).
- **Browser UI** stays in `frontend/`.

See `.cursor/rules/backend.mdc` for AI coding conventions in this folder.

## Setup

```bash
cd backend
python3.12 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
cp .env.example .env        # optional at this stage — every value has a default
```

## Commands

```bash
ruff format --check .   # ruff format . to fix
ruff check .
mypy --strict src
pytest -m "not docker"  # full suite (needs a Docker daemon): pytest -m docker
```

These four are exactly what `.github/workflows/ci.yml`'s `backend` job and
`scripts/pre-commit-check.sh` run — if they're green locally, CI will be too.

## Run it

```bash
uvicorn codeignite.api.app:app --reload --port 8000
```

```bash
curl -X POST localhost:8000/runs \
  -H 'content-type: application/json' \
  -d '{"language": "python", "code": "print(\"hi\")"}'
# {"stdout":"hi\n","stderr":"","exit_code":0,"duration_ms":...,"status":"ok","truncated":false}
```

Requires a running Docker daemon — `LocalDockerRunner` shells out to `docker
run` for every request. `GET /healthz` works without one.

## Layout

| Path | Purpose |
| --- | --- |
| `pyproject.toml` | Dependencies, ruff, mypy, pytest config |
| `src/codeignite/config.py` | Environment contract (`pydantic-settings`), mirrors `frontend/lib/env.ts` |
| `src/codeignite/domain/languages.py` | `LANGUAGES` registry — one entry per supported language |
| `src/codeignite/runner/base.py` | The `Runner` Protocol and `RunResult` — the interface everything else is built against |
| `src/codeignite/runner/local_docker.py` | `LocalDockerRunner` — executes code in an ephemeral, locked-down container |
| `src/codeignite/api/app.py` | FastAPI app factory (`create_app()`) |
| `src/codeignite/api/routes_runs.py` | `POST /runs` — request/response models, the runner composition root |
| `tests/` | Unit tests; Docker-dependent tests are marked `@pytest.mark.docker` |

## Why the `Runner` Protocol comes before any implementation

From the architecture doc: "Put execution behind a single interface. Nothing
else in the system knows what sits underneath it... today `LocalDockerRunner`,
later `KubernetesJobRunner`... That single swap is the entire EKS migration."
The interface shipped ahead of `LocalDockerRunner` in the previous PR, so this
one's diff is nothing but the sandbox itself — no scaffolding noise mixed into
the part that actually needs careful review.

## Sandbox flags

Every flag `LocalDockerRunner` passes to `docker run` is explained — and
mapped onto its future Kubernetes equivalent — in
`docs/code-playground-plan.md` ("The local runner"). Don't add or remove one
without updating that table; the whole point of matching it exactly is that
the EKS migration becomes a mechanical swap rather than a redesign.

## Running the Docker-backed tests

```bash
pytest -m docker tests/test_local_docker.py
```

These launch real containers and take a few seconds each (one runs an actual
timeout, another an actual OOM kill). They're excluded from the default
`pytest` run and from CI unless the runner has Docker available — see
`tests/test_local_docker.py`'s module docstring.
