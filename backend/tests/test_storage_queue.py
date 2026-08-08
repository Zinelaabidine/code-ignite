"""SQS send/receive/delete, backed by moto. `settings.runs_queue_url` is a
placeholder from pytest-env — this fixture points it at whatever URL moto
actually assigns the mocked queue, for the duration of each test."""

from collections.abc import Iterator

import boto3
import pytest
from moto import mock_aws

from codeignite.config import settings
from codeignite.storage import queue


@pytest.fixture(autouse=True)
def _mocked_queue(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    with mock_aws():
        response = boto3.client("sqs", region_name=settings.aws_region).create_queue(
            QueueName="test-runs-queue"
        )
        monkeypatch.setattr(settings, "runs_queue_url", response["QueueUrl"])
        yield


class TestSendAndReceive:
    def test_round_trips_a_job_id(self) -> None:
        queue.send_job("job-abc")

        messages = queue.receive_jobs(max_messages=1, wait_time_seconds=0)

        assert len(messages) == 1
        assert messages[0].job_id == "job-abc"
        assert messages[0].receipt_handle

    def test_receive_with_no_messages_returns_an_empty_list(self) -> None:
        assert queue.receive_jobs(max_messages=1, wait_time_seconds=0) == []

    def test_delete_removes_the_message(self) -> None:
        queue.send_job("job-xyz")
        [message] = queue.receive_jobs(max_messages=1, wait_time_seconds=0)

        queue.delete_job(message.receipt_handle)

        assert queue.receive_jobs(max_messages=1, wait_time_seconds=0) == []

    def test_extend_visibility_does_not_raise(self) -> None:
        queue.send_job("job-visibility")
        [message] = queue.receive_jobs(max_messages=1, wait_time_seconds=0)

        queue.extend_visibility(message.receipt_handle, visibility_timeout=30)


def test_a_message_with_an_unparseable_body_yields_a_none_job_id() -> None:
    # Simulates a poisoned message: valid SQS content, but not JSON with a
    # job_id — exactly what queue.py's own poisoned-message handling exists
    # for, exercised end to end in tests/test_worker_loop.py.
    boto3.client("sqs", region_name=settings.aws_region).send_message(
        QueueUrl=settings.runs_queue_url, MessageBody="not json"
    )

    [message] = queue.receive_jobs(max_messages=1, wait_time_seconds=0)

    assert message.job_id is None
    assert message.receipt_handle


def test_a_message_body_that_is_json_but_missing_job_id_yields_none() -> None:
    boto3.client("sqs", region_name=settings.aws_region).send_message(
        QueueUrl=settings.runs_queue_url, MessageBody='{"not_a_job_id": "x"}'
    )

    [message] = queue.receive_jobs(max_messages=1, wait_time_seconds=0)

    assert message.job_id is None
