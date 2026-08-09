#!/usr/bin/env bash
# Builds backend/dist/api.zip — the deployment package for
# infra/modules/run-api's zip-packaged Lambda function
# (codeignite.api.lambda_handler.handler). Run this before `terraform apply`
# in infra/envs/<env> whenever backend source or dependencies change;
# lambda.tf reads the file directly via filebase64sha256(), so a stale zip
# means a stale — not missing — deploy, unlike the "unset tag" failure mode
# an earlier draft of this module had with container images.
#
#   backend/scripts/build-lambda-zip.sh
#
# Deliberately no Docker, no ECR, no container image anywhere in this
# script — see docs/code-playground-hosted-api-plan.md §0 and §3 for why.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="build/lambda"
DIST_DIR="dist"
ZIP_PATH="$DIST_DIR/api.zip"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

# --platform/--python-version/--implementation/--only-binary=:all: together
# tell pip to fetch prebuilt manylinux wheels for Lambda's Amazon Linux
# runtime instead of compiling against this machine's own platform — this
# is what makes pyjwt[crypto]'s compiled `cryptography` dependency work when
# built on a developer's Mac or CI's own Linux, targeting Lambda's x86_64
# Python 3.12 runtime either way.
#
# `.[lambda]` pulls in exactly the base dependencies (pydantic, fastapi,
# boto3, pyjwt[crypto]) plus mangum — not `.[server]`'s uvicorn stack, which
# Mangum has no use for (see pyproject.toml's server/lambda extras comment).
pip install \
  --platform manylinux2014_x86_64 \
  --python-version 3.12 \
  --implementation cp \
  --only-binary=:all: \
  --target "$BUILD_DIR" \
  --no-compile \
  ".[lambda]"

# codeignite itself isn't installed by the pip command above (only its
# dependencies, via the [lambda] extra) — copied in directly so the zip's
# top-level layout is exactly `codeignite/...`, matching the
# `codeignite.api.lambda_handler.handler` string lambda.tf configures.
cp -r src/codeignite "$BUILD_DIR/codeignite"

rm -f "$ZIP_PATH"
(cd "$BUILD_DIR" && zip -rq "../../$ZIP_PATH" .)

echo "built $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"
