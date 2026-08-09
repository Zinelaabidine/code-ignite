# ─────────────────────────────────────────────────────────────────────────────
# Runtime permissions — what the API and worker processes themselves are
# allowed to do at request time. Two policies, not one: the API and worker
# have genuinely different rights (see docs/code-playground-implementation-plan.md
# stage 2a's table), and writing them separately now is what makes the future
# ECS/EKS task roles correct later instead of a shared-and-therefore-overbroad
# one.
#
# Both attach only to the local-dev role, gated by
# attach_runtime_policies_to_local_dev_role — phase 1 is local-first
# (docs/code-playground-plan.md), so the same person's local-dev role is what
# the API and worker processes assume via an AWS profile. Neither policy
# attaches to the GitHub deploy role: CI deploys infrastructure, it never
# runs the application.
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "run_api_policy" {
  statement {
    sid    = "RunApiJobsReadWrite"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
    ]
    # The API writes input.json and reads result.json for GET /runs/{job_id}
    # — scoped to the jobs/ prefix, never the whole bucket.
    resources = ["${aws_s3_bucket.jobs.arn}/jobs/*"]
  }

  # Without ListBucket, GetObject on a key that does not exist yet returns
  # AccessDenied (not NoSuchKey) — S3 refuses to confirm absence. The API
  # polls result.json before the worker has written it, so that response
  # crashed GET /runs/{job_id} with a 500 instead of the intended 202
  # pending. Prefix-conditioned so this is not a bucket-wide listing grant.
  statement {
    sid    = "RunApiJobsListBucket"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
    ]
    resources = [aws_s3_bucket.jobs.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["jobs/*"]
    }
  }

  statement {
    sid    = "RunApiQueueSend"
    effect = "Allow"
    actions = [
      "sqs:SendMessage",
      "sqs:GetQueueUrl",
    ]
    resources = [aws_sqs_queue.runs.arn]
  }
}

resource "aws_iam_policy" "run_api_policy" {
  provider = aws.this

  name        = "${local.name_prefix}-run-api-policy"
  description = "Runtime permissions for the code playground API: write job input, read job result, enqueue the job ID."
  policy      = data.aws_iam_policy_document.run_api_policy.json

  depends_on = [time_sleep.run_pipeline_iam_propagation]

  tags = {
    Name        = "${local.name_prefix}-run-api-policy"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

data "aws_iam_policy_document" "run_worker_policy" {
  statement {
    sid    = "RunWorkerJobsReadWrite"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]
    # The worker reads input.json and writes result.json — same jobs/ prefix,
    # never the whole bucket.
    resources = ["${aws_s3_bucket.jobs.arn}/jobs/*"]
  }

  # Same S3 absence-vs-AccessDenied quirk as RunApiJobsListBucket — the
  # worker's get_input path returns None on a missing key, which only works
  # when ListBucket lets S3 answer with NoSuchKey.
  statement {
    sid    = "RunWorkerJobsListBucket"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
    ]
    resources = [aws_s3_bucket.jobs.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["jobs/*"]
    }
  }

  statement {
    sid    = "RunWorkerQueueConsume"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [aws_sqs_queue.runs.arn]
  }
}

resource "aws_iam_policy" "run_worker_policy" {
  provider = aws.this

  name        = "${local.name_prefix}-run-worker-policy"
  description = "Runtime permissions for the code playground worker: receive jobs, read job input, write job result, delete/extend the message."
  policy      = data.aws_iam_policy_document.run_worker_policy.json

  depends_on = [time_sleep.run_pipeline_iam_propagation]

  tags = {
    Name        = "${local.name_prefix}-run-worker-policy"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

resource "aws_iam_role_policy_attachment" "local_dev_run_api" {
  count    = var.attach_runtime_policies_to_local_dev_role ? 1 : 0
  provider = aws.this

  role       = data.aws_iam_role.local_dev_role[0].name
  policy_arn = aws_iam_policy.run_api_policy.arn

  depends_on = [time_sleep.run_pipeline_iam_propagation]
}

resource "aws_iam_role_policy_attachment" "local_dev_run_worker" {
  count    = var.attach_runtime_policies_to_local_dev_role ? 1 : 0
  provider = aws.this

  role       = data.aws_iam_role.local_dev_role[0].name
  policy_arn = aws_iam_policy.run_worker_policy.arn

  depends_on = [time_sleep.run_pipeline_iam_propagation]
}
