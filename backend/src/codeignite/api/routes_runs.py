"""`POST /runs` — synchronous for now.

Stage 1 of docs/code-playground-plan.md runs the sandbox inline and returns
the result in the same request. Stage 2 (async runs) replaces the body of
`submit_run` with an S3 write + SQS send and a `202 {job_id}`, and this file
gains a `GET /runs/{job_id}` — the request/response *shapes* defined here
(`RunRequest`, `RunResponse`) carry over unchanged, since they mirror
`RunResult` field-for-field.

`get_runner` is this module's composition root: the only function that
imports `LocalDockerRunner`. Every route depends on `Runner` (the Protocol),
injected via FastAPI's `Depends`, so tests substitute a fake runner with
`app.dependency_overrides[get_runner] = ...` instead of touching Docker.
"""

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field, field_validator

from codeignite.config import settings
from codeignite.domain.languages import LANGUAGES
from codeignite.runner.base import Runner, RunResult, RunStatus
from codeignite.runner.local_docker import LocalDockerRunner

router = APIRouter()

# Approximate — pydantic's max_length counts characters, not bytes, so a
# code sample using multi-byte characters could exceed 64 KiB of actual
# storage before hitting this cap. Close enough for a request-size guard;
# revisit if it ever needs to be exact.
MAX_CODE_LENGTH = 64 * 1024


class RunRequest(BaseModel):
    language: str
    code: str = Field(max_length=MAX_CODE_LENGTH)

    @field_validator("language")
    @classmethod
    def language_must_be_registered(cls, value: str) -> str:
        # Validated here, not left for the runner to discover: an unknown
        # language must never become a value that reaches `docker run`.
        if value not in LANGUAGES:
            supported = ", ".join(sorted(LANGUAGES))
            raise ValueError(f"unsupported language {value!r} — supported: {supported}")
        return value


class RunResponse(BaseModel):
    stdout: str
    stderr: str
    exit_code: int
    duration_ms: int
    status: RunStatus
    truncated: bool


def _to_response(result: RunResult) -> RunResponse:
    return RunResponse(
        stdout=result.stdout,
        stderr=result.stderr,
        exit_code=result.exit_code,
        duration_ms=result.duration_ms,
        status=result.status,
        truncated=result.truncated,
    )


def get_runner() -> Runner:
    """FastAPI dependency — the one place this module picks a concrete
    `Runner`. Stage 2 makes this read `settings.runner_backend`; today there
    is exactly one implementation, so there is nothing to branch on yet.
    """
    return LocalDockerRunner()


@router.post("/runs", response_model=RunResponse)
def submit_run(payload: RunRequest, runner: Runner = Depends(get_runner)) -> RunResponse:
    result = runner.run(
        code=payload.code,
        language=payload.language,
        timeout=settings.max_execution_seconds,
    )
    return _to_response(result)
