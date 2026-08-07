# ─── Bootstrap CI Role (OIDC, no static keys) ─────────────────────────────────
#
# Assumed by bootstrap.yml itself. Trust is scoped to the exact workflow file on
# main via the job_workflow_ref claim, so no other workflow in this repo — and
# no fork — can assume it.
#
# PREREQUISITE (one-time): this role must exist before the first bootstrap.yml
# run, so it is created by the first LOCAL apply (see README "Bootstrap the
# account"). The OIDC provider it federates through is either created by that
# same apply or reused — see create_oidc_provider in variables.tf and the
# comment in iam-oidc.tf — so no manual import of the provider is needed.
#
# If this role itself already exists from an earlier attempt (state was lost or
# this account was bootstrapped before), import it instead of letting apply
# fail on EntityAlreadyExists:
#
#   terraform import aws_iam_role.bootstrap_ci <project_name>-bootstrap-ci-role

data "aws_iam_policy_document" "bootstrap_ci_trust" {
  statement {
    sid    = "AllowBootstrapWorkflowOIDC"
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

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.github_repo_full}:*"]
    }

    # The critical condition: only bootstrap.yml on main can assume this role.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values   = ["${local.github_repo_full}/.github/workflows/bootstrap.yml@refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "bootstrap_ci" {
  name        = "${var.project_name}-bootstrap-ci-role"
  description = "Assumed by bootstrap.yml via OIDC. Manages IAM/OIDC resources only. No static keys."

  assume_role_policy   = data.aws_iam_policy_document.bootstrap_ci_trust.json
  max_session_duration = 3600

  tags = {
    Name = "${var.project_name}-bootstrap-ci-role"
  }
}

data "aws_iam_policy_document" "bootstrap_ci_permissions" {
  statement {
    sid    = "OIDCProvider"
    effect = "Allow"
    actions = [
      "iam:CreateOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:AddClientIDToOpenIDConnectProvider",
      "iam:RemoveClientIDFromOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviderTags",
    ]
    resources = [local.github_oidc_provider_arn]
  }

  # ListOpenIDConnectProviders has no resource-level permission scope.
  statement {
    sid       = "OIDCProviderList"
    effect    = "Allow"
    actions   = ["iam:ListOpenIDConnectProviders"]
    resources = ["*"]
  }

  statement {
    sid    = "DeployRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:DeleteRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:ListRoleTags",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:GetRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*-github-deploy-role",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-local-dev-role",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-bootstrap-ci-role",
    ]
  }

  statement {
    sid    = "TerraformState"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "arn:aws:s3:::${local.terraform_state_bucket}",
      "arn:aws:s3:::${local.terraform_state_bucket}/*",
    ]
  }

  statement {
    sid    = "S3BucketBootstrap"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:GetBucketVersioning",
      "s3:PutBucketVersioning",
      "s3:GetEncryptionConfiguration",
      "s3:PutEncryptionConfiguration",
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketPublicAccessBlock",
      "s3:GetBucketOwnershipControls",
      "s3:PutBucketOwnershipControls",
      "s3:GetBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:GetLifecycleConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:GetBucketTagging",
      "s3:PutBucketTagging",
      "s3:GetBucketLocation",
    ]
    resources = ["arn:aws:s3:::${local.terraform_state_bucket}"]
  }

  # ListAllMyBuckets and GetCallerIdentity have no resource-level scope.
  statement {
    sid       = "GlobalListAndIdentity"
    effect    = "Allow"
    actions   = ["s3:ListAllMyBuckets", "sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "bootstrap_ci" {
  name   = "${var.project_name}-bootstrap-ci-policy"
  role   = aws_iam_role.bootstrap_ci.id
  policy = data.aws_iam_policy_document.bootstrap_ci_permissions.json
}
