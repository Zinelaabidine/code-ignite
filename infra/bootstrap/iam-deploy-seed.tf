# ─── Deploy-role seed permissions ─────────────────────────────────────────────
#
# Bootstrap creates the GitHub deploy roles with trust only. The env module then
# creates and attaches the full managed policies (core / storage / cdn / …).
# That leaves a chicken-and-egg on a fresh environment:
#
#   1. terraform init needs S3 access to the state bucket
#   2. deploy.yml's targeted IAM apply needs CreatePolicy / AttachRolePolicy
#      before those managed policies exist
#
# Both grants live here — bootstrap owns the state bucket and the empty roles,
# so it is the only place that can break the cycle without a local admin apply.
# Once the env module's managed policies are attached they supersede this seed
# for day-to-day deploys; the seed stays as the floor for the next fresh env.

data "aws_iam_policy_document" "github_deploy_seed" {
  for_each = toset(local.environments)

  statement {
    sid    = "TerraformStateBackend"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      aws_s3_bucket.terraform_state.arn,
      "${aws_s3_bucket.terraform_state.arn}/*",
    ]
  }

  statement {
    sid    = "IAMDeployRoleRead"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:ListRoleTags",
    ]
    resources = [
      aws_iam_role.github_deploy[each.key].arn,
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-local-dev-role",
    ]
  }

  statement {
    sid    = "IAMDeployPoliciesManage"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    # Matches static-site / run-pipeline / run-api managed deploy policy names:
    #   ${project}-${env}-github-deploy-*
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project_name}-${each.key}-github-deploy-*",
    ]
  }

  statement {
    sid    = "IAMDeployPoliciesAttach"
    effect = "Allow"
    actions = [
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
    ]
    resources = [
      aws_iam_role.github_deploy[each.key].arn,
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-local-dev-role",
    ]
  }
}

resource "aws_iam_role_policy" "github_deploy_seed" {
  for_each = toset(local.environments)

  name   = "${var.project_name}-${each.key}-github-deploy-seed"
  role   = aws_iam_role.github_deploy[each.key].id
  policy = data.aws_iam_policy_document.github_deploy_seed[each.key].json
}
