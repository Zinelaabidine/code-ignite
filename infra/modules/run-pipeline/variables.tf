# ─── Identity and naming ──────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region the queue and bucket live in. Must match the region configured on the aws.this provider — used to construct the runs queue's ARN by name in the deploy-time IAM policy (iam-deploy.tf), before the queue exists, so the policy document doesn't depend on the queue resource itself and create a cycle."
  type        = string
}

variable "project_name" {
  description = "Project slug used to build resource name prefixes (e.g. \"myapp\")."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens, 3-32 characters, and must not start or end with a hyphen."
  }
}

variable "environment" {
  description = "Deployment environment name. Drives the resource name prefix."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

# ─── Local-dev role attachment ────────────────────────────────────────────────
#
# Two separate flags because they grant two different kinds of access to the
# same account-global role: one is deploy-time (create/manage the queue,
# bucket, and IAM policies), the other is runtime (the actual SendMessage /
# ReceiveMessage / GetObject calls the API and worker make while running
# locally, per docs/code-playground-plan.md's local-first phase 1). A
# developer who only runs `terraform apply` but never runs the API locally
# should not carry the runtime grant, and vice versa.

variable "attach_deploy_policies_to_local_dev_role" {
  description = "Attach this module's deploy-time managed policy (create/manage the queue, DLQ, jobs bucket, and runtime IAM policies) to the shared local-dev IAM role, and look that role up. Enable in exactly one environment (conventionally dev) — the role is account-global and shared across all environments. Requires local_dev_iam_users to be non-empty in infra/bootstrap."
  type        = bool
  default     = false
}

variable "attach_runtime_policies_to_local_dev_role" {
  description = "Attach the run-api and run-worker runtime managed policies to the shared local-dev IAM role. Enable wherever the API and worker actually run as local processes under that role — conventionally dev, and only dev, until they run somewhere else. Requires local_dev_iam_users to be non-empty in infra/bootstrap."
  type        = bool
  default     = false
}

# ─── SQS ───────────────────────────────────────────────────────────────────────

variable "visibility_timeout_seconds" {
  description = "SQS visibility timeout for the runs queue. Must stay comfortably above the worker's maximum execution time (CODEIGNITE_MAX_EXECUTION_SECONDS in the backend) or a job still running can be redelivered to a second worker."
  type        = number
  default     = 60

  validation {
    condition     = var.visibility_timeout_seconds >= 0 && var.visibility_timeout_seconds <= 43200
    error_message = "visibility_timeout_seconds must be between 0 and 43200 (the SQS maximum, 12 hours)."
  }
}

variable "max_receive_count" {
  description = "How many times a message may be received before SQS moves it to the dead-letter queue. Low on purpose: a job that crashes the worker twice is not going to succeed on a third try, and a low count keeps a poison message from being redelivered forever."
  type        = number
  default     = 2

  validation {
    condition     = var.max_receive_count >= 1 && var.max_receive_count <= 1000
    error_message = "max_receive_count must be between 1 and 1000."
  }
}

variable "message_retention_seconds" {
  description = "How long an unclaimed job stays on the runs queue before SQS discards it. 4 hours by default — a job nobody collected by then is not worth keeping."
  type        = number
  default     = 14400

  validation {
    condition     = var.message_retention_seconds >= 60 && var.message_retention_seconds <= 1209600
    error_message = "message_retention_seconds must be between 60 and 1209600 (the SQS maximum, 14 days)."
  }
}

variable "dlq_message_retention_seconds" {
  description = "How long a failed job stays on the dead-letter queue. Long by default (14 days, the SQS maximum) — the DLQ is the debugging record for jobs that crashed the worker."
  type        = number
  default     = 1209600

  validation {
    condition     = var.dlq_message_retention_seconds >= 60 && var.dlq_message_retention_seconds <= 1209600
    error_message = "dlq_message_retention_seconds must be between 60 and 1209600 (the SQS maximum, 14 days)."
  }
}

# ─── S3 ────────────────────────────────────────────────────────────────────────

variable "jobs_retention_days" {
  description = "How long objects under jobs/ (input.json, result.json) are kept before S3 expires them. Jobs are ephemeral by design — this is both hygiene and cost control, not a durable record."
  type        = number
  default     = 7

  validation {
    condition     = var.jobs_retention_days >= 1
    error_message = "jobs_retention_days must be at least 1."
  }
}
