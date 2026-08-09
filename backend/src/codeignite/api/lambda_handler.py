"""Entrypoint for the hosted API — infra/modules/run-api's zip-packaged
Lambda function points its `handler` at
`codeignite.api.lambda_handler.handler`.

Mangum, not a container image + the AWS Lambda Web Adapter: this repository
does not use Amazon ECR, ECS, or EKS anywhere (see
`docs/code-playground-hosted-api-plan.md` §0 and §3) — Lambda's container
image support requires the image to live in ECR specifically, which rules
that packaging route out entirely regardless of where the image is built or
pushed. Mangum translates a Lambda Function URL's HTTP API v2 event into an
ASGI call against `app` directly, in-process — no server process, no
adapter binary, no container.

`create_app()` itself (`api/app.py`) stays completely unaware this file
exists; this is the only Lambda-specific code in the whole application.
"""

from mangum import Mangum

from codeignite.api.app import app

# lifespan="off": FastAPI's startup/shutdown lifespan events model a
# long-lived server process. Lambda's execution model — a function that may
# be frozen, thawed, or replaced between invocations — doesn't match that,
# and this app's lifespan hooks (none today) would run at unpredictable
# points relative to actual requests if left on.
handler = Mangum(app, lifespan="off")
