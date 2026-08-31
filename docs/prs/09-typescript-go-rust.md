# PR 9 — TypeScript, Go, and Rust in the language registry (+ frontend wiring)

**Branch:** `feat/typescript-go-rust`
**Commit:** `feat(backend): add typescript, go, and rust to the language registry`,
`feat(frontend): wire typescript/node/go/rust into the playground UI`
**Stage:** a second pass at stage 6 of `docs/code-playground-implementation-plan.md`,
picking up where PR 8 (`node`) and its own "Next" section left off — this
time closing the frontend gap PR 8 deliberately left open, for four
languages at once.
**Status:** done locally; **not verified against a real Docker daemon or a
real `npm install`** — see "Verification" below. Not committed or pushed.

## What this is

Three registry entries plus the frontend wiring PR 8 explicitly scoped out
("wiring a new language into the dropdown is frontend work... out of scope
here"). This PR does both ends for all three new languages, plus `node`,
which had been sitting in the backend registry unreachable from the UI since
PR 8.

- **`typescript`** reuses the exact same pinned `node:22-alpine` image and
  adds `--experimental-strip-types`. Node 22.6+ can run a `.ts` file
  directly by stripping type annotations at parse time — no separate
  compiler, no build artifact, no new image. This is the one addition that
  is genuinely "just a registry entry," same as `node` was in PR 8.
- **`go`** and **`rust`** are the harder case PR 8 deferred outright: "Go
  (and compiled languages generally) is not in the registry... there's
  nowhere for a compiler to put its output without either a writable mount
  ... or a compile-then-run wrapper that changes the container invocation
  shape for every language." That framing missed that `command` was
  already a free-form argv, not a fixed binary name, and every sandbox
  container already has one writable location: `--tmpfs /tmp` (`--read-only`
  covers everything else). So both compile from the read-only `/sandbox`
  mount into `/tmp` and run the result from there, via a `["sh", "-c",
  ...]` command — no change to `LocalDockerRunner`, `_build_argv`, or the
  `Runner` interface. The registry stayed data, not a factory, for the
  second time running.

## Why these three, in this shape

- **TypeScript**: `node`'s type-stripping mode needed nothing beyond a flag
  change. Skipping it because it "looks like a compile step" would have been
  wrong — it isn't one.
- **Rust pinned to `rust:1.98`, not `rust:1.98-alpine`**: the official Alpine
  variant ships without `musl-dev`/`gcc`, which `rustc` needs on the host to
  link even a statically-linked musl binary, and the sandbox has
  `--network none` — there's no way to `apk add` it at run time. The full
  Debian-based image carries a linker already. `rustc` itself (not `cargo`)
  needs no `$HOME` — it reads `/sandbox/main.rs` and writes straight to
  `/tmp` via the OS default temp dir.
- **Go pinned to `golang:1.27-alpine`**: no cgo, no need for a C toolchain,
  so Alpine's smaller image is fine. It does need `HOME=/tmp` set explicitly
  in its command — the image sets no `HOME` for the arbitrary non-root UID
  we run every sandbox container as (`--user 65534`), and `go run` refuses
  to guess a `GOCACHE` location without one.
- **Digests** resolved live from Docker Hub's registry API (manifest-list
  digest, not a single-arch digest — same method PR 8 used for `python` and
  `node`), so both new images are pinned the same way as the rest of the
  registry from the moment they land, not pinned later as a follow-up.

## What this deliberately does not fix

- **No shared build cache across jobs.** Every job is a brand-new `--rm`
  container, so Go's cold `GOCACHE` (routed to `/tmp`) recompiles a chunk of
  the standard library on *every* run of a `go` job, not just the first —
  there is no warm-cache case. A host-mounted, shared `GOCACHE` (parallel to
  the existing job-workspace hostPath) would fix this, but it means
  untrusted job containers writing into a cache later trusted by other
  users' containers — a cache-poisoning surface not worth taking on to save
  a couple of seconds per Go job. Left as a deliberate non-goal; see the
  docstring in `domain/languages.py`.
