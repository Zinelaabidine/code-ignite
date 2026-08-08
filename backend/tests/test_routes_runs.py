"""Route-level tests. `client` (see conftest.py) is wired to
`FakeRunsGateway`, never to `S3SqsRunsGateway` — these tests are about
request validation, ordering, and response shaping, not S3/SQS, so they run
with no AWS credentials and no moto at all.

`client` also has `get_current_sub` and `get_rate_limiter` overridden with a
fixed fake `sub` and a generous limiter (see conftest.py), so most tests
below never touch real JWT verification. The auth-specific tests at the
bottom of this file build their own app instead, overriding only
`get_runs_gateway`, so `get_current_sub` and `enforce_rate_limit` run for
real."""

from fastapi.testclient import TestClient

from codeignite.api.app import create_app
from codeignite.api.auth import get_current_sub
from codeignite.api.rate_limit import InProcessTokenBucketLimiter, get_rate_limiter
from codeignite.api.routes_runs import MAX_CODE_LENGTH, get_runs_gateway
from codeignite.domain.models import JobInput
from codeignite.runner.base import RunResult
from tests.conftest import FAKE_SUB, FakeRunsGateway


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
    assert stored.user_sub == FAKE_SUB


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


def _own_input(*, user_sub: str = FAKE_SUB) -> JobInput:
    return JobInput(
        code="print(1)", language="python", submitted_at="2024-01-01T00:00:00", user_sub=user_sub
    )


def test_get_run_returns_202_pending_before_a_result_exists(
    client: TestClient, fake_runs_gateway: FakeRunsGateway
) -> None:
    job_id = "a" * 32
    fake_runs_gateway.inputs[job_id] = _own_input()

    response = client.get(f"/runs/{job_id}")

    assert response.status_code == 202
    assert response.json() == {"status": "pending"}


def test_get_run_returns_200_and_the_result_once_it_exists(
    client: TestClient, fake_runs_gateway: FakeRunsGateway
) -> None:
    job_id = "b" * 32
    fake_runs_gateway.inputs[job_id] = _own_input()
    fake_runs_gateway.results[job_id] = RunResult(
        stdout="hi\n", stderr="", exit_code=0, duration_ms=5, status="ok"
    )

    response = client.get(f"/runs/{job_id}")

    assert response.status_code == 200
    body = response.json()
    assert body["stdout"] == "hi\n"
    assert body["status"] == "ok"


def test_get_run_returns_404_for_a_job_id_that_was_never_submitted(
    client: TestClient, fake_runs_gateway: FakeRunsGateway
) -> None:
    job_id = "c" * 32

    response = client.get(f"/runs/{job_id}")

    assert response.status_code == 404


def test_get_run_returns_404_for_someone_elses_job(
    client: TestClient, fake_runs_gateway: FakeRunsGateway
) -> None:
    job_id = "d" * 32
    fake_runs_gateway.inputs[job_id] = _own_input(user_sub="a-different-user")

    response = client.get(f"/runs/{job_id}")

    assert response.status_code == 404


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


def _unauthenticated_client(fake_runs_gateway: FakeRunsGateway) -> TestClient:
    # Deliberately does not override get_current_sub / enforce_rate_limit —
    # unlike the `client` fixture, these tests need the real auth dependency
    # to run so a missing Authorization header actually gets rejected.
    app = create_app()
    app.dependency_overrides[get_runs_gateway] = lambda: fake_runs_gateway
    return TestClient(app)


def test_submit_run_without_a_token_is_rejected(fake_runs_gateway: FakeRunsGateway) -> None:
    client = _unauthenticated_client(fake_runs_gateway)

    response = client.post("/runs", json={"language": "python", "code": "print(1)"})

    assert response.status_code == 401
    assert fake_runs_gateway.inputs == {}


def test_get_run_without_a_token_is_rejected(fake_runs_gateway: FakeRunsGateway) -> None:
    client = _unauthenticated_client(fake_runs_gateway)

    response = client.get(f"/runs/{'a' * 32}")

    assert response.status_code == 401


def test_submit_run_with_a_malformed_bearer_token_is_rejected(
    fake_runs_gateway: FakeRunsGateway,
) -> None:
    client = _unauthenticated_client(fake_runs_gateway)

    response = client.post(
        "/runs",
        json={"language": "python", "code": "print(1)"},
        headers={"Authorization": "Bearer not-a-jwt"},
    )

    assert response.status_code == 401


def test_submit_run_is_rejected_once_the_rate_limit_bucket_is_empty(
    fake_runs_gateway: FakeRunsGateway,
) -> None:
    # Real get_current_sub, overridden only enough to skip JWT verification
    # (this is auth.py's own concern, covered by test_auth.py) — the point
    # here is that enforce_rate_limit's own logic actually runs and blocks.
    #
    # The override must return the *same* limiter instance every call — a
    # lambda that builds a fresh one per request would hand each request its
    # own full bucket and nothing would ever be rejected.
    limiter = InProcessTokenBucketLimiter(capacity=2)
    app = create_app()
    app.dependency_overrides[get_runs_gateway] = lambda: fake_runs_gateway
    app.dependency_overrides[get_current_sub] = lambda: FAKE_SUB
    app.dependency_overrides[get_rate_limiter] = lambda: limiter
    client = TestClient(app)

    payload = {"language": "python", "code": "print(1)"}
    responses = [client.post("/runs", json=payload) for _ in range(3)]

    assert [r.status_code for r in responses] == [202, 202, 429]
