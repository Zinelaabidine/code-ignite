"""`POST /runs` / `GET /runs/{job_id}` — asynchronous, per
docs/code-playground-plan.md's flow, both behind a verified Cognito access
token (stage 3, `api/auth.py`):

    POST /runs          → verify token, rate-limit on its `sub`
                        → job_id = uuid4()
                        → S3 PUT  jobs/{job_id}/input.json   {..., user_sub}
                        → SQS SEND {job_id}
                        → 202 {job_id}

    GET /runs/{job_id}  → verify token
                        → S3 GET input.json; 404 if missing or owned by a
                          different `sub`
                        → S3 GET result.json
                        → 200 result, or 202 {"status":"pending"} if not there yet

The worker (worker/loop.py) is what actually runs code now — this file no
longer imports `Runner` or `LocalDockerRunner` at all. That's the visible
effect of the stage 1 → stage 2 split: the API's only job is to enqueue.

`RunsGateway` is this module's composition root, same pattern as stage 1's
`get_runner`: routes depend on the Protocol via `Depends`, tests substitute
`FakeRunsGateway` instead of touching S3/SQS.
"""

import uuid
from datetime import UTC, datetime
from typing import Literal, Protocol

from fastapi import APIRouter, Depends, HTTPException, Path, Response
from pydantic import BaseModel, Field, field_validator

from codeignite.api.auth import get_current_sub
from codeignite.api.rate_limit import enforce_rate_limit
from codeignite.domain.languages import LANGUAGES
from codeignite.domain.models import JobInput
from codeignite.runner.base import RunResult, RunStatus
from codeignite.storage import objects, queue

router = APIRouter()

# Approximate — pydantic's max_length counts characters, not bytes, so a
# code sample using multi-byte characters could exceed 64 KiB of actual
# storage before hitting this cap. Close enough for a request-size guard;
# revisit if it ever needs to be exact.
MAX_CODE_LENGTH = 64 * 1024

# Exactly what uuid.uuid4().hex produces. Constraining the job_id path
# parameter to this shape before it reaches an S3 key rules out path
# traversal via a crafted job_id ("../", url-encoded separators, etc.) —
# rejected as a 422 before any storage call.
JOB_ID_PATTERN = r"^[0-9a-f]{32}$"


class RunRequest(BaseModel):
    language: str
    code: str = Field(max_length=MAX_CODE_LENGTH)

    @field_validator("language")
    @classmethod
    def language_must_be_registered(cls, value: str) -> str:
        # Validated here, not left for the worker to discover: an unknown
        # language must never become a value that reaches `docker run`.
        if value not in LANGUAGES:
            supported = ", ".join(sorted(LANGUAGES))
            raise ValueError(f"unsupported language {value!r} — supported: {supported}")
        return value


class SubmitRunResponse(BaseModel):
    job_id: str


class RunResponse(BaseModel):
    stdout: str
    stderr: str
    exit_code: int
    duration_ms: int
    status: RunStatus
    truncated: bool


class PendingResponse(BaseModel):
    status: Literal["pending"] = "pending"


def _to_response(result: RunResult) -> RunResponse:
    return RunResponse(
        stdout=result.stdout,
        stderr=result.stderr,
        exit_code=result.exit_code,
        duration_ms=result.duration_ms,
        status=result.status,
        truncated=result.truncated,
    )


class RunsGateway(Protocol):
    """The storage operations the API needs — nothing more. `get_input` is
    here (and not only in `storage/`) because `get_run`'s ownership check
    needs the stored `user_sub` before it can return a result. The worker
    needs more than this (`delete_job`, `extend_visibility`, ...), which is
    exactly why the fuller surface lives in `storage/` as plain functions
    rather than behind this Protocol: this stays scoped to what a route
    handler does.
    """

    def put_input(self, job_id: str, job_input: JobInput) -> None: ...
    def send_job(self, job_id: str) -> None: ...
    def get_input(self, job_id: str) -> JobInput | None: ...
    def get_result(self, job_id: str) -> RunResult | None: ...


class S3SqsRunsGateway:
    """The real implementation, backed by storage/objects.py and
    storage/queue.py. `get_runner`'s successor for this file — the one place
    that talks to actual AWS.
    """

    def put_input(self, job_id: str, job_input: JobInput) -> None:
        objects.put_input(job_id, job_input)

    def send_job(self, job_id: str) -> None:
        queue.send_job(job_id)

    def get_input(self, job_id: str) -> JobInput | None:
        return objects.get_input(job_id)

    def get_result(self, job_id: str) -> RunResult | None:
        return objects.get_result(job_id)


def get_runs_gateway() -> RunsGateway:
    return S3SqsRunsGateway()


@router.post("/runs", status_code=202, response_model=SubmitRunResponse)
def submit_run(
    payload: RunRequest,
    sub: str = Depends(enforce_rate_limit),
    gateway: RunsGateway = Depends(get_runs_gateway),
) -> SubmitRunResponse:
    job_id = uuid.uuid4().hex
    job_input = JobInput(
        code=payload.code,
        language=payload.language,
        submitted_at=datetime.now(UTC).isoformat(),
        user_sub=sub,
    )

    # Order matters and must never change: the worker can receive the job ID
    # the instant it's on the queue, so the input has to exist in S3 first.
    # Reversing this lets a worker win the race against S3 and find nothing.
    gateway.put_input(job_id, job_input)
    gateway.send_job(job_id)

    return SubmitRunResponse(job_id=job_id)


@router.get("/runs/{job_id}")
def get_run(
    response: Response,
    job_id: str = Path(..., pattern=JOB_ID_PATTERN),
    sub: str = Depends(get_current_sub),
    gateway: RunsGateway = Depends(get_runs_gateway),
) -> RunResponse | PendingResponse:
    job_input = gateway.get_input(job_id)
    if job_input is None or job_input.user_sub != sub:
        # Same 404 either way — a job_id the caller never submitted must
        # look identical to one that belongs to someone else. Job IDs are
        # UUIDs, but returning 403 for "not yours" vs 404 for "no such job"
        # would leak which guessed IDs are live.
        raise HTTPException(status_code=404)

    result = gateway.get_result(job_id)
    if result is None:
        response.status_code = 202
        return PendingResponse()
    return _to_response(result)
