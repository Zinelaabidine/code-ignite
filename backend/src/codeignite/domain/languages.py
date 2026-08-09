"""The language registry.

One dict entry per supported language, per `code-playground-plan.md` §"More
languages": "Keep a dict mapping language → {image, command, extension}.
Adding Node or Go becomes one entry." The registry shape is what makes these
additions mechanical instead of a redesign — stage 6
(`docs/code-playground-implementation-plan.md` §6) adds Node here.

`image` is pinned by digest, not tag: `python:3.12-alpine` and `node:22-alpine`
are moving tags that Docker Hub repoints as patch releases ship, which would
change the sandbox out from under a runner that was tested against a
different image. Every entry is `tag@sha256:...` instead — the tag stays for
a human reading the registry, the digest is what `docker run` actually
resolves. Re-pin deliberately (fetch the current digest, update the
dict) rather than letting it drift.

Compiled languages (Go, Rust, ...) are deliberately not here yet. This
registry's `command` is exec'd directly against the mounted `:ro` workspace —
there is nowhere to put a build artifact without either a writable mount
(defeats the read-only root) or a compile-then-run wrapper that changes the
container invocation shape for every other entry. That is its own design
decision, not a registry entry — see stage 6's note in the implementation
plan.
"""

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Language:
    """A single sandboxed execution target."""

    # Docker image the code runs inside, pinned as `tag@sha256:digest`.
    image: str
    # Full argv run inside the container, after the sandbox's own `timeout N`
    # prefix. Never built by string interpolation — see LocalDockerRunner.
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
}
