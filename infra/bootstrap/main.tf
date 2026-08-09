# ──────────────────────────────────────────────────────────────────────────────
# Bootstrap — Terraform remote state + GitHub Actions OIDC foundation
#
# WHY THIS IS SEPARATE FROM THE APP INFRA:
#   The resources here (Terraform state bucket, GitHub OIDC provider, and the
#   deploy-role trust policies) form the trust chain that lets GitHub Actions
#   authenticate to AWS at all. If the deploy workflow managed its own trust
#   chain, a misconfiguration could lock GitHub Actions out entirely and
#   recovery would require manual console access.
#
#   Keeping bootstrap in a separate Terraform root and a separate workflow
#   (bootstrap.yml, manual-trigger only) ensures:
#     1. The trust chain changes deliberately, after human review.
#     2. A normal deployment cannot accidentally break OIDC authentication.
#     3. Bootstrap runs under its own role, so it does not depend on the very
#        roles it manages.
#
# FILE LAYOUT (one concern per file, per CLAUDE.md §6):
#   s3-state.tf        Terraform remote state bucket and its companions
#   iam-oidc.tf        GitHub Actions OIDC provider
#   iam-deploy-roles.tf  Per-environment deploy roles and their trust policies
#   iam-local-dev.tf   Shared local-developer role (MFA-gated)
#   iam-bootstrap-ci.tf  The role bootstrap.yml itself assumes
#
# FILES TO REVIEW MANUALLY BEFORE EVERY APPLY:
#   - iam-deploy-roles.tf  (OIDC trust conditions)
#   - iam-local-dev.tf     (who may assume the shared dev role)
#   - variables.tf         (local_dev_iam_users list)
#
# FIRST RUN (one-time, per AWS account):
#   cp infra/common.tfvars.example infra/common.tfvars   # project_name once
#   cd infra/bootstrap
#   cp terraform.tfvars.example terraform.tfvars
#   ln -sf ../common.tfvars common.auto.tfvars
#   terraform init -backend=false
#   terraform apply
#   terraform init -backend-config="bucket=$(../../scripts/state-bucket-name.sh)" -migrate-state
#
# Shared values live in infra/common.tfvars (symlinked as common.auto.tfvars).
# State bucket and site FQDNs are derived from project_name — not set elsewhere.
# ──────────────────────────────────────────────────────────────────────────────

locals {
  terraform_state_bucket = "${var.project_name}-terraform-state-${data.aws_caller_identity.current.account_id}"

  github_repo_full = "${var.github_owner}/${var.github_repo}"

  # GitHub Actions OIDC `sub` uses immutable owner/repo IDs (opt-in, or
  # automatic for repos created/renamed after 2026-07-15):
  #   repo:OWNER@OWNER_ID/REPO@REPO_ID:environment:ENV
  # Trust policies must match that form — name-only subjects no longer match.
  github_repo_immutable = "${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}"

  # Must match the `environment:` values used in .github/workflows/deploy.yml.
  # dev → push to dev branch, staging → push to staging, prod → push to main.
  environments = ["dev", "staging", "prod"]

  # The shared local-developer role only exists if someone is allowed to
  # assume it. An IAM trust policy with an empty principal list is rejected by
  # the API, so an empty list means "do not create the role at all".
  create_local_dev_role = length(var.local_dev_iam_users) > 0

  # Resolves to whichever of the resource or the data source actually exists,
  # so every other file can reference one stable ARN regardless of
  # create_oidc_provider. See iam-oidc.tf for why this toggle exists.
  github_oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github_project_template[0].arn : data.aws_iam_openid_connect_provider.existing[0].arn
}

data "aws_caller_identity" "current" {}
