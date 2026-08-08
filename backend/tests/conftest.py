"""Shared fixtures. `FakeRunsGateway` is what keeps `test_routes_runs.py`
from ever touching S3/SQS — the route layer only knows about the
`RunsGateway` Protocol, so a fake that satisfies it is a complete substitute
for tests, the same pattern `FakeRunner` established for the `Runner`
Protocol in stage 1.

The required `CODEIGNITE_*` env vars (`aws_region`, `jobs_bucket`,
`runs_queue_url`, `cognito_user_pool_id`, `cognito_client_id` — see
`config.py`) are set via `pytest-env` in `pyproject.toml`, not here, since
`config.py` instantiates `Settings()` eagerly at import time and needs a
value before the first test module even finishes importing
`codeignite.config`.

The `client` fixture below overrides `get_current_sub` with a fixed fake
`sub` and `get_rate_limiter` with a fresh, high-capacity limiter — most
route tests are about request validation, ordering, and response shaping,
not about JWT verification or throttling, so they run with no real token and
no risk of a shared bucket going empty across the suite. `test_auth.py`
and the auth-specific tests in `test_routes_runs.py` exercise the real
dependencies directly instead of going through this fixture.
"""

from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient

from codeignite.api.app import create_app
from codeignite.api.auth import get_current_sub
from codeignite.api.rate_limit import InProcessTokenBucketLimiter, get_rate_limiter
from codeignite.api.routes_runs import get_runs_gateway
from codeignite.domain.models import JobInput
from codeignite.runner.base import RunResult
from codeignite.storage import objects, queue

FAKE_SUB = "test-user-sub"


class FakeRunsGateway:
    def __init__(self) -> None:
        self.inputs: dict[str, JobInput] = {}
        self.sent_job_ids: list[str] = []
        self.results: dict[str, RunResult] = {}
        # Records "put_input" / "send_job" in call order — lets tests assert
        # the S3-before-SQS ordering routes_runs.py's docstring calls out as
        # load-bearing, without monkeypatching methods.
        self.call_log: list[str] = []

    def put_input(self, job_id: str, job_input: JobInput) -> None:
        self.call_log.append("put_input")
        self.inputs[job_id] = job_input

    def send_job(self, job_id: str) -> None:
        self.call_log.append("send_job")
        self.sent_job_ids.append(job_id)

    def get_input(self, job_id: str) -> JobInput | None:
        return self.inputs.get(job_id)

    def get_result(self, job_id: str) -> RunResult | None:
        return self.results.get(job_id)


@pytest.fixture
def fake_runs_gateway() -> FakeRunsGateway:
    return FakeRunsGateway()


@pytest.fixture
def client(fake_runs_gateway: FakeRunsGateway) -> TestClient:
    app = create_app()
    app.dependency_overrides[get_runs_gateway] = lambda: fake_runs_gateway
    app.dependency_overrides[get_current_sub] = lambda: FAKE_SUB
    app.dependency_overrides[get_rate_limiter] = lambda: InProcessTokenBucketLimiter(capacity=1000)
    return TestClient(app)


@pytest.fixture(autouse=True)
def _reset_boto3_client_caches() -> Iterator[None]:
    """`storage/objects.py` and `storage/queue.py` each cache their boto3
    client with `lru_cache`. Left alone, a client built while a moto mock was
    active in one test would leak into the next test (which may or may not
    have its own mock active), since `lru_cache` state lives at module scope
    and outlives any single test. Runs for every test, not just the
    moto-backed ones — cheap even when nothing was cached.
    """
    yield
    objects._client.cache_clear()
    queue._client.cache_clear()
