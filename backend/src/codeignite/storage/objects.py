"""S3 read/write for the job object layout fixed in
`docs/code-playground-plan.md`:

    jobs/{job_id}/input.json    {code, language, submitted_at, user_sub}
    jobs/{job_id}/result.json   {stdout, stderr, exit_code, duration_ms,
                                  status, truncated}

`get_input`/`get_result` return `None` on a missing key rather than raising —
that "not there yet" is the expected, common case for `get_result` (the API
polls it before the worker has finished) and is exactly what distinguishes
202 from 200 in `api/routes_runs.py`.
"""

import json
from functools import lru_cache
from typing import Any

import boto3
from botocore.exceptions import ClientError
from mypy_boto3_s3 import S3Client

from codeignite.config import settings
from codeignite.domain.models import JobInput
from codeignite.runner.base import RunResult, RunStatus


@lru_cache(maxsize=1)
def _client() -> S3Client:
    return boto3.client("s3", region_name=settings.aws_region)


def input_key(job_id: str) -> str:
    return f"jobs/{job_id}/input.json"


def result_key(job_id: str) -> str:
    return f"jobs/{job_id}/result.json"


def put_input(job_id: str, job_input: JobInput) -> None:
    body = json.dumps(
        {
            "code": job_input.code,
            "language": job_input.language,
            "submitted_at": job_input.submitted_at,
            "user_sub": job_input.user_sub,
        }
    ).encode("utf-8")
    _client().put_object(
        Bucket=settings.jobs_bucket,
        Key=input_key(job_id),
        Body=body,
        ContentType="application/json",
    )


def get_input(job_id: str) -> JobInput | None:
    data = _get_json(input_key(job_id))
    if data is None:
        return None
    return JobInput(
        code=data["code"],
        language=data["language"],
        submitted_at=data["submitted_at"],
        user_sub=data.get("user_sub"),
    )


def put_result(job_id: str, result: RunResult) -> None:
    body = json.dumps(
        {
            "stdout": result.stdout,
            "stderr": result.stderr,
            "exit_code": result.exit_code,
            "duration_ms": result.duration_ms,
            "status": result.status,
            "truncated": result.truncated,
        }
    ).encode("utf-8")
    _client().put_object(
        Bucket=settings.jobs_bucket,
        Key=result_key(job_id),
        Body=body,
        ContentType="application/json",
    )


def get_result(job_id: str) -> RunResult | None:
    data = _get_json(result_key(job_id))
    if data is None:
        return None
    status: RunStatus = data["status"]
    return RunResult(
        stdout=data["stdout"],
        stderr=data["stderr"],
        exit_code=data["exit_code"],
        duration_ms=data["duration_ms"],
        status=status,
        truncated=data.get("truncated", False),
    )


def _get_json(key: str) -> dict[str, Any] | None:
    try:
        response = _client().get_object(Bucket=settings.jobs_bucket, Key=key)
    except ClientError as error:
        if error.response.get("Error", {}).get("Code") in ("NoSuchKey", "404"):
            return None
        raise
    body: dict[str, Any] = json.loads(response["Body"].read())
    return body
