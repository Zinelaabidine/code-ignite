# Dead-letter queue. A job that crashes the worker (rather than completing
# with a status of its own — see the worker's own error handling, stage 2 of
# docs/code-playground-implementation-plan.md) lands here after
# max_receive_count deliveries instead of being redelivered forever.
resource "aws_sqs_queue" "runs_dlq" {
  provider = aws.this

  name = "${local.name_prefix}-runs-dlq"

  message_retention_seconds = var.dlq_message_retention_seconds
  sqs_managed_sse_enabled   = true

  depends_on = [time_sleep.run_pipeline_iam_propagation]

  tags = {
    Name        = "${local.name_prefix}-runs-dlq"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

# Explicit allow-list of which queue may redrive into this DLQ, rather than
# leaving it implicit in the source queue's redrive_policy alone — belt and
# braces, and it is what AWS's own console surfaces as "Dead-letter queue
# recipient of" on the DLQ itself.
resource "aws_sqs_queue_redrive_allow_policy" "runs_dlq" {
  provider = aws.this

  queue_url = aws_sqs_queue.runs_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.runs.arn]
  })
}
