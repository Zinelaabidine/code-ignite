# PR 1 — Backend scaffold

**Branch:** `feat/backend-scaffold`
**Commit:** `feat(backend): scaffold python tooling, env contract, language registry and runner interface`
**Stage:** 1 (sandbox skeleton), part 1 of 2 — see
`docs/code-playground-implementation-plan.md`.
**Status:** done, CI-green (verified locally with the exact commands the CI
job runs — see "Verification" below).

## What this is

Pure scaffolding for the code playground backend. No code executes anything
yet — there is no Docker call, no API endpoint, no worker. What lands here is
the tooling and the two interfaces every later stage builds against:

- Python project tooling (`pyproject.toml`): dependency management, `ruff`
  for lint + format, `mypy --strict` for types, `pytest` for tests. Deliberately
  mirrors the rigor of the frontend's `strict: true` / `eslint` / `prettier`
  contract, so the two halves of the repo feel like one codebase.
- `codeignite.config.Settings` — the backend's environment contract, in the
  same spirit as `frontend/lib/env.ts`: one typed place that declares every
  configuration value, so a missing or malformed one fails at process
  startup instead of surfacing three calls deep as `None` or a KeyError.
- `codeignite.domain.languages.LANGUAGES` — the registry the architecture doc
  calls out explicitly: "Keep a dict mapping language → `{image, command,
  extension}`. Adding Node or Go becomes one entry." Seeded with a single
  `python` entry.
- `codeignite.runner.base.Runner` — the Protocol from the architecture doc,
  verbatim: "Put execution behind a single interface. Nothing else in the
  system knows what sits underneath it... Today: `LocalDockerRunner`. Later:
  `KubernetesJobRunner`... That single swap is the entire EKS migration."
  This PR ships only the interface, not an implementation — the file tree the
  implementation plan lays out for stage 1 explicitly puts "the `Runner`
  Protocol + `RunResult`" ahead of `LocalDockerRunner`, so the next PR's diff
  is nothing but the sandbox, reviewable on its own.

## Why this is its own PR

Two independent reasons, both from the implementation plan:

1. **Review isolation.** The sandbox runner (next PR) is the highest-risk
   piece of this whole project — it runs untrusted code. Mixing it into a PR
   that also introduces `pyproject.toml`, CI wiring, and `.gitignore` entries
   would bury the part that needs the most scrutiny under routine scaffolding.
2. **CI has to exist before it can gate anything.** The `backend` CI job and
   the `pre-commit-check.sh` mirror need something to check. Standing them up
   against a trivial, already-correct scaffold proves the pipeline itself
   works before anything risky runs through it.

## Files

### Added

| Path | Purpose |
| --- | --- |
| `backend/pyproject.toml` | Project metadata, dependencies (`pydantic`, `pydantic-settings` only — `fastapi`/`uvicorn`/`boto3` arrive when something in the codebase actually imports them), `ruff`/`mypy`/`pytest` config |
| `backend/.python-version` | Pins `3.12`, matching `requires-python` and `mypy`'s `python_version` |
| `backend/.env.example` | Documents the (currently all-optional) config surface; the pattern `frontend/.env.example` already uses |
| `backend/src/codeignite/__init__.py` | Package marker + `__version__` |
| `backend/src/codeignite/config.py` | `Settings` — the environment contract |
| `backend/src/codeignite/domain/languages.py` | `LANGUAGES` registry, one `python` entry |
| `backend/src/codeignite/runner/base.py` | `Runner` Protocol, `RunResult` dataclass, `RunStatus` literal |
| `backend/tests/test_config.py` | Defaults and env-var override behaviour |
| `backend/tests/test_languages.py` | Registry shape: non-empty fields, `command` is a list of strings (never a shell string), immutability |
| `backend/tests/test_runner_base.py` | A fake conforming `Runner` satisfies the Protocol at `isinstance` time; `RunResult` defaults and immutability |
| `docs/prs/01-backend-scaffold.md` | This file |

### Modified

| Path | Change |
| --- | --- |
| `backend/README.md` | Rewritten from "reserved for later" to describe the actual layout, setup, and commands |
| `.github/workflows/ci.yml` | New `backend` job: checkout → `actions/setup-python` → `pip install -e ".[dev]"` → `ruff format --check` → `ruff check` → `mypy --strict src` → `pytest -m "not docker"`. Added `PYTHON_VERSION: "3.12"` to the workflow-level `env:` block, alongside the existing `NODE_VERSION` |
| `scripts/pre-commit-check.sh` | Mirrors the same four checks locally, guarded so it skips cleanly (with a warning, not a failure) until `backend/src/codeignite` exists — which, as of this PR, it does |
| `.github/dependabot.yml` | New `pip` ecosystem entry for `/backend`, grouped `minor-and-patch` like the existing `npm` entry; updated the file's header comment to mention it |
| `.gitignore` | New "Backend (Python)" section: `backend/.venv/`, `__pycache__/`, `*.pyc`, `.pytest_cache/`, `.mypy_cache/`, `.ruff_cache/`, `.coverage`, `htmlcov/` (`.env` itself was already covered by the existing top-level rule) |

## Design notes worth flagging on review

- **`Settings` has no required fields yet, on purpose.** Every value in
  `config.py` has a default because nothing in this PR reads them at a point
  where a wrong value would matter. `frontend/lib/env.ts`'s hard-required
  pattern is preserved for when it's actually earned: stage 2 (async runs)
  adds `aws_region`, `jobs_bucket`, `runs_queue_url` with no defaults, once
  there's a real queue and bucket that a missing value would silently fail
  against.
- **`fastapi`, `uvicorn`, `boto3` are not dependencies yet.** They're added in
  the PR that first imports them. A scaffold that pre-declares dependencies
  for code that doesn't exist yet is a scaffold nobody can tell is honest.
- **`Runner` is `@runtime_checkable`.** This is what lets
  `test_runner_base.py` assert `isinstance(fake, Runner)` — a cheap, real
  check that a conforming implementation satisfies the contract, without
  needing an implementation to exist yet.
- **`RunResult` and `Language` are frozen dataclasses.** A `RunResult` is a
  value describing something that already happened; nothing should mutate it
  after the runner returns it. Tests assert the immutability directly rather
  than trusting the annotation.

## Verification

Run from `backend/`, exactly matching the new CI job and
`pre-commit-check.sh`:

```bash
ruff format --check .   # 11 files already formatted
ruff check .            # All checks passed!
mypy --strict src       # Success: no issues found in 6 source files
pytest -m "not docker"  # 8 passed
```

All four confirmed locally against Python 3.12.13 before this commit. Test
coverage on the new `src/codeignite` package is 100% (8 tests, 29 statements,
0 missed) — expected at this size, and not a target to chase once the runner
and API introduce real branching logic.

## What's deliberately not here

- No FastAPI app, no `/runs` endpoint — that's the next PR
  (`feat/local-docker-runner`).
- No Docker interaction — `LocalDockerRunner` doesn't exist yet.
- No Terraform — the run pipeline module (`infra/modules/run-pipeline`)
  arrives at stage 2, once there's a worker that needs a queue.
- No `docker-compose.yml` / `Dockerfile.*` — nothing to containerize yet.

## Next

PR 2 (`feat/local-docker-runner`): implement `LocalDockerRunner` against the
`Runner` Protocol shipped here, plus a synchronous `POST /runs` FastAPI
endpoint. Definition of done is the stage 1 checklist in
`docs/code-playground-implementation-plan.md` — `curl` → `print("hi")` →
`"hi"`, plus verified network isolation, read-only root filesystem, timeout,
and OOM handling.
