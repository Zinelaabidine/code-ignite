# ─── GitHub Actions OIDC Provider ─────────────────────────────────────────────
#
# One provider per AWS account. Every deploy role and the bootstrap CI role
# federate through it, so no static AWS keys exist anywhere in CI.
#
# AWS allows only ONE OIDC provider per URL per account — not per project. If
# this account has ever bootstrapped GitHub Actions OIDC before (this repo or a
# different one), token.actions.githubusercontent.com already exists
# account-wide and CreateOpenIDConnectProvider fails with EntityAlreadyExists.
#
# Set create_oidc_provider = false in terraform.tfvars to reuse the existing
# provider instead of creating a duplicate — it's looked up by URL below.
# Sharing it is safe: the provider itself grants nothing. Each deploy role's
# own trust policy (iam-deploy-roles.tf) is what scopes access to this repo.

resource "aws_iam_openid_connect_provider" "github_project_template" {
  count = var.create_oidc_provider ? 1 : 0

  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # AWS stopped validating thumbprints for this well-known IdP in 2023 and now
  # trusts the library of root CAs directly. The API still accepts the field
  # but it is no longer meaningful, so it is omitted rather than pinned to a
  # value that silently rots.

  tags = {
    Name = "github-actions-oidc"
  }
}

# Looked up instead of created when create_oidc_provider = false.
data "aws_iam_openid_connect_provider" "existing" {
  count = var.create_oidc_provider ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}
