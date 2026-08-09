# ─── Per-Environment Deploy Roles ─────────────────────────────────────────────
#
# Trust is narrowed to three facts simultaneously:
#   1. This specific GitHub repository
#   2. The matching GitHub Actions environment (dev / staging / prod)
#   3. The GitHub OIDC audience (sts.amazonaws.com)
#
# The environment claim is the load-bearing one: it only appears in the token
# when the job declares `environment:`, and GitHub evaluates that environment's
# protection rules (required reviewers, branch restrictions) before the token
# is minted. Branch enforcement therefore lives in the environment settings,
# not here.
#
# Local IAM users are deliberately NOT in this trust policy — they use the
# local-dev role in iam-local-dev.tf, keeping CI and workstation credentials
# separate.
#
data "aws_iam_policy_document" "github_deploy_trust" {
  for_each = toset(local.environments)

  statement {
    sid    = "AllowGitHubActionsOIDC"
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Exact immutable repo + environment combination (OWNER@id/REPO@id).
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.github_repo_immutable}:environment:${each.key}"]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  for_each = toset(local.environments)

  name        = "${var.project_name}-${each.key}-github-deploy-role"
  description = "Assumed by GitHub Actions (OIDC) for ${each.key} deployments. Trust policy managed in infra/bootstrap."

  assume_role_policy = data.aws_iam_policy_document.github_deploy_trust[each.key].json

  # A deploy takes minutes; the default 1 hour is longer than needed and a
  # leaked token is useful for exactly as long as this window.
  max_session_duration = 3600

  # Created without permissions on purpose — the app module in infra/envs/<env>
  # creates and attaches the deploy managed policies.
  tags = {
    Name        = "${var.project_name}-${each.key}-github-deploy-role"
    Environment = each.key
  }
}
