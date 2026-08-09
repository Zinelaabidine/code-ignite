# PR 8 — More languages: Node in the registry, digest pinning, per-language tests

**Branch:** `feat/more-languages`
**Commit:** `feat(backend): add node to the language registry`
**Stage:** 6 of `docs/code-playground-implementation-plan.md`.
**Status:** done, verified locally — ruff, mypy, and the non-Docker test
suite pass. The new `@pytest.mark.docker` hello-world tests could not run
in this environment (no Docker daemon available) and need a run on a
machine that has one before merge — see "Verification" below. Not yet
committed or pushed.

## What this is

`domain/languages.py` was already shaped as a registry (one dict entry per
language) specifically so this PR would be mechanical. It adds `node`
alongside `python`, switches every entry from a bare tag to a
digest-pinned image (`tag@sha256:...`), and adds a parametrized
`@pytest.mark.docker` test that runs a real hello-world through every
registered language — so a future entry with no passing hello-world fails
loudly instead of being discovered the first time someone picks it in the
UI.

Go (and compiled languages generally) is **not** in the registry after this
PR. The implementation plan calls this out explicitly: a compiled language
needs a build step before the run step, and this registry's `command` is
exec'd directly against a workspace mounted `:ro` — there's nowhere for a
compiler to put its output without either a writable mount (which weakens
the read-only root every other entry relies on) or a compile-then-run
wrapper that changes the container invocation shape for every language, not
just the compiled ones. That's a real design decision with its own
trade-offs, not a registry entry, so it's deliberately out of scope here.

## Why digest pinning, not just a second tag

`python:3.12-alpine` and `node:22-alpine` are moving tags — Docker Hub
repoints them as patch releases ship. A runner tested against one image can
silently start running a different one the next time it pulls. Pinning by
digest (`tag@sha256:...`) makes the image immutable; the tag stays in the
string purely for a human reading the registry. Re-pinning is a deliberate
act (fetch the current digest, update the dict), not something that happens
by accident on a routine `docker pull`.

Digests were resolved from Docker Hub's public tag API
(`hub.docker.com/v2/repositories/library/{python,node}/tags/{tag}`), using
the manifest-list digest (the `image-index` value, not a single-arch
image digest) so the pin resolves correctly regardless of host
architecture.

## Files

### Added

| Path | Purpose |
| --- | --- |
| `backend/scripts/pull-images.sh` | Pre-pulls every image in `LANGUAGES` via the venv's Python (reads the registry directly rather than hardcoding a second copy of the image list) |
| `docs/prs/08-more-languages.md` | This file |

### Modified

| Path | Change |
| --- | --- |
| `backend/src/codeignite/domain/languages.py` | `python` re-pinned by digest; new `node` entry (`node:22-alpine@sha256:...`, `["node", "/sandbox/main.js"]`, extension `js`); docstring explains digest pinning and why compiled languages aren't here yet |
| `backend/tests/test_languages.py` | `test_node_is_registered`; `test_every_image_is_pinned_by_digest_not_a_moving_tag` (asserts `"@sha256:"` in every `image`) |
| `backend/tests/test_local_docker.py` | `HELLO_WORLD_BY_LANGUAGE` mapping + `TestHelloWorldPerLanguage`, parametrized over `sorted(LANGUAGES)` — a language with no snippet in the mapping fails at collection with a `KeyError`, not a silent skip |
| `backend/docker-compose.yml` | Header comment points at `scripts/pull-images.sh`, explaining why (first run of a language shouldn't pay for its own image pull inside the job's 8s timeout) |
| `backend/README.md` | New "pre-pull the sandbox images" step in Setup; `scripts/pull-images.sh` added to the Layout table |

## Design notes worth flagging on review

- **The registry stayed data, not a factory.** Adding `node` is a plain dict
  entry — no branching in `LocalDockerRunner` or `_build_argv` needed a
  change. That was the whole point of the registry shape from PR 1; this PR
  is the first real test of it.
