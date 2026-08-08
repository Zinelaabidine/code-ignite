"""The language registry.

One dict entry per supported language, per `code-playground-plan.md` §"More
languages": "Keep a dict mapping language → {image, command, extension}.
Adding Node or Go becomes one entry." Only Python exists today; the registry
shape is what makes the later additions mechanical instead of a redesign.

`image` is pinned by tag for now. Stage 6 (more languages) switches to digest
pinning — a moving `:alpine` tag changes the sandbox out from under a runner
that was tested against a different image, and that only starts to matter
once there is more than one entry to keep consistent.
"""

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Language:
    """A single sandboxed execution target."""

    # Docker image the code runs inside.
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
        image="python:3.12-alpine",
        command=["python", "/sandbox/main.py"],
        extension="py",
    ),
}
