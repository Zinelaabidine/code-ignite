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
#   cd ../..                                              # repo root
#   cp infra/common.tfvars.example infra/common.tfvars    # fill in, once for
#   cp infra/common-backend.hcl.example infra/common-backend.hcl  # every root
#   cd infra/bootstrap
#   cp terraform.tfvars.example terraform.tfvars   # fill in bootstrap-only values
#   ln -sf ../common-backend.hcl backend.hcl       # not `cp` — see common-backend.hcl.example
#   ln -sf ../common.tfvars common.auto.tfvars     # not `cp` — see common.tfvars.example
#   terraform init -backend=false
#   terraform apply                                # creates the state bucket
#   terraform init -backend-config=backend.hcl -migrate-state
#
# aws_region, project_name, github_owner, github_repo, and
# terraform_state_bucket are no longer duplicated per root — they live once in
# infra/common.tfvars and infra/common-backend.hcl, and every root (this one
# plus all three infra/envs/*) picks them up through the symlinks above.
# (hosted_zone_name / certificate_domain_name live in infra/common-domain.tfvars
# instead, symlinked into infra/envs/* only — this root doesn't touch Route 53
# or ACM.) Only bootstrap-only values (create_oidc_provider,
# state_noncurrent_version_retention_days, local_dev_iam_users) stay in this
# root's own terraform.tfvars.
# ──────────────────────────────────────────────────────────────────────────────

locals {
  github_repo_full = "${var.github_owner}/${var.github_repo}"

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
