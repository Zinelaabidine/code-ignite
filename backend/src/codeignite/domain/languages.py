"""The language registry.

One dict entry per supported language, per `code-playground-plan.md` §"More
languages": "Keep a dict mapping language → {image, command, extension}.
Adding Node or Go becomes one entry." The registry shape is what makes these
additions mechanical instead of a redesign.

`image` is pinned by digest, not tag: a bare `python:3.12-alpine` or
`node:22-alpine` is a moving tag that Docker Hub repoints as patch releases
ship, which would change the sandbox out from under a runner that was tested
against a different image. Every entry is `tag@sha256:...` instead — the tag
stays for a human reading the registry, the digest is what `docker run`
actually resolves. Re-pin deliberately (fetch the current digest, update the
dict) rather than letting it drift.

## TypeScript: still a plain interpreted entry, not a compile step

`typescript` reuses the exact same pinned `node` image and just adds
`--experimental-strip-types` to the command. Node (22.6+) can run a `.ts`
file directly by stripping type annotations at parse time — no type
checking, no emitted JS, no build artifact anywhere. That means TypeScript
never needed a "compiled language" story at all: it's the same
read-only-mount, single-process, single-command shape as `python` and
`node`, just a different flag.

## Go and Rust: compile-then-run, without changing the invocation shape

The original version of this file argued compiled languages couldn't be
registry entries because `command` was exec'd directly against the
`:ro`-mounted workspace, and a compile step needs somewhere writable to put
its output. That argument missed that every sandbox container already has a
writable location: `--tmpfs /tmp:size=64m` (see `runner/local_docker.py`).
`command` was already a free-form argv, not a single binary name — nothing
stops an entry from being `["sh", "-c", "compile-then-run"]` instead of
`["python", "/sandbox/main.py"]`. So `go` and `rust` compile from the
read-only `/sandbox` mount into `/tmp`, then run the result from `/tmp` —
same container, same flags, same `LocalDockerRunner`/`_build_argv`, zero
changes needed there. This is why the registry stayed data instead of
becoming a factory (see `docs/prs/08-more-languages.md`'s framing) — this PR
is the second proof of that, for a harder case than Node was.

Two things this does NOT solve, deliberately:

- **No shared build cache across jobs.** Every job is a brand-new `--rm`
  container, so Go's `GOCACHE` (routed to `/tmp` via `HOME=/tmp` — the
  official image sets no `HOME` for an arbitrary non-root UID, and Go
  refuses to guess one) starts cold every single time: a `fmt`-importing
  hello world recompiles a chunk of the standard library from source on
  every run, not just the first. A host-mounted, shared `GOCACHE` directory
  (parallel to the existing job-workspace hostPath) would fix this, but it
  means untrusted job containers writing into a cache that other users'
  containers later trust — a cache-poisoning surface this sandbox doesn't
  need to take on for the sake of shaving a couple of seconds off Go
  compiles. Left as a deliberate non-goal; revisit only if cold-compile
  latency actually starts blowing `max_execution_seconds` in practice.
- **No per-language timeout.** `max_execution_seconds` (`config.py`) is one
  global value applied to every job regardless of language, and it wraps
  compile time *and* run time for `go`/`rust` the same way `timeout N`
  always has. A cold Go compile is the one case where that budget is
  genuinely tighter than it is for `python`/`node`/`typescript`. Not
  addressed here — worth watching once this is live, per the note above.

Rust needs no such `HOME` juggling: `rustc` (not `cargo`) has no
`~/.cargo`-shaped state to find a home for — it reads `/sandbox/main.rs` and
writes straight to `/tmp`, using the OS temp dir default. That's also why
`rust` is pinned to the full `rust:1.98` image rather than `rust:1.98-alpine`:
the official Alpine variant ships without `musl-dev`/`gcc`, which `rustc`
needs on-host to link even a static musl binary, and there is no network
inside the sandbox to `apk add` it at run time. The full Debian-based image
carries a linker out of the box. `golang:1.27-alpine` has no equivalent
problem — a pure, non-cgo `go run` never shells out to a C compiler, so
Alpine's smaller image is fine there.
"""

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Language:
    """A single sandboxed execution target."""

    # Docker image the code runs inside, pinned as `tag@sha256:digest`.
    image: str
    # Full argv run inside the container, after the sandbox's own `timeout N`
    # prefix. Never built by string interpolation — see LocalDockerRunner.
    # A `["sh", "-c", "..."]` shape (go, rust) is fine — the whole point is
    # that this stays whatever argv the language needs, single command or
    # not.
    command: list[str]
    # Extension used for the source file written into the job's temp dir
    # (e.g. "py" → main.py). Also namespaces per-language starter examples
    # later.
    extension: str


LANGUAGES: dict[str, Language] = {
    "python": Language(
        image="python:3.12-alpine@sha256:6d43704baacd1bfbe7c295d7f13079d5d8104ed33568873133f8fc69980419df",
        command=["python", "/sandbox/main.py"],
        extension="py",
    ),
    "node": Language(
        image="node:22-alpine@sha256:968df39aedcea65eeb078fb336ed7191baf48f972b4479711397108be0966920",
        command=["node", "/sandbox/main.js"],
        extension="js",
    ),
    "typescript": Language(
        # Same pinned image as `node` — see the module docstring. Node's
        # own type-stripping (22.6+) makes this a plain interpreted entry,
        # not a build step.
        image="node:22-alpine@sha256:968df39aedcea65eeb078fb336ed7191baf48f972b4479711397108be0966920",
        command=["node", "--experimental-strip-types", "/sandbox/main.ts"],
        extension="ts",
    ),
    "go": Language(
        image="golang:1.27-alpine@sha256:4c9fe60190a2a3350ddc51de80d0224b8a6698d12bdfc999fee45ea9d6c46dbc",
        # HOME=/tmp: the image sets no HOME for an arbitrary non-root UID
        # (we run as 65534 — see `_build_argv`), and `go run` refuses to
        # pick a GOCACHE location without one. Everything Go needs to write
        # — build cache, `go env` config — lands under /tmp this way, and
        # nowhere else, matching every other entry's single writable
        # location. See the module docstring for what this does and doesn't
        # solve.
        command=["sh", "-c", "HOME=/tmp go run /sandbox/main.go"],
        extension="go",
    ),
    "rust": Language(
        image="rust:1.98@sha256:271849e998ffce5776454bbf98c5dc21baafc854ff8e566197908d3aca9a81e8",
        # rustc, not cargo — no ~/.cargo, no HOME needed. Compiles straight
        # from the read-only /sandbox mount to /tmp, then runs the result.
        command=["sh", "-c", "rustc -O -o /tmp/main /sandbox/main.rs && /tmp/main"],
        extension="rs",
    ),
}
