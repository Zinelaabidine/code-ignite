# Values for these live in terraform.tfvars (gitignored) or, in CI, in the
# TF_VAR_* environment variables set from GitHub Actions variables. Nothing
# identifying — domain, GitHub owner, bucket names — is committed to the repo.
#
# See terraform.tfvars.example.

variable "aws_region" {
  description = "AWS region for regional resources in this environment."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project slug used to build every resource name prefix. Must match project_name in infra/bootstrap."
  type        = string
}

variable "domain_name_override" {
  description = "Optional FQDN override. When null, defaults to \"{project_name}-staging.{hosted_zone_name}\"."
  type        = string
  default     = null
}

variable "hosted_zone_name" {
  description = "Route 53 public hosted zone that contains domain_name (e.g. \"example.com\")."
  type        = string
}

variable "certificate_domain_name" {
  description = "Domain of the pre-existing ISSUED ACM certificate in us-east-1 that CloudFront presents (e.g. \"*.example.com\")."
  type        = string
}

variable "github_owner" {
  description = "GitHub organisation or user that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name, without the owner prefix."
  type        = string
}

# ─── Environment-tunable hardening ────────────────────────────────────────────

variable "mfa_configuration" {
  description = "Cognito MFA enforcement: OFF, ON, or OPTIONAL."
  type        = string
  default     = "OFF"
}

variable "advanced_security_mode" {
  description = "Cognito threat protection: OFF, AUDIT, or ENFORCED. Billed per monthly active user."
  type        = string
  default     = "OFF"
}

variable "enable_waf" {
  description = "Attach a WAF web ACL to the CloudFront distribution. Billed per web ACL, rule, and million requests."
  type        = bool
  default     = false
}

