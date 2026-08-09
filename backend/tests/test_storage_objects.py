"""S3 read/write, backed by moto — never touches real AWS. Bucket creation
is this test file's own setup, matching what
infra/modules/run-pipeline actually provisions
(docs/prs/03-run-pipeline-infra.md); objects.py itself never creates a
bucket."""

from collections.abc import Iterator

import boto3
import pytest
from moto import mock_aws

from codeignite.config import settings
from codeignite.domain.models import JobInput
from codeignite.runner.base import RunResult
from codeignite.storage import objects


@pytest.fixture(autouse=True)
def _mocked_bucket() -> Iterator[None]:
    with mock_aws():
        boto3.client("s3", region_name=settings.aws_region).create_bucket(
            Bucket=settings.jobs_bucket
        )
        yield


def test_input_and_result_keys_are_namespaced_under_jobs_prefix() -> None:
    assert objects.input_key("abc") == "jobs/abc/input.json"
    assert objects.result_key("abc") == "jobs/abc/result.json"


class TestPutGetInput:
    def test_round_trips(self) -> None:
        job_input = JobInput(
            code="print(1)",
            language="python",
            submitted_at="2026-01-01T00:00:00+00:00",
            user_sub=None,
        )
        objects.put_input("job-1", job_input)

        assert objects.get_input("job-1") == job_input

    def test_missing_input_returns_none(self) -> None:
        assert objects.get_input("does-not-exist") is None

    def test_user_sub_round_trips_when_set(self) -> None:
        job_input = JobInput(
            code="1", language="python", submitted_at="t", user_sub="cognito-sub-123"
        )
        objects.put_input("job-2", job_input)

        result = objects.get_input("job-2")

        assert result is not None
        assert result.user_sub == "cognito-sub-123"


class TestPutGetResult:
    def test_round_trips(self) -> None:
        result = RunResult(
            stdout="hi\n", stderr="", exit_code=0, duration_ms=12, status="ok", truncated=False
        )
        objects.put_result("job-3", result)

        assert objects.get_result("job-3") == result

    def test_missing_result_returns_none(self) -> None:
        assert objects.get_result("does-not-exist") is None

    def test_access_denied_for_list_bucket_is_treated_as_missing(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        # Reproduces the hosted GET /runs/{id} 500: without s3:ListBucket,
        # GetObject on a not-yet-written result.json raises AccessDenied
        # mentioning ListBucket instead of NoSuchKey. Must become None so
        # routes_runs returns 202 pending, not an unhandled 500.
        from botocore.exceptions import ClientError

        def _raise_list_bucket_denied(**_kwargs: object) -> None:
            raise ClientError(
                {
                    "Error": {
                        "Code": "AccessDenied",
                        "Message": (
                            "User is not authorized to perform: s3:ListBucket "
                            'on resource: "arn:aws:s3:::bucket"'
                        ),
                    }
                },
                "GetObject",
            )

        monkeypatch.setattr(objects._client(), "get_object", _raise_list_bucket_denied)

        assert objects.get_result("pending-job") is None

    def test_truncated_flag_round_trips(self) -> None:
        result = RunResult(
            stdout="x" * 10, stderr="", exit_code=0, duration_ms=1, status="ok", truncated=True
        )
        objects.put_result("job-4", result)

        got = objects.get_result("job-4")

        assert got is not None
        assert got.truncated is True

    def test_non_ok_status_round_trips(self) -> None:
        result = RunResult(stdout="", stderr="", exit_code=-1, duration_ms=8000, status="timeout")
        objects.put_result("job-5", result)

        got = objects.get_result("job-5")

        assert got is not None
        assert got.status == "timeout"
