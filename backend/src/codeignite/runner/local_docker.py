"""The first `Runner` implementation — executes code in an ephemeral,
locked-down Docker container on the local machine.

Every flag below is explained, flag by flag, in
docs/code-playground-plan.md ("The local runner") along with the table
mapping each one onto its Kubernetes Job equivalent. That mapping is the
point: these are not incidental hardening choices, they are the shape
`KubernetesJobRunner` has to reproduce at the EKS migration. Do not add or
remove a flag here without updating that table.

This module is imported from exactly one place in the API
(`api/routes_runs.py`'s composition root) and from the worker's composition
root once the worker exists (stage 2). Nothing else should import it — every
other caller depends on `codeignite.runner.base.Runner`.
"""

import logging
import os
import stat
import subprocess
import tempfile
import time
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

from codeignite.domain.languages import LANGUAGES, Language
from codeignite.runner.base import RunResult, RunStatus

logger = logging.getLogger(__name__)

# A print loop inside the sandbox streams output through a pipe into *this*
# process. The container's own memory limit (256m) does not bound that pipe,
# so cap what we read here rather than trusting the child to behave.
MAX_OUTPUT_BYTES = 64 * 1024

# The outer subprocess timeout is longer than the inner `timeout N` baked
# into the container command. The inner limit stops a runaway *program*; this
# one exists only to stop a *wedged Docker daemon* from hanging the request
# forever, so it needs headroom above the inner limit, not to duplicate it.
OUTER_TIMEOUT_SLACK_SECONDS = 5

# How long we're willing to wait for `docker kill` after the outer timeout
# fires. Best-effort: if the daemon is wedged enough that `docker run` hung,
# `docker kill` may hang too, and there is nothing further to fall back to
# from application code.
KILL_TIMEOUT_SECONDS = 5


class UnknownLanguageError(ValueError):
    """`language` is not a key in `LANGUAGES`.

    The API validates this before it ever reaches the runner (see
    `api/routes_runs.py`'s `RunRequest` validator) — this exists so a
    misuse from any other caller (tests, the future worker) fails loudly
    instead of quietly reaching `docker run` with a garbage image name.
    """


class LocalDockerRunner:
    """`Runner` implementation backed by the `docker` CLI.

    Shells out to `docker run` rather than using the Docker SDK: the
    architecture doc's flag table is written against the CLI invocation, and
    the CLI is one less dependency to pin and audit for a sandbox-adjacent
    process. `KubernetesJobRunner` will shell out to nothing — it talks to
    the Kubernetes API — so this dependency does not carry forward.
    """

    def __init__(
        self,
        job_workspace_dir: Path | None = None,
        host_job_workspace_dir: Path | None = None,
    ) -> None:
        """`job_workspace_dir` / `host_job_workspace_dir` mirror the
        `config.py` settings of the same name — see that module's docstring
        for why both exist. Plumbed through the constructor rather than read
        from `codeignite.config.settings` directly here, so this module
        stays usable by anything that isn't the worker's composition root
        (`worker/loop.py`'s `get_runner()`, the only place that should pass
        them) — stage 1's `pytest -m docker` tests construct
        `LocalDockerRunner()` with neither set and get the old
        direct-daemon behaviour, unchanged.

        Both `None` means "this process's filesystem and the Docker
        daemon's are the same thing" — the temp dir goes wherever
        `tempfile` puts it by default, and the mount source handed to
        `docker run` is that same path, unmodified.
        """
        self._job_workspace_dir = job_workspace_dir
        self._host_job_workspace_dir = host_job_workspace_dir

    def run(self, code: str, language: str, timeout: int) -> RunResult:
        if language not in LANGUAGES:
            raise UnknownLanguageError(language)
        spec = LANGUAGES[language]

        job_id = uuid.uuid4().hex
        container_name = f"job-{job_id}"

        with _job_workspace(code, spec.extension, self._job_workspace_dir) as workspace:
            mount_source = _host_mount_source(
                workspace, self._job_workspace_dir, self._host_job_workspace_dir
            )
            argv = _build_argv(mount_source, spec, container_name, timeout)
            start = time.monotonic()

            try:
                # argv is a fixed list built by _build_argv — never a shell
                # string, never user input placed directly on a command line.
                completed = subprocess.run(
                    argv,
                    capture_output=True,
                    timeout=timeout + OUTER_TIMEOUT_SLACK_SECONDS,
                )
            except subprocess.TimeoutExpired:
                _force_kill(container_name)
                return RunResult(
                    stdout="",
                    stderr="",
                    exit_code=-1,
                    duration_ms=_elapsed_ms(start),
                    status="timeout",
                )
            except OSError:
                logger.exception("docker invocation failed for job %s", job_id)
                return RunResult(
                    stdout="",
                    stderr="the sandbox failed to start",
                    exit_code=-1,
                    duration_ms=_elapsed_ms(start),
                    status="error",
                )

            return _to_run_result(completed, _elapsed_ms(start))


def _elapsed_ms(start: float) -> int:
    return int((time.monotonic() - start) * 1000)