- **No per-language timeout.** `max_execution_seconds` (`config.py`) is one
  global value for every job, and it wraps compile time *and* run time for
  `go`/`rust` exactly the way it always has for `python`/`node`. A cold Go
  compile is the one case where that budget is genuinely tighter than for
  an interpreted language. Not addressed here — worth watching once this is
  live; if it turns out to matter, that's a `Language`-level timeout floor,
  not a global bump.
- **No `GET /languages` endpoint.** `frontend/types/runs.ts`'s
  `SUPPORTED_LANGUAGES` is still maintained by hand against the backend
  registry, same as PR 8 left it. Still no query S3 can't answer that would
  justify one.

## Files

### Modified — backend

| Path | Change |
| --- | --- |
| `backend/src/codeignite/domain/languages.py` | Adds `typescript`, `go`, `rust`; docstring rewritten to explain the type-stripping approach and the compile-then-run wrapper, plus the two deliberately-unsolved caveats above |
| `backend/src/codeignite/runner/local_docker.py` | `--tmpfs /tmp:size=16m` → `size=64m`, so `go`'s cold stdlib build cache has room; `python`/`node`/`typescript` barely touch `/tmp` so this costs them nothing |
| `backend/tests/test_local_docker.py` | `test_root_filesystem_is_read_only` updated for the new tmpfs size; `HELLO_WORLD_BY_LANGUAGE` gets entries for all three new languages (test_languages.py's generic assertions already cover new entries with no changes needed) |

### Modified — frontend

| Path | Change |
| --- | --- |
| `frontend/package.json` | Adds `@codemirror/lang-go`, `@codemirror/lang-javascript`, `@codemirror/lang-rust`, and `@codemirror/state` (promoted from transitive to direct, since `EditorPane.tsx` now imports its `Extension` type directly) |
| `frontend/types/runs.ts` | `SUPPORTED_LANGUAGES` grows from one entry (`python`) to five: `python`, `node`, `typescript`, `go`, `rust` |
| `frontend/components/playground/EditorPane.tsx` | Per-language CodeMirror extension lookup (`LANGUAGE_EXTENSIONS`) replaces the `language === "python"` one-off; `typescript` reuses `@codemirror/lang-javascript`'s `{ typescript: true }` mode rather than a separate package, mirroring the backend's image reuse |
| `frontend/components/playground/LanguageSelect.tsx` | Docstring updated — it claimed `SUPPORTED_LANGUAGES` had "exactly one entry" and to "revisit if stage 6 makes a richer picker worth it"; both are now true and false respectively, so it's corrected rather than left stale |

## Verification

**Ran here:** `python3 -m ast` syntax checks on every edited Python file —
all clean. Manual re-derivation of `_build_argv`'s output for each new
entry against the existing flag table.

**Could not run in this environment** (no network egress from this shell,
matching PR 8's own Docker-daemon gap — a different resource, same shape of
problem):

```bash
# backend — needs a real Python 3.12 + deps, and Docker for the two new
# @pytest.mark.docker cases
cd backend
ruff format --check . && ruff check . && mypy --strict src
pytest -m "not docker"
scripts/pull-images.sh                       # now also pulls golang + rust
pytest -m docker tests/test_local_docker.py  # exercises go/rust hello-world for real

# frontend — needs npm install to actually resolve the three new
# @codemirror/lang-* packages and regenerate package-lock.json; nothing
# here has installed them yet
cd frontend
npm install
npm run build && npm run lint && npm run typecheck && npm run test && npm run format:check
```

Everything above is inference from reading the Go/Rust toolchain's own
documented behavior (`GOCACHE` resolution via `$HOME`, `rustc`'s lack of any
`$HOME` dependency, the Alpine Rust image's missing linker), not something
exercised end to end. Treat the `go`/`rust` hello-world pass as the one
thing this PR most needs before merging, the same way PR 8 flagged `node`'s.

## What's deliberately not here

- **No `GET /languages` endpoint**, per above.
- **No richer `LanguageSelect`.** Five entries is still comfortably a plain
  `<select>`'s territory.
- **No shared Go build cache, no per-language timeout override** — both
  flagged above as conscious non-goals, not oversights.
- **No starter examples per language** — `docs/code-playground-plan.md`'s
  "Features worth adding later" list, untouched by this PR.
