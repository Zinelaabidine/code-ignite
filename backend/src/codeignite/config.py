"""Build/runtime environment contract for the backend.

Mirrors the intent of `frontend/lib/env.ts`: declare the whole configuration
surface in one place, typed, so a missing or malformed value fails at process
startup rather than surfacing as a confusing runtime error three calls deep.

Every field here already has a default because nothing in this PR consumes
these values yet — the local Docker runner (next PR) is the first reader of
`runner_backend` and `max_execution_seconds`. Stage 2 (async runs) adds
`aws_region`, `jobs_bucket` and `runs_queue_url` with no defaults, the way
`lib/env.ts` has none for its three variables — at that point there really is
no correct value to fall back to.
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

    # Selects the Runner implementation at the composition root. The only
    # value today is "local_docker"; "kubernetes_job" arrives at the EKS
    # migration described in docs/code-playground-plan.md and is added here
    # the same PR it's implemented, not before.
    runner_backend: Literal["local_docker"] = "local_docker"

    # Wall-clock ceiling passed to the runner as `timeout`. Matches the `timeout
    # 8` inside the Docker command plus headroom, per the architecture doc.
    max_execution_seconds: int = 10

    log_level: str = "INFO"


settings = Settings()
