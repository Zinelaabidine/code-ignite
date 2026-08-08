"""Every field has a default today (see config.py's docstring for why), so
this only pins down those defaults and the env-var override path — the same
override path stage 2 relies on for the values that won't have defaults."""

import pytest

from codeignite.config import Settings


def test_defaults() -> None:
    settings = Settings(_env_file=None)  # type: ignore[call-arg]
    assert settings.runner_backend == "local_docker"
    assert settings.max_execution_seconds == 10
    assert settings.log_level == "INFO"


def test_env_var_override(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CODEIGNITE_MAX_EXECUTION_SECONDS", "30")
    settings = Settings(_env_file=None)  # type: ignore[call-arg]
    assert settings.max_execution_seconds == 30
