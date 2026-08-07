# Copy to terraform.tfvars (gitignored) and fill in before the first bootstrap
# apply.
#
# aws_region, project_name, github_owner, github_repo, and
# terraform_state_bucket now live in one place: infra/common.tfvars (loaded
# automatically here via the common.auto.tfvars symlink). Only bootstrap-only
# values remain in this file.
#
# `terraform_state_bucket` (in common.tfvars) MUST match the `bucket` value in
# backend.hcl (infra/common-backend.hcl, also symlinked in). The S3 backend
# block cannot read variables, so the two are checked against each other by
# scripts/pre-commit-check.sh instead.
#
# The AWS account ID is no longer a variable — it is read from the caller's
# identity, so this file drops into any account unchanged.

# AWS allows only one GitHub Actions OIDC provider per account. Set this to
# false if the account already has one — either from an earlier attempt of
# this apply, or from a different project.
create_oidc_provider = false

# How long superseded Terraform state versions are kept (minimum 30).
state_noncurrent_version_retention_days = 90

# IAM principals allowed to assume <project_name>-local-dev-role. That role
# carries the full deploy blast radius, so assuming it requires MFA no more than
# an hour old. Leave the list empty to skip creating the role entirely.
#
# REVIEW THIS LIST BEFORE EVERY APPLY.
local_dev_iam_users = [
  # "arn:aws:iam::000000000000:user/terraadmin",
]
