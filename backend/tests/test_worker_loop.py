"""Worker loop tests, backed by moto for S3+SQS and a `FakeRunner` for
execution. This file is about the loop's own failure handling — missing
input, a crashing runner, a poisoned message — not the sandbox itself (see
test_local_docker.py) and not storage/queue in isolation (see
test_storage_objects.py / test_storage_queue.py)."""

from collections.abc import Iterator
from pathlib import Path

import boto3
import pytest
from moto import mock_aws

from codeignite.config import settings
from codeignite.domain.models import JobInput
from codeignite.runner.base import RunResult
from codeignite.runner.local_docker import LocalDockerRunner
from codeignite.storage import objects, queue
from codeignite.worker.loop import GracefulShutdown, get_runner, handle_message, run_forever


class FakeRunner:
    def __init__(self, result: RunResult | None = None, raises: bool = False) -> None:
        self.result = result or RunResult(
            stdout="hi\n", stderr="", exit_code=0, duration_ms=1, status="ok"
        )
        self.raises = raises
        self.calls: list[dict[str, object]] = []

    def run(self, code: str, language: str, timeout: int) -> RunResult:
        self.calls.append({"code": code, "language": language, "timeout": timeout})
        if self.raises:
            raise RuntimeError("boom")
        return self.result


@pytest.fixture(autouse=True)
def _mocked_aws(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    with mock_aws():
        boto3.client("s3", region_name=settings.aws_region).create_bucket(
            Bucket=settings.jobs_bucket
        )
        response = boto3.client("sqs", region_name=settings.aws_region).create_queue(
            QueueName="test-runs-queue"
        )
        monkeypatch.setattr(settings, "runs_queue_url", response["QueueUrl"])
        yield


def _seed_job(
    job_id: str, code: str = "print(1)", language: str = "python"
) -> queue.ReceivedMessage:
    job_input = JobInput(code=code, language=language, submitted_at="2026-01-01T00:00:00+00:00")
    objects.put_input(job_id, job_input)
    queue.send_job(job_id)
    [message] = queue.receive_jobs(max_messages=1, wait_time_seconds=0)
    return message


def test_happy_path_writes_the_result_and_deletes_the_message() -> None:
    message = _seed_job("job-1")
    runner = FakeRunner(
        result=RunResult(stdout="ok\n", stderr="", exit_code=0, duration_ms=3, status="ok")
    )

    handle_message(runner, message)

    result = objects.get_result("job-1")
    assert result is not None
    assert result.stdout == "ok\n"
    assert queue.receive_jobs(max_messages=1, wait_time_seconds=0) == []


def test_happy_path_calls_the_runner_with_the_stored_code_and_language() -> None:
    message = _seed_job("job-args", code="print('x')", language="python")
    runner = FakeRunner()

    handle_message(runner, message)

    assert runner.calls == [
        {"code": "print('x')", "language": "python", "timeout": settings.max_execution_seconds}
    ]


def test_missing_input_writes_an_error_result_and_deletes_the_message() -> None:
    # A message on the queue with no matching input.json — e.g. it expired
    # before the worker got to it.
    queue.send_job("job-ghost")
    [message] = queue.receive_jobs(max_messages=1, wait_time_seconds=0)
    runner = FakeRunner()

    handle_message(runner, message)

    result = objects.get_result("job-ghost")
    assert result is not None
    assert result.status == "error"
    assert queue.receive_jobs(max_messages=1, wait_time_seconds=0) == []
    assert runner.calls == []


def test_a_crashing_runner_still_writes_an_error_result_and_deletes_the_message() -> None:
    message = _seed_job("job-crash")
    runner = FakeRunner(raises=True)

    handle_message(runner, message)

    result = objects.get_result("job-crash")
    assert result is not None
    assert result.status == "error"
    assert queue.receive_jobs(max_messages=1, wait_time_seconds=0) == []


def test_a_poisoned_message_is_left_on_the_queue_for_redelivery() -> None:
    boto3.client("sqs", region_name=settings.aws_region).send_message(
        QueueUrl=settings.runs_queue_url, MessageBody="not json"
    )
    [message] = queue.receive_jobs(max_messages=1, wait_time_seconds=0)
    assert message.job_id is None
    runner = FakeRunner()

    handle_message(runner, message)

    assert runner.calls == []
    # Never deleted — still on the queue. A receive puts the message in-flight
    # (visibility timeout); expire that window so we can observe it again.
    # Older moto returned in-flight messages immediately; current moto does not.
    queue.extend_visibility(message.receipt_handle, visibility_timeout=0)
    remaining = queue.receive_jobs(max_messages=1, wait_time_seconds=0)
    assert len(remaining) == 1


def test_get_runner_passes_through_the_workspace_dir_settings(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Regression test for the "docker outside of docker" bug: a worker
    # running under docker-compose.yml talks to the host's Docker daemon
    # through a mounted socket, so LocalDockerRunner needs the host-side
    # path translation settings — see config.py and runner/local_docker.py.
    # Without get_runner() passing these through, every job fails with
    # "can't open file '/sandbox/main.py'" because the bind mount names a
    # path that only exists inside the worker container, not on the host
    # the daemon actually resolves it against.
    monkeypatch.setattr(settings, "job_workspace_dir", "/job-workspace")
    monkeypatch.setattr(settings, "host_job_workspace_dir", "/host/path/.job-workspace")

    runner = get_runner()

    assert isinstance(runner, LocalDockerRunner)
    assert runner._job_workspace_dir == Path("/job-workspace")
    assert runner._host_job_workspace_dir == Path("/host/path/.job-workspace")


def test_get_runner_leaves_workspace_dirs_unset_by_default() -> None:
    # settings.job_workspace_dir / host_job_workspace_dir default to None —
    # the direct-daemon case (worker run outside a container).
    runner = get_runner()

    assert isinstance(runner, LocalDockerRunner)
    assert runner._job_workspace_dir is None
    assert runner._host_job_workspace_dir is None


def test_graceful_shutdown_sets_requested_on_signal() -> None:
    shutdown = GracefulShutdown()
    assert shutdown.requested is False

    shutdown._handle(15, None)  # SIGTERM's numeric value; avoids importing signal just for this

    assert shutdown.requested is True


def test_run_forever_returns_once_shutdown_is_already_requested() -> None:
    # Setting requested before the first iteration means the loop body never
    # runs, so this returns immediately instead of blocking on a real
    # receive — proves run_forever checks the flag before every poll, not
    # only between messages.
    shutdown = GracefulShutdown()
    shutdown.requested = True
    runner = FakeRunner()

    run_forever(runner=runner, shutdown=shutdown)

    assert runner.calls == []
