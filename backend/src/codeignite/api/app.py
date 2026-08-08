"""FastAPI application factory.

A factory rather than a module-level `app` that does its own wiring: tests
build a fresh app per test via `create_app()` and override
`routes_runs.get_runner` on that instance, instead of mutating shared global
state that would leak between tests.
"""

from fastapi import FastAPI

from codeignite import __version__
from codeignite.api.routes_runs import router as runs_router


def create_app() -> FastAPI:
    app = FastAPI(title="codeignite", version=__version__)
    app.include_router(runs_router)

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    return app


# Entrypoint for `uvicorn codeignite.api.app:app`.
app = create_app()
