"""Shared fixtures. `FakeRunner` is what keeps `test_routes_runs.py` from
ever touching Docker — the route layer only knows about the `Runner`
Protocol, so a fake that satisfies it is a complete substitute for tests."""

import pytest
from fastapi.testclient import TestClient

from codeignite.api.app import create_app
from codeignite.api.routes_runs import get_runner
from codeignite.runner.base import RunResult


class FakeRunner:
    def __init__(self) -> None:
        self.result = RunResult(stdout="hi\n", stderr="", exit_code=0, duration_ms=5, status="ok")
        self.last_call: dict[str, object] | None = None

    def run(self, code: str, language: str, timeout: int) -> RunResult:
        self.last_call = {"code": code, "language": language, "timeout": timeout}
        return self.result


@pytest.fixture
def fake_runner() -> FakeRunner:
    return FakeRunner()


@pytest.fixture
def client(fake_runner: FakeRunner) -> TestClient:
    app = create_app()
    app.dependency_overrides[get_runner] = lambda: fake_runner
    return TestClient(app)
