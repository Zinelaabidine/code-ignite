data "aws_caller_identity" "current" {}

locals {
  terraform_state_bucket = "${var.project_name}-terraform-state-${data.aws_caller_identity.current.account_id}"

  # Default: {project_name}-dev.{hosted_zone_name} — override in terraform.tfvars
  # when this environment needs a non-standard hostname.
  domain_name = coalesce(
    var.domain_name_override,
    "${var.project_name}-dev.${var.hosted_zone_name}"
  )
}
