# The API itself — api/app.py's create_app(), reached through
# api/lambda_handler.py's Mangum wrapper. Zip-packaged, not a container
# image: this repo uses no ECR, ECS, or EKS anywhere (see
# docs/code-playground-hosted-api-plan.md §0), and Lambda's container image
# support only ever pulls from ECR regardless of where the image is built or
# pushed — a container image was never on the table once that constraint was
# fixed. backend/scripts/build-lambda-zip.sh resolves pyjwt[crypto]'s
# compiled cryptography dependency against Lambda's own manylinux/Python
# 3.12 target so the zip runs correctly regardless of what platform built it.
resource "aws_lambda_function" "api" {
  provider = aws.this

  function_name = "${local.name_prefix}-run-api"
  role          = aws_iam_role.lambda_execution.arn

  runtime = "python3.12"
  handler = "codeignite.api.lambda_handler.handler"

  filename         = var.lambda_package_path
  source_code_hash = filebase64sha256(var.lambda_package_path)

  memory_size = var.lambda_memory_mb
  timeout     = var.lambda_timeout_seconds

  # No VPC configuration. The API only talks to S3, SQS, and Cognito's
  # public JWKS endpoint — all reachable over the public internet — so
  # there is nothing a VPC would gain here except ENIs to provision and a
  # NAT gateway to pay for. Deliberately absent, not an oversight.

  environment {
    variables = {
      # AWS_REGION is a Lambda-reserved environment variable name and is set
      # automatically by the platform — see variables.tf's aws_region_for_app
      # comment for why this is CODEIGNITE_AWS_REGION instead.
      CODEIGNITE_AWS_REGION           = var.aws_region_for_app
      CODEIGNITE_JOBS_BUCKET          = var.jobs_bucket_name
      CODEIGNITE_RUNS_QUEUE_URL       = var.runs_queue_url
      CODEIGNITE_COGNITO_USER_POOL_ID = var.cognito_user_pool_id
      CODEIGNITE_COGNITO_CLIENT_ID    = var.cognito_client_id
    }
  }

  tags = {
    Name        = "${local.name_prefix}-run-api"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

resource "aws_cloudwatch_log_group" "api" {
  provider = aws.this

  name              = "/aws/lambda/${local.name_prefix}-run-api"
  retention_in_days = 30

  tags = {
    Name        = "${local.name_prefix}-run-api-logs"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

# AWS_IAM, not NONE: only a caller who can SigV4-sign the request may invoke
# this. CloudFront does so via the Lambda-type OAC above (oac.tf) — a direct
# request to this Function URL's own domain gets an IAM auth rejection
# before reaching api/app.py.
resource "aws_lambda_function_url" "api" {
  provider = aws.this

  function_name      = aws_lambda_function.api.function_name
  authorization_type = "AWS_IAM"
}

# Grants CloudFront's service principal permission to invoke the Function
# URL — OAC only makes CloudFront *sign* the request; something still has to
# authorize the signing identity, the same "confused deputy" concern
# static-site's S3 bucket policy (s3-policy.tf) already documents for its
# own OAC.
#
# Scoped to source_account, not source_arn (the exact CloudFront
# distribution ARN): that ARN is assigned by AWS when the distribution is
# created, in the static-site module, which itself needs this module's
# Function URL domain and OAC ID as inputs (see infra/envs/dev/main.tf).
# Depending on the distribution ARN here would make this module depend on
# static-site depending on this module — a cycle Terraform cannot plan.
# source_account restricts invocation to any CloudFront distribution owned
# by this AWS account rather than this one specifically; acceptable because
# this account has exactly one CloudFront distribution (this project's).
resource "aws_lambda_permission" "cloudfront" {
  provider = aws.this

  statement_id           = "AllowCloudFrontInvokeFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.api.function_name
  principal              = "cloudfront.amazonaws.com"
  source_account         = local.account_id
  function_url_auth_type = "AWS_IAM"
}
