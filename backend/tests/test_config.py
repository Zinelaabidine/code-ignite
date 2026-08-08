"""aws_region/jobs_bucket/runs_queue_url are required (see config.py's
docstring for why); the rest still have defaults. `pytest-env`
(pyproject.toml) supplies placeholder values for the required three so a
plain `Settings()` works in every other test in this suite — the tests here
explicitly clear them to exercise the "fails loudly" contract itself."""

import pytest
from pydantic import ValidationError

from codeignite.config import Settings

_REQUIRED_KWARGS = {
    "aws_region": "us-east-1",
    "jobs_bucket": "test-jobs-bucket",
    "runs_queue_url": "https://sqs.us-east-1.amazonaws.com/123456789012/test-runs-queue",
}


def test_defaults() -> None:
    settings = Settings(_env_file=None, **_REQUIRED_KWARGS)  # type: ignore[call-arg]
    assert settings.runner_backend == "local_docker"
    assert settings.max_execution_seconds == 10
    assert settings.log_level == "INFO"


def test_env_var_override(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CODEIGNITE_MAX_EXECUTION_SECONDS", "30")
    settings = Settings(_env_file=None, **_REQUIRED_KWARGS)  # type: ignore[call-arg]
    assert settings.max_execution_seconds == 30


def test_required_fields_have_no_fallback(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("CODEIGNITE_AWS_REGION", raising=False)
    monkeypatch.delenv("CODEIGNITE_JOBS_BUCKET", raising=False)
    monkeypatch.delenv("CODEIGNITE_RUNS_QUEUE_URL", raising=False)

    with pytest.raises(ValidationError) as excinfo:
        Settings(_env_file=None)  # type: ignore[call-arg]

    missing = {error["loc"][0] for error in excinfo.value.errors()}
    assert missing == {"aws_region", "jobs_bucket", "runs_queue_url"}
