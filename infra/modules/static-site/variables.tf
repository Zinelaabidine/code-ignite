# ─── Identity and naming ──────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region for all regional resources in this module. Must match the region configured on the aws.this provider — it is used to build regional ARNs in the deploy IAM policies."
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
  description = "Deployment environment name. Drives the resource name prefix and the GitHub Actions environment binding."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

# ─── DNS and TLS ──────────────────────────────────────────────────────────────

variable "domain_name" {
  description = "Fully qualified domain the static site is served from (e.g. \"myapp-dev.example.com\")."
  type        = string
}

variable "hosted_zone_name" {
  description = "Route 53 public hosted zone that contains domain_name (e.g. \"example.com\")."
  type        = string
}

variable "certificate_domain_name" {
  description = "Domain of the pre-existing ISSUED ACM certificate in us-east-1 that CloudFront presents (e.g. \"*.example.com\")."
  type        = string
}

# ─── GitHub / CI ──────────────────────────────────────────────────────────────

variable "github_owner" {
  description = "GitHub organisation or user that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name, without the owner prefix."
  type        = string
}

variable "terraform_state_bucket" {
  description = "Name of the S3 bucket holding Terraform remote state. Must match {project_name}-terraform-state-{account_id} used at terraform init."
  type        = string
}

variable "attach_deploy_policies_to_local_dev_role" {
  description = "Attach the deploy managed policies to the shared local-dev IAM role, and look that role up. Enable in exactly one environment (conventionally dev) — the role is account-global and shared across all environments. Requires local_dev_iam_users to be non-empty in infra/bootstrap."
  type        = bool
  default     = false
}

# ─── Cognito ──────────────────────────────────────────────────────────────────

variable "password_minimum_length" {
  description = "Minimum Cognito password length. NIST SP 800-63B and AWS both recommend 12 or more for human-chosen passwords."
  type        = number
  default     = 12

  validation {
    condition     = var.password_minimum_length >= 12 && var.password_minimum_length <= 99
    error_message = "password_minimum_length must be between 12 and 99."
  }
}

variable "mfa_configuration" {
  description = "Cognito MFA enforcement: OFF, ON (required for every user), or OPTIONAL (user opt-in). ON/OPTIONAL enable TOTP software tokens; SMS is deliberately not configured because it is the weakest second factor and costs per message."
  type        = string
  default     = "OFF"

  validation {
    condition     = contains(["OFF", "ON", "OPTIONAL"], var.mfa_configuration)
    error_message = "mfa_configuration must be one of: OFF, ON, OPTIONAL."
  }
}

variable "advanced_security_mode" {
  description = "Cognito threat protection: OFF, AUDIT (log risk events), or ENFORCED (block high-risk sign-ins, compromised-credential detection). AUDIT and ENFORCED are billed per monthly active user, so this defaults to OFF — turn it on for prod deliberately."
  type        = string
  default     = "OFF"

  validation {
    condition     = contains(["OFF", "AUDIT", "ENFORCED"], var.advanced_security_mode)
    error_message = "advanced_security_mode must be one of: OFF, AUDIT, ENFORCED."
  }
}

variable "access_token_validity_minutes" {
  description = "Lifetime of Cognito access tokens, in minutes."
  type        = number
  default     = 60

  validation {
    condition     = var.access_token_validity_minutes >= 5 && var.access_token_validity_minutes <= 1440
    error_message = "access_token_validity_minutes must be between 5 and 1440."
  }
}

variable "id_token_validity_minutes" {
  description = "Lifetime of Cognito ID tokens, in minutes."
  type        = number
  default     = 60

  validation {
    condition     = var.id_token_validity_minutes >= 5 && var.id_token_validity_minutes <= 1440
    error_message = "id_token_validity_minutes must be between 5 and 1440."
  }
}

variable "refresh_token_validity_days" {
  description = "Lifetime of Cognito refresh tokens, in days. The AWS default is 30; a refresh token sitting in browser storage is a bearer credential for its whole lifetime, so this template shortens it."
  type        = number
  default     = 7

  validation {
    condition     = var.refresh_token_validity_days >= 1 && var.refresh_token_validity_days <= 3650
    error_message = "refresh_token_validity_days must be between 1 and 3650."
  }
}

variable "cognito_deletion_protection" {
  description = "Cognito User Pool deletion protection. Deleting a pool destroys every registered account irreversibly."
  type        = string
  default     = "ACTIVE"

  validation {
    condition     = contains(["ACTIVE", "INACTIVE"], var.cognito_deletion_protection)
    error_message = "cognito_deletion_protection must be ACTIVE or INACTIVE."
  }
}

# ─── CloudFront ───────────────────────────────────────────────────────────────

variable "cloudfront_price_class" {
  description = "CloudFront price class. PriceClass_100 is North America and Europe only — the cheapest."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.cloudfront_price_class)
    error_message = "cloudfront_price_class must be one of: PriceClass_100, PriceClass_200, PriceClass_All."
  }
}

variable "enable_access_logging" {
  description = "Create a logs bucket and send CloudFront access logs and S3 server access logs to it. Without this there is no record of who requested what."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "How long access logs are kept before expiry."
  type        = number
  default     = 90

  validation {
    condition     = var.log_retention_days >= 1
    error_message = "log_retention_days must be at least 1."
  }
}

variable "site_noncurrent_version_retention_days" {
  description = "How long superseded objects in the site bucket are kept. Versioning is enabled, and every deploy's `s3 sync --delete` creates noncurrent versions, so without expiry the bucket grows without bound."
  type        = number
  default     = 30

  validation {
    condition     = var.site_noncurrent_version_retention_days >= 1
    error_message = "site_noncurrent_version_retention_days must be at least 1."
  }
}

# ─── WAF ──────────────────────────────────────────────────────────────────────

variable "enable_waf" {
  description = "Attach an AWS WAF web ACL to the CloudFront distribution (AWS managed common rule set plus a rate limit). Billed per web ACL, per rule, and per million requests, so it defaults to off."
  type        = bool
  default     = false
}

variable "waf_rate_limit_per_5min" {
  description = "Requests per 5-minute window from a single IP before WAF blocks it. Only used when enable_waf is true."
  type        = number
  default     = 2000

  validation {
    condition     = var.waf_rate_limit_per_5min >= 100
    error_message = "waf_rate_limit_per_5min must be at least 100 (the AWS WAF minimum)."
  }
}
