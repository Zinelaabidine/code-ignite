"""Route-level tests. `client` (see conftest.py) is wired to `FakeRunner`,
never to `LocalDockerRunner` — these tests are about request validation and
response shaping, not sandboxing, so they run with no Docker daemon at all."""

from fastapi.testclient import TestClient

from codeignite.api.routes_runs import MAX_CODE_LENGTH
from codeignite.config import settings
from codeignite.runner.base import RunResult
from tests.conftest import FakeRunner


def test_healthz(client: TestClient) -> None:
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_submit_run_returns_the_runner_result(client: TestClient, fake_runner: FakeRunner) -> None:
    response = client.post("/runs", json={"language": "python", "code": "print('hi')"})

    assert response.status_code == 200
    body = response.json()
    assert body["stdout"] == "hi\n"
    assert body["status"] == "ok"
    assert body["truncated"] is False


def test_submit_run_forwards_code_language_and_configured_timeout(
    client: TestClient, fake_runner: FakeRunner
) -> None:
    client.post("/runs", json={"language": "python", "code": "print(1)"})

    assert fake_runner.last_call == {
        "code": "print(1)",
        "language": "python",
        "timeout": settings.max_execution_seconds,
    }


def test_unknown_language_is_rejected_before_reaching_the_runner(
    client: TestClient, fake_runner: FakeRunner
) -> None:
    response = client.post("/runs", json={"language": "cobol", "code": "x"})

    assert response.status_code == 422
    assert fake_runner.last_call is None


def test_code_over_the_length_cap_is_rejected_before_reaching_the_runner(
    client: TestClient, fake_runner: FakeRunner
) -> None:
    response = client.post(
        "/runs", json={"language": "python", "code": "a" * (MAX_CODE_LENGTH + 1)}
    )

    assert response.status_code == 422
    assert fake_runner.last_call is None


def test_non_ok_statuses_are_surfaced_verbatim(client: TestClient, fake_runner: FakeRunner) -> None:
    fake_runner.result = RunResult(
        stdout="", stderr="", exit_code=-1, duration_ms=8000, status="timeout"
    )

    response = client.post("/runs", json={"language": "python", "code": "while True: pass"})

    assert response.status_code == 200
    assert response.json()["status"] == "timeout"


def test_truncated_flag_passes_through(client: TestClient, fake_runner: FakeRunner) -> None:
    fake_runner.result = RunResult(
        stdout="x" * 10,
        stderr="",
        exit_code=0,
        duration_ms=5,
        status="ok",
        truncated=True,
    )

    response = client.post("/runs", json={"language": "python", "code": "print('x' * 999999)"})

    assert response.json()["truncated"] is True
