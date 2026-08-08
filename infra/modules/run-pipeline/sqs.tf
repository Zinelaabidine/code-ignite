# The runs queue. Carries job IDs only — code and results live in S3
# (s3-jobs.tf); see docs/code-playground-plan.md's "flow" section for the
# full POST /runs → SQS → worker → GET /runs/{job_id} sequence.
resource "aws_sqs_queue" "runs" {
  provider = aws.this

  name = "${local.name_prefix}-runs"

  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds

  # Long polling: a receive call waits up to 20s for a message rather than
  # returning empty immediately. Short polling burns through the 1M-request
  # free tier for nothing when the worker is idle.
  receive_wait_time_seconds = 20

  sqs_managed_sse_enabled = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.runs_dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  # sqs:CreateQueue is granted by the deploy-time policy created in this same
  # module (iam-deploy.tf) — wait for it to propagate before the first apply
  # tries to use it.
  depends_on = [time_sleep.run_pipeline_iam_propagation]

  tags = {
    Name        = "${local.name_prefix}-runs"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}
