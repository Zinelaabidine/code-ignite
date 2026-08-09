# ─── Identity and naming ──────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region for every resource in this module. Must match the region configured on the aws.this provider — used to build regional ARNs (Lambda, ECR) in the deploy IAM policy before those resources exist, and to derive the Function URL's own domain."
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

variable "attach_deploy_policies_to_local_dev_role" {
  description = "Attach this module's deploy-time managed policy (create/manage the ECR repository, Lambda function, its execution role, and the Lambda-type OAC) to the shared local-dev IAM role, and look that role up. Same account-global-role caveat as every other module's copy of this flag: enable in exactly one environment, and only if you actually run `terraform apply` for this module locally. Requires local_dev_iam_users to be non-empty in infra/bootstrap."
  type        = bool
  default     = false
}

# ─── Runtime configuration — mirrors backend/.env.example's five required
# CODEIGNITE_* values. Lambda's own AWS_REGION env var is reserved by the
# platform and set automatically, so it is not passed here — only the
# CODEIGNITE_-prefixed contract api/config.py actually reads. ────────────────

variable "aws_region_for_app" {
  description = "Value written into the function's CODEIGNITE_AWS_REGION environment variable. A separate variable from aws_region only in name — same value — because AWS_REGION itself is a Lambda-reserved environment variable name and cannot be set directly."
  type        = string
}

variable "jobs_bucket_name" {
  description = "S3 bucket holding job input/result objects — CODEIGNITE_JOBS_BUCKET (from infra/modules/run-pipeline's jobs_bucket_name output)."
  type        = string
}

variable "runs_queue_url" {
  description = "SQS queue URL the API enqueues job IDs to — CODEIGNITE_RUNS_QUEUE_URL (from infra/modules/run-pipeline's runs_queue_url output)."
  type        = string
}

variable "cognito_user_pool_id" {
  description = "Cognito User Pool ID the API verifies access tokens against — CODEIGNITE_COGNITO_USER_POOL_ID (from infra/modules/static-site's cognito_user_pool_id output)."
  type        = string
}

variable "cognito_client_id" {
  description = "Cognito App Client ID the API checks the token's client_id claim against — CODEIGNITE_COGNITO_CLIENT_ID (from infra/modules/static-site's cognito_client_id output)."
  type        = string
}

variable "run_api_policy_arn" {
  description = "ARN of the run-api runtime managed policy (from infra/modules/run-pipeline's run_api_policy_arn output) — attached to this module's Lambda execution role. Written once in run-pipeline/iam-runtime.tf and reused here rather than duplicated, since the permissions a caller needs to enqueue a job are identical whether that caller is a local process or this Lambda."
  type        = string
}

# ─── Deployment ────────────────────────────────────────────────────────────────

variable "image_tag" {
  description = "Tag of the backend/Dockerfile.lambda image in this module's ECR repository that the Lambda function should run — set by deploy.yml to the commit SHA it just built and pushed. Terraform does not build or push images itself; the image referenced by this tag must already exist in the repository before apply runs, or CreateFunction/UpdateFunctionCode fails."
  type        = string
  default     = "unset"

  validation {
    condition     = length(var.image_tag) > 0
    error_message = "image_tag must not be empty."
  }
}

variable "lambda_memory_mb" {
  description = "Memory allocated to the API Lambda, in MB. This function does no CPU-heavy work (it enqueues jobs and reads/writes small S3 objects) — 512 is headroom for cryptography's RS256 verification in api/auth.py, not a tuned figure."
  type        = number
  default     = 512

  validation {
    condition     = var.lambda_memory_mb >= 128 && var.lambda_memory_mb <= 10240
    error_message = "lambda_memory_mb must be between 128 and 10240 (the Lambda maximum)."
  }
}

variable "lambda_timeout_seconds" {
  description = "Lambda invocation timeout. Generous relative to the API's actual work (an S3 put/get and an SQS send, typically well under a second) to absorb cold starts from the Lambda Web Adapter and cryptography's import time, not because the API is expected to run long."
  type        = number
  default     = 15

  validation {
    condition     = var.lambda_timeout_seconds >= 1 && var.lambda_timeout_seconds <= 900
    error_message = "lambda_timeout_seconds must be between 1 and 900 (the Lambda maximum)."
  }
}
