output "runs_queue_url" {
  description = "SQS queue URL the API sends job IDs to and the worker receives from — CODEIGNITE_RUNS_QUEUE_URL in the backend."
  value       = aws_sqs_queue.runs.id
}

output "runs_queue_arn" {
  description = "ARN of the runs SQS queue."
  value       = aws_sqs_queue.runs.arn
}

output "runs_dlq_url" {
  description = "SQS queue URL of the dead-letter queue."
  value       = aws_sqs_queue.runs_dlq.id
}

output "runs_dlq_arn" {
  description = "ARN of the dead-letter queue."
  value       = aws_sqs_queue.runs_dlq.arn
}

output "jobs_bucket_name" {
  description = "Name of the S3 bucket holding job input and result objects — CODEIGNITE_JOBS_BUCKET in the backend."
  value       = aws_s3_bucket.jobs.id
}

output "jobs_bucket_arn" {
  description = "ARN of the jobs S3 bucket."
  value       = aws_s3_bucket.jobs.arn
}

output "run_api_policy_arn" {
  description = "ARN of the run-api runtime managed policy."
  value       = aws_iam_policy.run_api_policy.arn
}

output "run_worker_policy_arn" {
  description = "ARN of the run-worker runtime managed policy."
  value       = aws_iam_policy.run_worker_policy.arn
}
