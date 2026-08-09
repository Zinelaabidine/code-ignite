# ─────────────────────────────────────────────────────────────────────────────
# The Lambda function's own execution role — what api/app.py is allowed to do
# at request time. Two grants, both scoped as tight as the resource allows:
# CloudWatch Logs (so the function can start at all — Lambda refuses to
# invoke a function whose role cannot create its own log stream) and the
# existing run-api runtime policy from infra/modules/run-pipeline, reused
# rather than duplicated — see run-pipeline/iam-runtime.tf's header comment
# on why the API and worker have genuinely separate policies. This role gets
# only the API's half; the worker's half (run-worker) is never attached here
# because the worker never runs in AWS — see
# docs/code-playground-hosted-api-plan.md §0.
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_execution" {
  provider = aws.this

  name               = "${local.name_prefix}-run-api-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  # iam:CreateRole is granted by the deploy-time policy created in this same
  # module (iam-deploy.tf) — wait for it to propagate before the first apply
  # tries to use it.
  depends_on = [time_sleep.run_api_iam_propagation]

  tags = {
    Name        = "${local.name_prefix}-run-api-lambda-role"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

# Written out explicitly rather than attaching the AWS managed
# AWSLambdaBasicExecutionRole policy, which grants CreateLogGroup /
# CreateLogStream / PutLogEvents on every log group in the account
# ("arn:aws:logs:*:*:*"). Scoped to this function's own log group only.
data "aws_iam_policy_document" "lambda_logs" {
  statement {
    sid    = "LambdaLogging"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-run-api:*",
    ]
  }
}

resource "aws_iam_policy" "lambda_logs" {
  provider = aws.this

  name        = "${local.name_prefix}-run-api-lambda-logs-policy"
  description = "CloudWatch Logs permissions for the run-api Lambda's own log group, scoped in place of the AWS managed AWSLambdaBasicExecutionRole policy."
  policy      = data.aws_iam_policy_document.lambda_logs.json

  # iam:CreatePolicy (scoped to the run-api-lambda-* name prefix) is granted
  # by the deploy-time policy created in this same module (iam-deploy.tf).
  depends_on = [time_sleep.run_api_iam_propagation]

  tags = {
    Name        = "${local.name_prefix}-run-api-lambda-logs-policy"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  provider = aws.this

  role       = aws_iam_role.lambda_execution.name
  policy_arn = aws_iam_policy.lambda_logs.arn
}

# The existing run-api runtime policy (S3 PutObject/GetObject on jobs/*,
# SQS SendMessage/GetQueueUrl) — see infra/modules/run-pipeline/iam-runtime.tf.
# Not created here, only attached: the permissions a caller needs to enqueue
# a job are identical whether that caller is a local process assuming the
# local-dev role or this Lambda.
resource "aws_iam_role_policy_attachment" "run_api_runtime" {
  provider = aws.this

  role       = aws_iam_role.lambda_execution.name
  policy_arn = var.run_api_policy_arn
}
