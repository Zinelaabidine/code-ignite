"""The worker loop:

    SQS RECEIVE (long poll)  → S3 GET input.json
                             → runner.run(...)
                             → S3 PUT result.json
                             → SQS DELETE

per docs/code-playground-plan.md. `get_runner()` here is this process's
composition root for `Runner` — the API no longer imports `LocalDockerRunner`
at all now that submission is async; only the worker executes code.

Two failure modes get careful handling, both from the architecture doc:

- A message whose body doesn't parse into a job ID (`ReceivedMessage.job_id
  is None`) is left alone rather than deleted, so SQS's own
  redelivery/max-receive-count/DLQ handling takes over — the worker has no
  job ID to write an error result against, so silently discarding it would
  just make the failure invisible.
- Any other unexpected failure while handling a *known* job ID gets a
  `status: "error"` result written before the message is deleted. Without
  this, a bug in the worker leaves the caller polling `GET /runs/{job_id}`
  forever instead of ever seeing an answer.
"""

import logging
import signal
from pathlib import Path
from types import FrameType

from codeignite.config import settings
from codeignite.runner.base import Runner, RunResult
from codeignite.runner.local_docker import LocalDockerRunner
from codeignite.storage import objects, queue
from codeignite.storage.queue import ReceivedMessage

logger = logging.getLogger(__name__)


def get_runner() -> Runner:
    """Composition root for the worker process. Stage 2's only
    implementation; the EKS migration swaps this for a `KubernetesJobRunner`
    without touching anything below it in this file.

    Passes through `settings.job_workspace_dir` /
    `settings.host_job_workspace_dir` — see `config.py` and
    `runner/local_docker.py` for why `LocalDockerRunner` needs both when it
    is talking to the host's Docker daemon "outside of Docker" through the
    socket `docker-compose.yml` mounts into this container. Both are `None`
    (the default) when running the worker directly on a dev machine, which
    leaves `LocalDockerRunner`'s old, untranslated behaviour unchanged.
    """
    return LocalDockerRunner(
        job_workspace_dir=Path(settings.job_workspace_dir) if settings.job_workspace_dir else None,
        host_job_workspace_dir=(
            Path(settings.host_job_workspace_dir) if settings.host_job_workspace_dir else None
        ),
    )


class GracefulShutdown:
    """Tracks a SIGTERM/SIGINT request without acting on it immediately.

    The run loop checks `.requested` between jobs, never mid-job — "finish
    the current job, then exit" per the architecture doc, not "abandon it."
    A pod eviction in the eventual Kubernetes version sends the same signal,
    so this is the code path that migration exercises too.
    """

    def __init__(self) -> None:
        self.requested = False

    def install(self) -> None:
        signal.signal(signal.SIGTERM, self._handle)
        signal.signal(signal.SIGINT, self._handle)

    def _handle(self, signum: int, frame: FrameType | None) -> None:
        logger.info("shutdown_requested", extra={"signal": signum})
        self.requested = True


def run_forever(runner: Runner | None = None, shutdown: GracefulShutdown | None = None) -> None:
    runner = runner if runner is not None else get_runner()
    shutdown = shutdown if shutdown is not None else GracefulShutdown()
    shutdown.install()

    # max_messages=1, so there is at most one job per iteration — the outer
    # condition alone gives "finish the current job, then exit": a signal
    # during handle_message() is picked up on the next check, before the
    # next receive.
    logger.info("worker_started")
    while not shutdown.requested:
        for message in queue.receive_jobs(max_messages=1, wait_time_seconds=20):
            handle_message(runner, message)
    logger.info("worker_stopped")


def handle_message(runner: Runner, message: ReceivedMessage) -> None:
    if message.job_id is None:
        logger.error("poisoned_message_left_for_redelivery")
        return

    job_id = message.job_id
    try:
        job_input = objects.get_input(job_id)
        if job_input is None:
            logger.error("job_input_missing", extra={"job_id": job_id})
            objects.put_result(job_id, _missing_input_result())
            queue.delete_job(message.receipt_handle)
            return

        result = runner.run(
            code=job_input.code,
            language=job_input.language,
            timeout=settings.max_execution_seconds,
        )
        objects.put_result(job_id, result)
        queue.delete_job(message.receipt_handle)
        logger.info("job_completed", extra={"job_id": job_id, "status": result.status})
    except Exception:
        logger.exception("job_handler_crashed", extra={"job_id": job_id})
        _fail_safely(job_id, message.receipt_handle)


def _fail_safely(job_id: str, receipt_handle: str) -> None:
    """Best-effort: write a crash result and delete the message. If even
    this fails, the message is left in place — SQS redelivers it up to
    max_receive_count, then the DLQ catches it. That's the one case the
    architecture doc's DLQ exists for: a job that crashes the worker badly
    enough that it can't clean up after itself.
    """
    try:
        objects.put_result(job_id, _crash_result())
        queue.delete_job(receipt_handle)
    except Exception:
        logger.exception("failed_to_record_crash_result", extra={"job_id": job_id})


def _missing_input_result() -> RunResult:
    return RunResult(
        stdout="",
        stderr="job input was not found — it may have expired",
        exit_code=-1,
        duration_ms=0,
        status="error",
    )


def _crash_result() -> RunResult:
    return RunResult(
        stdout="",
        stderr="the worker crashed while running this job",
        exit_code=-1,
        duration_ms=0,
        status="error",
    )