def _build_argv(workspace: Path, spec: Language, container_name: str, timeout: int) -> list[str]:
    """Build the full `docker run` argv as a list.

    Never string-interpolated, never passed through a shell — `code` reaches
    this function only as a file already written to `workspace` by
    `_job_workspace`, so there is no path by which user input becomes part
    of a command line.
    """
    return [
        "docker",
        "run",
        "--rm",
        "--name",
        container_name,
        "--network",
        "none",
        # 512m, not 256m: a cold `go run` compiles stdlib inside the same
        # cgroup; 256m OOM-kills the compiler on arm64. Interpreted langs
        # barely touch their limit, so this only really matters for go.
        "--memory",
        "512m",
        "--memory-swap",
        "512m",
        "--cpus",
        "0.5",
        "--pids-limit",
        "64",
        "--read-only",
        "--tmpfs",
        # 64m, not 16m: go/rust (domain/languages.py) compile into this
        # directory before running, and a cold, uncached `go build` of even
        # a handful of stdlib packages wants a few tens of MB of build
        # cache. python/node barely touch /tmp at all, so this only ever
        # costs anything on the languages that need it.
        # `exec` is required: go/rust write compiled binaries to /tmp and
        # run them as uid 65534; Docker's default tmpfs mount is noexec.
        "/tmp:size=64m,exec",
        "--user",
        "65534",
        "--cap-drop",
        "ALL",
        "--security-opt",
        "no-new-privileges",
        "-v",
        f"{workspace}:/sandbox:ro",
        spec.image,
        "timeout",
        str(timeout),
        *spec.command,
    ]


@contextmanager
def _job_workspace(code: str, extension: str, base_dir: Path | None = None) -> Iterator[Path]:
    """Write `code` to a fresh temp dir as the only file the container sees.

    `base_dir`, when set, is the directory the temp dir is created *inside*
    rather than the OS default — the worker's bind-mounted, host-shared
    workspace directory (see `LocalDockerRunner.__init__` and
    `_host_mount_source`) rather than `/tmp`, so the resulting path is
    guaranteed to sit under a directory the host can also resolve.

    World-readable permissions are set deliberately: the container runs as
    uid 65534 (nobody), a different uid than the one that created the file,
    so the bind mount only works if the file is readable by "other". The
    directory and file are deleted in `finally` regardless of how the
    container run went.
    """
    with tempfile.TemporaryDirectory(prefix="codeignite-job-", dir=base_dir) as tmp:
        workspace = Path(tmp)
        os.chmod(
            workspace, stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP | stat.S_IROTH | stat.S_IXOTH
        )

        source = workspace / f"main.{extension}"
        source.write_text(code)
        os.chmod(source, stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)

        yield workspace


def _host_mount_source(
    workspace: Path, job_workspace_dir: Path | None, host_job_workspace_dir: Path | None
) -> Path:
    """Translate this process's own view of `workspace` into the path the
    Docker daemon that actually receives the `docker run` call will
    resolve — see the module docstring's "docker outside of docker" note.

    Identity when `host_job_workspace_dir` is unset: the direct-daemon case,
    where this process's filesystem and the daemon's are the same thing.
    Otherwise `workspace` is guaranteed to sit under `job_workspace_dir`
    (`_job_workspace` was given it as `base_dir`), so the daemon-visible
    equivalent is `host_job_workspace_dir` plus whatever `workspace` added
    on top of `job_workspace_dir`.
    """
    if host_job_workspace_dir is None:
        return workspace
    if job_workspace_dir is None:
        raise ValueError(
            "host_job_workspace_dir is set but job_workspace_dir is not — "
            "the two must be configured together (see config.py)"
        )
    return host_job_workspace_dir / workspace.relative_to(job_workspace_dir)


def _force_kill(container_name: str) -> None:
    try:
        subprocess.run(
            ["docker", "kill", container_name],
            capture_output=True,
            timeout=KILL_TIMEOUT_SECONDS,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        logger.warning("failed to force-kill %s after outer timeout", container_name)


def _to_run_result(completed: subprocess.CompletedProcess[bytes], duration_ms: int) -> RunResult:
    stdout, stdout_truncated = _decode_capped(completed.stdout)
    stderr, stderr_truncated = _decode_capped(completed.stderr)
    status, exit_code = _classify(completed.returncode)

    return RunResult(
        stdout=stdout,
        stderr=stderr,
        exit_code=exit_code,
        duration_ms=duration_ms,
        status=status,
        truncated=stdout_truncated or stderr_truncated,
    )


def _decode_capped(raw: bytes) -> tuple[str, bool]:
    truncated = len(raw) > MAX_OUTPUT_BYTES
    capped = raw[:MAX_OUTPUT_BYTES]
    # `errors="replace"` rather than raising: truncating at a byte boundary
    # can land inside a multi-byte UTF-8 sequence, and a program's own
    # output may not be valid UTF-8 to begin with — either way this is
    # untrusted input and must not be able to crash the runner.
    return capped.decode("utf-8", errors="replace"), truncated


def _classify(returncode: int) -> tuple[RunStatus, int]:
    """Map the container's exit code onto a `RunStatus`.

    124 is `timeout`'s own reserved exit code for "the command timed out" —
    guaranteed by GNU coreutils regardless of which signal the child actually
    received.

    137 (128 + SIGKILL) is what Docker's cgroup OOM killer produces. It is
    not exclusively an OOM signature — anything else that sent the container
    SIGKILL would look identical, and by the time `docker run --rm` returns,
    the container may already be removed, so `docker inspect
    .State.OOMKilled` is a race rather than a reliable check (see the
    architecture doc's own hedge on this point). Treating 137 as "oom" is the
    pragmatic call for a local dev tool; noted here so a future contributor
    doesn't "fix" it by trusting a post-removal inspect call.
    """
    if returncode == 124:
        return "timeout", returncode
    if returncode == 137:
        return "oom", returncode
    if returncode == 0:
        return "ok", returncode
    return "error", returncode
