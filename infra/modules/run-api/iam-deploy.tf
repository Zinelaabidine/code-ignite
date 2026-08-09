# ─────────────────────────────────────────────────────────────────────────────
# Deploy-time permissions — create/manage the Lambda function and its
# Function URL, the Lambda execution role and its own policies
# (iam-lambda.tf), and the Lambda-type OAC. Attached to the GitHub deploy
# role always, and to the local-dev role when
# attach_deploy_policies_to_local_dev_role is true.
#
# This is a separate managed policy from static-site's and run-pipeline's —
# not merged into either — for the same composability reason run-pipeline's
# iam-deploy.tf gives: a fork that drops run-api loses exactly this policy.
# It creates itself, without any special-casing, because static-site's core
# policy (iam-github-oidc.tf's IAMManagedPoliciesWrite) already grants
# iam:CreatePolicy scoped to "${local.name_prefix}-github-deploy-*" — this
# policy's own name matches that prefix, so no bootstrap-level grant is
# needed beyond what an already-deployed environment already has.
#
# Same chicken-and-egg as every other module here: the permissions THIS
# policy grants (lambda:CreateFunction, ...) are not available to the deploy
# role until this policy is attached and has propagated — deploy.yml applies
# this module's IAM resources with -target before anything that needs them,
# same as static_site and run_pipeline.
#
# No ECR statements here — the API deploys as a zip-packaged Lambda built by
# backend/scripts/build-lambda-zip.sh, not a container image. See
# docs/code-playground-hosted-api-plan.md §0 and §3.
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "github_deploy_run_api_policy" {

  # ─── Lambda ────────────────────────────────────────────────────────────────

  statement {
    sid    = "LambdaFunctionManage"
    effect = "Allow"
    actions = [
      "lambda:CreateFunction",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:ListVersionsByFunction",
      "lambda:GetFunctionCodeSigningConfig",
      "lambda:GetFunctionConcurrency",
      "lambda:GetFunctionRecursionConfig",
      "lambda:GetFunctionEventInvokeConfig",
      "lambda:DeleteFunction",
      "lambda:TagResource",
      "lambda:UntagResource",
      "lambda:ListTags",
      "lambda:CreateFunctionUrlConfig",
      "lambda:GetFunctionUrlConfig",
      "lambda:UpdateFunctionUrlConfig",
      "lambda:DeleteFunctionUrlConfig",
      "lambda:AddPermission",
      "lambda:RemovePermission",
      "lambda:GetPolicy",
    ]
    resources = [local.lambda_function_arn]
  }

  # ─── IAM — this module's own Lambda execution role and its policies ───────

  statement {
    sid    = "IAMLambdaRoleManage"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
    ]
    resources = [local.lambda_execution_role_arn]
  }

  # Lambda itself must be able to assume the role at invoke time — the
  # deploy role only needs to hand it off, not use it.
  statement {
    sid    = "IAMPassLambdaExecutionRole"
    effect = "Allow"
    actions = [
      "iam:PassRole",
    ]
    resources = [local.lambda_execution_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }

  # Policy IDs/versions are not knowable before CreatePolicy runs, so scoped
  # to the name prefix rather than an exact ARN — same pattern
  # run-pipeline/iam-deploy.tf uses for the run-api/run-worker policies.
  statement {
    sid    = "IAMLambdaLogsPolicyManage"
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
    resources = [
      "arn:aws:iam::${local.account_id}:policy/${local.name_prefix}-run-api-lambda-*",
    ]
  }

  # Only needed when there is a local-dev role to attach this module's own
  # deploy policy to.
  dynamic "statement" {
    for_each = length(data.aws_iam_role.local_dev_role) > 0 ? [1] : []

    content {
      sid    = "IAMDeployPolicyAttachToLocalDev"
      effect = "Allow"
      actions = [
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:ListAttachedRolePolicies",
      ]
      resources = [data.aws_iam_role.local_dev_role[0].arn]
    }
  }

  # ─── CloudWatch Logs — this function's own log group ──────────────────────

  # DescribeLogGroups is a list API: IAM evaluates it against
  # arn:...:log-group::log-stream: (empty name), so a named log-group ARN
  # never matches. AWS offers no resource-level scope for this action.
  statement {
    sid    = "LogGroupsDescribe"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "LogGroupManage"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
      "logs:ListTagsForResource",
    ]
    resources = [
      "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-run-api",
      "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-run-api:*",
    ]
  }

  # ─── CloudFront — the Lambda-type OAC only. This module never touches the
  # distribution itself; that stays static-site's. Same "AWS offers no
  # resource-level scope" reasoning as static-site's own CloudFrontOACManage
  # statement — OAC IDs are opaque at plan time. ──────────────────────────────

  statement {
    sid    = "CloudFrontOACManage"
    effect = "Allow"
    actions = [
      "cloudfront:CreateOriginAccessControl",
      "cloudfront:GetOriginAccessControl",
      "cloudfront:GetOriginAccessControlConfig",
      "cloudfront:UpdateOriginAccessControl",
      "cloudfront:DeleteOriginAccessControl",
      "cloudfront:ListOriginAccessControls",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "github_deploy_run_api_policy" {
  provider = aws.this

  name        = "${local.name_prefix}-github-deploy-run-api-policy"
  description = "Lambda function/Function URL, Lambda execution role, and Lambda-type OAC management for the GitHub and local-dev roles"
  policy      = data.aws_iam_policy_document.github_deploy_run_api_policy.json

  tags = {
    Name        = "${local.name_prefix}-github-deploy-run-api-policy"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

resource "aws_iam_role_policy_attachment" "github_deploy_run_api" {
  provider = aws.this

  role       = data.aws_iam_role.github_oidc_deploy_role.name
  policy_arn = aws_iam_policy.github_deploy_run_api_policy.arn
}

resource "aws_iam_role_policy_attachment" "local_dev_run_api_deploy" {
  count    = var.attach_deploy_policies_to_local_dev_role ? 1 : 0
  provider = aws.this

  role       = data.aws_iam_role.local_dev_role[0].name
  policy_arn = aws_iam_policy.github_deploy_run_api_policy.arn
}

resource "time_sleep" "run_api_iam_propagation" {
  create_duration = "15s"

  triggers = {
    policy_hash = sha256(aws_iam_policy.github_deploy_run_api_policy.policy)
  }

  depends_on = [aws_iam_role_policy_attachment.github_deploy_run_api]
}
