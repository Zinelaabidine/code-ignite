"""FastAPI application factory.

A factory rather than a module-level `app` that does its own wiring: tests
build a fresh app per test via `create_app()` and override
`routes_runs.get_runner` on that instance, instead of mutating shared global
state that would leak between tests.
"""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from codeignite import __version__
from codeignite.api.routes_runs import router as runs_router
from codeignite.config import settings


def create_app() -> FastAPI:
    app = FastAPI(title="codeignite", version=__version__)

    # Explicit origin allowlist, not "*": the bearer token travels as a
    # request header rather than a cookie, so allow_credentials stays
    # False and there's no CSRF surface from this — but a wildcard origin
    # would still let any page's JS read the response.
    #
    # Both custom headers must be listed or the browser's preflight fails.
    # This only bites local development (localhost:3000 -> localhost:8000 is
    # cross-origin); the deployed frontend is same-origin behind CloudFront
    # and never sends a preflight at all, which is exactly why a missing
    # entry here would go unnoticed until someone ran the stack locally.
    origins = [
        origin.strip() for origin in settings.cors_allowed_origins.split(",") if origin.strip()
    ]
    app.add_middleware(
        CORSMiddleware,
        allow_origins=origins,
        allow_credentials=False,
        allow_methods=["GET", "POST", "OPTIONS"],
        allow_headers=[
            "Authorization",
            "Content-Type",
            "X-Codeignite-Authorization",
            "x-amz-content-sha256",
        ],
    )

    app.include_router(runs_router)

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    return app


# Entrypoint for `uvicorn codeignite.api.app:app`.
app = create_app()
