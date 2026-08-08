"""Build/runtime environment contract for the backend.

Mirrors the intent of `frontend/lib/env.ts`: declare the whole configuration
surface in one place, typed, so a missing or malformed value fails at process
startup rather than surfacing as a confusing runtime error three calls deep.

`aws_region`, `jobs_bucket` and `runs_queue_url` are the first fields with no
default — as promised when this module was scaffolded. There is no correct
fallback for them: they come from `infra/modules/run-pipeline`'s outputs
(`terraform output -raw jobs_bucket_name` / `runs_queue_url` in
`infra/envs/dev`), and a process that started against the wrong bucket or
queue would fail in a much more confusing way than refusing to start.
"""

from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Process configuration, read from the environment (or `.env` locally).

    All variables are prefixed `CODEIGNITE_` so they can't collide with
    unrelated environment variables (`AWS_REGION`, `LOG_LEVEL`, etc. are
    common enough to be owned by something else in a shared environment).
    """

    model_config = SettingsConfigDict(
        env_prefix="CODEIGNITE_",
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # Required — see the module docstring for why none of these three have a
    # default. Read by storage/objects.py, storage/queue.py, and the boto3
    # client construction in both.
    aws_region: str
    jobs_bucket: str
    runs_queue_url: str

    # Selects the Runner implementation at the composition root (now the
    # worker's — see worker/loop.py). The only value today is
    # "local_docker"; "kubernetes_job" arrives at the EKS migration described
    # in docs/code-playground-plan.md and is added here the same PR it's
    # implemented, not before.
    runner_backend: Literal["local_docker"] = "local_docker"

    # Wall-clock ceiling passed to the runner as `timeout`. Matches the `timeout
    # 8` inside the Docker command plus headroom, per the architecture doc.
    max_execution_seconds: int = 10

    log_level: str = "INFO"


settings = Settings()
