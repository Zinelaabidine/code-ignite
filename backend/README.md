# Backend

The code playground's API and worker. Sandboxed code execution behind SQS and
S3 — see `docs/code-playground-plan.md` for the architecture and
`docs/code-playground-implementation-plan.md` for the build order this folder
follows stage by stage.

This PR (stage 1, part 1) is scaffolding only: tooling, the environment
contract, the language registry, and the `Runner` interface everything else
gets built against. Nothing here executes code yet — `LocalDockerRunner` and
the API land in the next PR.

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
pytest                  # -m "not docker" once Docker-backed tests exist
```

These four are exactly what `.github/workflows/ci.yml`'s `backend` job and
`scripts/pre-commit-check.sh` run — if they're green locally, CI will be too.

## Layout

| Path | Purpose |
| --- | --- |
| `pyproject.toml` | Dependencies, ruff, mypy, pytest config |
| `src/codeignite/config.py` | Environment contract (`pydantic-settings`), mirrors `frontend/lib/env.ts` |
| `src/codeignite/domain/languages.py` | `LANGUAGES` registry — one entry per supported language |
| `src/codeignite/runner/base.py` | The `Runner` Protocol and `RunResult` — the interface everything else is built against |
| `tests/` | Unit tests; Docker-dependent tests are marked `@pytest.mark.docker` |

## Why the `Runner` Protocol comes before any implementation

From the architecture doc: "Put execution behind a single interface. Nothing
else in the system knows what sits underneath it... today `LocalDockerRunner`,
later `KubernetesJobRunner`... That single swap is the entire EKS migration."
Shipping the interface on its own, ahead of `LocalDockerRunner`, means the next
PR's diff is nothing but the sandbox — no scaffolding noise mixed into the
part that actually needs careful review.
