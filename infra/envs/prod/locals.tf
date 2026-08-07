data "aws_caller_identity" "current" {}

locals {
  terraform_state_bucket = "${var.project_name}-terraform-state-${data.aws_caller_identity.current.account_id}"

  domain_name = coalesce(
    var.domain_name_override,
    "${var.project_name}.${var.hosted_zone_name}"
  )
}
