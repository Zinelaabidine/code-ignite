locals {
  name_prefix = "${var.project_name}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id

  # Constructed by name rather than read from aws_sqs_queue.runs.arn /
  # aws_sqs_queue.runs_dlq.arn / aws_s3_bucket.jobs.arn — see iam-deploy.tf's
  # SQSQueueManage and S3JobsBucketManage comments for why the deploy policy
  # document must not depend on the resources it authorizes creating.
  runs_queue_arn  = "arn:aws:sqs:${var.aws_region}:${local.account_id}:${local.name_prefix}-runs"
  runs_dlq_arn    = "arn:aws:sqs:${var.aws_region}:${local.account_id}:${local.name_prefix}-runs-dlq"
  jobs_bucket_arn = "arn:aws:s3:::${local.name_prefix}-jobs"
}
