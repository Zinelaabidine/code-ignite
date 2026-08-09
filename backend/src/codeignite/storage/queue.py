"""SQS send/receive/delete for the runs queue. Messages carry a job ID only
— never code, never results — per `docs/code-playground-plan.md`.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from functools import lru_cache
from typing import TYPE_CHECKING

import boto3

from codeignite.config import settings

if TYPE_CHECKING:
    # See storage/objects.py's matching comment: mypy_boto3_sqs is a
    # type-check-only dev dependency, not installed into the Lambda zip, so
    # it must never be imported at module load time.
    from mypy_boto3_sqs import SQSClient
    from mypy_boto3_sqs.type_defs import MessageTypeDef


@lru_cache(maxsize=1)
def _client() -> SQSClient:
    return boto3.client("sqs", region_name=settings.aws_region)


def send_job(job_id: str) -> None:
    _client().send_message(
        QueueUrl=settings.runs_queue_url,
        MessageBody=json.dumps({"job_id": job_id}),
    )


@dataclass(frozen=True, slots=True)
class ReceivedMessage:
    # None means the message body didn't parse into a job ID — a poisoned
    # message. Callers must not delete it (see worker/loop.py): leaving it
    # alone lets SQS's own redelivery/DLQ handling take over, rather than the
    # worker silently discarding a message it can't make sense of.
    job_id: str | None
    receipt_handle: str


def receive_jobs(max_messages: int = 1, wait_time_seconds: int = 20) -> list[ReceivedMessage]:
    response = _client().receive_message(
        QueueUrl=settings.runs_queue_url,
        MaxNumberOfMessages=max_messages,
        WaitTimeSeconds=wait_time_seconds,
    )
    return [_parse_message(raw) for raw in response.get("Messages", [])]


def _parse_message(raw: MessageTypeDef) -> ReceivedMessage:
    receipt_handle = raw["ReceiptHandle"]
    try:
        body = json.loads(raw["Body"])
        job_id = body["job_id"]
        if not isinstance(job_id, str):
            raise TypeError("job_id must be a string")
    except (json.JSONDecodeError, KeyError, TypeError):
        return ReceivedMessage(job_id=None, receipt_handle=receipt_handle)
    return ReceivedMessage(job_id=job_id, receipt_handle=receipt_handle)


def delete_job(receipt_handle: str) -> None:
    _client().delete_message(QueueUrl=settings.runs_queue_url, ReceiptHandle=receipt_handle)


def extend_visibility(receipt_handle: str, visibility_timeout: int) -> None:
    """Not called by the current worker loop — visibility_timeout (60s by
    default, infra/modules/run-pipeline) comfortably exceeds
    max_execution_seconds (10s by default), so there's no job the worker
    can't finish inside one visibility window today. Kept because
    docs/code-playground-implementation-plan.md documents it as part of this
    module's interface, and because a future longer-running language
    (compiled languages, stage 6) may need it.
    """
    _client().change_message_visibility(
        QueueUrl=settings.runs_queue_url,
        ReceiptHandle=receipt_handle,
        VisibilityTimeout=visibility_timeout,
    )
