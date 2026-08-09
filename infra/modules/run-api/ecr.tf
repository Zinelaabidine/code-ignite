# Deliberately empty. This module used to hold an ECR repository here for a
# container-image-packaged Lambda; per
# docs/code-playground-hosted-api-plan.md §0, this repo does not use ECR,
# ECS, or EKS anywhere, and Lambda's container image support requires an
# ECR-hosted image specifically (it cannot pull from Docker Hub or any other
# registry) — so the Lambda in lambda.tf is zip-packaged instead
# (codeignite.api.lambda_handler.handler, built by
# backend/scripts/build-lambda-zip.sh). Kept as an empty file rather than
# deleted: this sandbox could not remove it directly (a filesystem
# permission restriction on files already touched by an external editor) —
# safe to `git rm infra/modules/run-api/ecr.tf` by hand.
