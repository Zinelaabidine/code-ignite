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

`cognito_user_pool_id` and `cognito_client_id` are required for the same
reason, added in stage 3 (`api/auth.py`): they come from
`infra/modules/static-site`'s Cognito outputs (the same pool the frontend
already points at — see `frontend/.env.example`), and an API that started
against the wrong pool would silently accept tokens from a different user
pool. Not secrets: same reasoning as `frontend/lib/env.ts` — a pool ID and
public SPA client ID are designed to be visible.
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

    # Required — see the module docstring. Read by api/auth.py to build the
    # JWKS URL and to check a verified token's `client_id` claim.
    cognito_user_pool_id: str
    cognito_client_id: str

    # Comma-separated, not a JSON list — keeps `.env` editable by hand the
    # same way the rest of this file is. Split by api/app.py, not here, so
    # this module stays free of any FastAPI-specific concern.
    cors_allowed_origins: str = "http://localhost:3000"

    # Selects the Runner implementation at the composition root (now the
    # worker's — see worker/loop.py). The only value today is
    # "local_docker"; "kubernetes_job" arrives at the EKS migration described
    # in docs/code-playground-plan.md and is added here the same PR it's
    # implemented, not before.
    runner_backend: Literal["local_docker"] = "local_docker"

    # Wall-clock ceiling passed to the runner as `timeout`. Matches the `timeout
    # 8` inside the Docker command plus headroom, per the architecture doc.
    max_execution_seconds: int = 10

    # "Docker outside of Docker" support for `LocalDockerRunner`
    # (`runner/local_docker.py`). The worker container talks to the *host's*
    # Docker daemon through the mounted socket, so a `docker run -v
    # <path>:/sandbox:ro` it builds must name a path the daemon can resolve —
    # not a path inside the worker container, which the daemon knows nothing
    # about. Both point at the same bind-mounted directory from two
    # different vantage points: `job_workspace_dir` is where this process
    # itself writes job files, `host_job_workspace_dir` is where
    # `docker-compose.yml` bind-mounted that same directory from on the
    # host. Both are unset when the runner talks directly to a Docker daemon
    # on the same filesystem it writes to — e.g. stage 1's `pytest -m
    # docker` on a dev machine, or `python -m codeignite.worker` run outside
    # a container — where there is nothing to translate.
    job_workspace_dir: str | None = None
    host_job_workspace_dir: str | None = None

    log_level: str = "INFO"


settings = Settings()