- **`node`'s command mirrors `python`'s exactly**: `["node",
  "/sandbox/main.js"]` against a file written by `_job_workspace` as
  `main.{extension}`. No new sandbox behavior, no new flags — the same
  `docker run` argv construction handles both languages identically.
- **The digest-pinning test is a guardrail against regression, not just a
  one-time check.** `test_every_image_is_pinned_by_digest_not_a_moving_tag`
  iterates `LANGUAGES` rather than asserting on the two known entries by
  name, so a ninth language landing with a bare tag fails this test
  immediately instead of quietly reintroducing drift.
- **`HELLO_WORLD_BY_LANGUAGE` is a second source of truth, deliberately.**
  It has to be — `LANGUAGES` doesn't carry a "how do I print hello world in
  this language" fact, and shouldn't; that's test fixture data, not
  something the runner needs. Keying the parametrize off
  `sorted(LANGUAGES)` (rather than hardcoding `["python", "node"]`) is what
  makes a missing snippet a collection-time `KeyError` instead of a test
  that silently never runs for a new language.
- **`pull-images.sh` asks the registry directly** (`python -c "from
  codeignite.domain.languages import LANGUAGES; ..."`) instead of
  hardcoding a parallel list of images in bash. Two lists of the same
  images drifting apart is exactly the kind of bug this PR's own tests are
  designed to catch elsewhere — no reason to reintroduce it in a shell
  script.
- **Not wired into CI.** The new `TestHelloWorldPerLanguage` tests are
  `@pytest.mark.docker`, same as the existing `TestLocalDockerRunnerLive`
  class, and `ci.yml`'s backend job already runs `pytest -m "not docker"`
  (see PR 1). No CI change needed for this PR to be covered the same way
  stage 1's Docker tests already are.

## Verification

Ran from `backend/` (Python 3.12.13). Note: the checked-in `.venv` in this
environment had a stale interpreter path from an earlier session and
wouldn't run; verified against a fresh venv built with `uv` instead —
recreate `backend/.venv` locally before running these yourself
(`python3.12 -m venv .venv && source .venv/bin/activate && pip install -e
".[dev]"`).

```bash
ruff format --check .   # 31 files already formatted
ruff check .            # All checks passed!
mypy --strict src       # Success: no issues found in 19 source files
pytest -m "not docker"  # 74 passed, 7 deselected, 1 pre-existing failure
```

The one failure (`test_worker_loop.py::test_a_poisoned_message_is_left_on_the_queue_for_redelivery`)
predates this PR — moto's mocked SQS behaves inconsistently in this sandbox
(flagged previously as an environment issue, not a code defect) and is
unrelated to anything touched here; all `test_languages.py` and
`test_local_docker.py` tests (including the ones this PR adds) pass.

**Not verified here, needs a machine with Docker before this merges:**

```bash
scripts/pull-images.sh
pytest -m docker tests/test_local_docker.py
```

This is what actually proves `node:22-alpine@sha256:...` resolves, pulls,
and runs `console.log('hi')` to `"hi\n"` inside the same locked-down
container `python` already uses — the part of this PR that matters most,
and the one thing I could not exercise in this sandbox.

## What's deliberately not here

- **No Go, no compiled languages.** See "What this is" above — needs its
  own compile-step design, not a registry entry.
- **No frontend changes.** `LanguageSelect.tsx` (PR 7) isn't touched, so
  `node` isn't reachable from the UI yet. Stage 6 in the implementation
  plan scopes this PR to the backend registry and its tests only; wiring a
  new language into the dropdown is frontend work with no dependency on
  this PR landing first, but it's out of scope here to keep this diff to
  exactly what the stage 6 checklist describes.
- **No CI/Dependabot changes.** Nothing about adding a language changes
  what `ci.yml` or `dependabot.yml` need to do — both already cover
  `backend/` generically.

## Next

PR 9 (`docs/update-architecture`): fix `CLAUDE.md`'s "no backend API, no
compute layer" architecture claim (stale since PR 4), update the repository
structure tree, add the Python standards section, and refresh
`README.md`/`backend/README.md` — the docs cleanup the implementation plan
holds until the very end on purpose.
