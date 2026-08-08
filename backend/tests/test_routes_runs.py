"""Route-level tests. `client` (see conftest.py) is wired to
`FakeRunsGateway`, never to `S3SqsRunsGateway` — these tests are about
request validation, ordering, and response shaping, not S3/SQS, so they run
with no AWS credentials and no moto at all."""

from fastapi.testclient import TestClient

from codeignite.api.routes_runs import MAX_CODE_LENGTH
from codeignite.runner.base import RunResult
from tests.conftest import FakeRunsGateway


def test_healthz(client: TestClient) -> None:
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_submit_run_returns_202_and_a_job_id(
    client: TestClient, fake_runs_gateway: FakeRunsGateway
) -> None:
    response = client.post("/runs", json={"language": "python", "code": "print('hi')"})

    assert response.status_code == 202
    job_id = response.json()["job_id"]
    assert len(job_id) == 32
    assert all(c in "0123456789abcdef" for c in job_id)


def test_submit_run_writes_input_before_sending_to_the_queue(
    client: TestClient, fake_runs_gateway: FakeRunsGateway
) -> None:
    # Ordering matters (see routes_runs.py's comment): a worker could
    # otherwise receive the job ID before the input exists in S3.
    client.post("/runs", json={"language": "python", "code": "print(1)"})

    assert fake_runs_gateway.call_log == ["put_input", "send_job"]


def test_submit_run_stores_code_and_language_in_the_job_input(
    client: TestClient, fake_runs_gateway: FakeRunsGateway
) -> None:
    response = client.post("/runs", json={"language": "python", "code": "print(1)"})
    job_id = response.json()["job_id"]

    stored = fake_runs_gateway.inputs[job_id]
    assert stored.code == "print(1)"
    assert stored.language == "python"
    assert stored.user_sub is None


def test_unknown_language_is_rejected_before_reaching_the_gateway(
    client: TestClient, fake_runs_gateway: FakeRunsGateway
) -> None:
    response = client.post("/runs", json={"language": "cobol", "code": "x"})

    assert response.status_code == 422
    assert fake_runs_gateway.inputs == {}
    assert fake_runs_gateway.sent_job_ids == []


def test_code_over_the_length_cap_is_rejected_before_reaching_the_gateway(
    client: TestClient, fake_runs_gateway: FakeRunsGateway
) -> None:
    response = client.post(
        "/runs", json={"language": "python", "code": "a" * (MAX_CODE_LENGTH + 1)}
    )

    assert response.status_code == 422
    assert fake_runs_gateway.inputs == {}


def test_get_run_returns_202_pending_before_a_result_exists(
    client: TestClient, fake_runs_gateway: FakeRunsGateway
) -> None:
    job_id = "a" * 32

    response = client.get(f"/runs/{job_id}")

    assert response.status_code == 202
    assert response.json() == {"status": "pending"}


def test_get_run_returns_200_and_the_result_once_it_exists(
    client: TestClient, fake_runs_gateway: FakeRunsGateway
) -> None:
    job_id = "b" * 32
    fake_runs_gateway.results[job_id] = RunResult(
        stdout="hi\n", stderr="", exit_code=0, duration_ms=5, status="ok"
    )

    response = client.get(f"/runs/{job_id}")

    assert response.status_code == 200
    body = response.json()
    assert body["stdout"] == "hi\n"
    assert body["status"] == "ok"


def test_get_run_rejects_a_malformed_job_id_before_reaching_the_gateway(
    client: TestClient, fake_runs_gateway: FakeRunsGateway
) -> None:
    # Not 32 lowercase hex characters — including an attempted path
    # traversal, which is exactly what the pattern constraint exists to stop
    # before it becomes part of an S3 key.
    response = client.get("/runs/../../etc/passwd")

    assert response.status_code in (404, 422)


def test_get_run_rejects_wrong_length_job_id(client: TestClient) -> None:
    response = client.get("/runs/short")

    assert response.status_code == 422
