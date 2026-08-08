"""The execution interface — the one thing this project has to get right.

From `code-playground-plan.md`:

    Put execution behind a single interface. Nothing else in the system
    knows what sits underneath it.
    ...
    Today: LocalDockerRunner. Later: KubernetesJobRunner. The worker loop,
    the API, the frontend, SQS and S3 do not change. That single swap is the
    entire EKS migration.

Nothing outside the composition root (`config.py`, and later `api/app.py` /
`worker/loop.py`) should import a concrete `Runner` implementation directly.
Every other module — API routes, the worker loop, tests — depends on this
Protocol, so `LocalDockerRunner` can be replaced with a `KubernetesJobRunner`
without touching any of them.
"""

from dataclasses import dataclass
from typing import Literal, Protocol, runtime_checkable

RunStatus = Literal["ok", "timeout", "oom", "error"]


@dataclass(frozen=True, slots=True)
class RunResult:
    stdout: str
    stderr: str
    exit_code: int
    duration_ms: int
    status: RunStatus
    # True when stdout/stderr were cut off at the runner's output cap rather
    # than ending naturally. Surfaced to the frontend so a truncated result
    # doesn't read as a smaller, complete one.
    truncated: bool = False


@runtime_checkable
class Runner(Protocol):
    """Executes untrusted code and returns a shaped result.

    Implementations must never raise for a failure that originates in the
    *executed* code (bad syntax, a crash, a timeout, an OOM kill) — those are
    `RunResult(status=...)` values, not exceptions. An exception from `run`
    means the runner itself is broken.
    """

    def run(self, code: str, language: str, timeout: int) -> RunResult: ...
