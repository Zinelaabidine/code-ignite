variable "aws_region" {
  description = "AWS region for all bootstrap resources."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project slug. Prefixes every IAM role name created here and must match project_name in infra/envs/*/terraform.tfvars."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens, 3-32 characters, and must not start or end with a hyphen."
  }
}

variable "create_oidc_provider" {
  description = <<-EOT
    Create the GitHub Actions OIDC provider
    (token.actions.githubusercontent.com).

    AWS allows only one provider per URL per account, not per project. If this
    account already has one — from a previous apply of this same config, or
    from an unrelated project — set this to false. The existing provider is
    then looked up by URL and reused instead of recreated. Sharing it is safe:
    the provider grants nothing by itself, and each deploy role's own trust
    policy is what scopes access to a specific repository.
  EOT
  type        = bool
  default     = true
}

variable "github_owner" {
  description = "GitHub organisation or user that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name, without the owner prefix."
  type        = string
}

variable "github_owner_id" {
  description = <<-EOT
    Numeric GitHub account ID for the owner (immutable OIDC sub claims).
    User: gh api user --jq .id
    Org:  gh api orgs/<owner> --jq .id
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must be a numeric string."
  }
}

variable "github_repo_id" {
  description = <<-EOT
    Numeric GitHub repository ID for immutable OIDC sub claims.
    gh api repos/<owner>/<repo> --jq .id
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repo_id))
    error_message = "github_repo_id must be a numeric string."
  }
}

variable "hosted_zone_name" {
  description = "Unused in bootstrap; declared so infra/common.tfvars can load via common.auto.tfvars without undeclared-variable errors."
  type        = string
  default     = ""
}

variable "certificate_domain_name" {
  description = "Unused in bootstrap; declared so infra/common.tfvars can load via common.auto.tfvars without undeclared-variable errors."
  type        = string
  default     = ""
}

variable "state_bucket_force_destroy" {
  description = "When true, Terraform may empty and delete the remote state bucket on destroy. Use only for full decommission; the bucket holds state for every environment root."
  type        = bool
  default     = false
}

variable "state_noncurrent_version_retention_days" {
  description = "How long superseded Terraform state versions are retained before expiry. Long enough to recover from a bad apply, short enough that the bucket does not grow without bound."
  type        = number
  default     = 90

  validation {
    condition     = var.state_noncurrent_version_retention_days >= 30
    error_message = "Keep at least 30 days of state history — shorter windows have burned people mid-incident."
  }
}

variable "local_dev_iam_users" {
  description = <<-EOT
    IAM user or role ARNs permitted to assume the local-developer role, which
    carries the full deploy blast radius and therefore requires MFA. These
    principals are intentionally absent from the GitHub deploy-role trust policy.

    Leave empty to skip creating the role entirely (an IAM trust policy with no
    principals is invalid, so an empty list cannot create a usable role).

    REVIEW THIS LIST before every bootstrap apply.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for arn in var.local_dev_iam_users :
      can(regex("^arn:aws:iam::[0-9]{12}:(user|role)/.+$", arn))
    ])
    error_message = "Each entry must be a fully qualified IAM user or role ARN (arn:aws:iam::<account-id>:user/<name>). Wildcards and account-root ARNs are not permitted."
  }
}
