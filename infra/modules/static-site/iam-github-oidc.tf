# The GitHub Actions OIDC provider and the deploy-role trust policy are managed
# in infra/bootstrap (bootstrap.yml workflow, manual trigger only).
#
# WHY: A workflow must not manage its own trust chain — doing so creates a
# circular dependency where a broken trust policy cannot be repaired by the
# same workflow that broke it. Bootstrap resources are intentionally separated
# into a workflow that uses a different role and requires a protected
# environment with human approval.
#
# These data sources look up roles that bootstrap already created. Applying
# infra/envs/<env> will NOT modify the trust policy — only infra/bootstrap can.
data "aws_iam_role" "github_oidc_deploy_role" {
  provider = aws.this

  name = "${local.name_prefix}-github-deploy-role"
}

# Shared across all envs — created once in infra/bootstrap, and only when
# `local_dev_iam_users` there is non-empty. Looked up only by the environment
# that attaches policies to it, so the other environments do not fail when the
# role was never created.
data "aws_iam_role" "local_dev_role" {
  count    = var.attach_deploy_policies_to_local_dev_role ? 1 : 0
  provider = aws.this

  name = "${var.project_name}-local-dev-role"
}

# ─────────────────────────────────────────────────────────────────────────────
# Core deploy permissions — Cognito and IAM.
#
# Permissions are split across several managed policies rather than one inline
# policy because inline policies on the shared local-dev role are cumulative
# across environments and hit the 10 240-byte quota after two applies.
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "github_deploy_policy" {

  # ─── Cognito ───────────────────────────────────────────────────────────────

  # ListUserPools is a list API with no resource-level permission scope.
  statement {
    sid    = "CognitoListGlobal"
    effect = "Allow"
    actions = [
      "cognito-idp:ListUserPools",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "CognitoManage"
    effect = "Allow"
    actions = [
      "cognito-idp:CreateUserPool",
      "cognito-idp:DescribeUserPool",
      "cognito-idp:UpdateUserPool",
      "cognito-idp:AddCustomAttributes",
      "cognito-idp:DeleteUserPool",
      "cognito-idp:SetUserPoolMfaConfig",
      "cognito-idp:GetUserPoolMfaConfig",
      "cognito-idp:ListUserPoolClients",
      "cognito-idp:CreateUserPoolClient",
      "cognito-idp:DescribeUserPoolClient",
      "cognito-idp:UpdateUserPoolClient",
      "cognito-idp:DeleteUserPoolClient",
      "cognito-idp:TagResource",
      "cognito-idp:UntagResource",
      "cognito-idp:ListTagsForResource",
      "cognito-idp:CreateGroup",
      "cognito-idp:GetGroup",
      "cognito-idp:UpdateGroup",
      "cognito-idp:DeleteGroup",
      "cognito-idp:ListGroups",
    ]
    resources = [
      "arn:aws:cognito-idp:${var.aws_region}:${local.account_id}:userpool/*",
    ]
  }

  # ─── IAM ───────────────────────────────────────────────────────────────────

  # ListOpenIDConnectProviders is a list API that AWS requires on "*".
  statement {
    sid    = "IAMListOIDCGlobal"
    effect = "Allow"
    actions = [
      "iam:ListOpenIDConnectProviders",
    ]
    resources = ["*"]
  }

  # Read-only on the pre-existing GitHub Actions OIDC provider.
  statement {
    sid    = "IAMOIDCProviderRead"
    effect = "Allow"
    actions = [
      "iam:GetOpenIDConnectProvider",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com",
    ]
  }

  # Scoped to project-owned IAM roles only. Note this grants no
  # iam:UpdateAssumeRolePolicy — the deploy role cannot widen its own trust.
  statement {
    sid    = "IAMProjectRolesManage"
    effect = "Allow"
    actions = [
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
    resources = [
      "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-github-deploy-role",
      "arn:aws:iam::${local.account_id}:role/${var.project_name}-local-dev-role",
    ]
  }

  statement {
    sid    = "IAMManagedPoliciesRead"
    effect = "Allow"
    actions = [
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
    ]
    # Wildcard suffix covers every env-scoped deploy managed policy (core,
    # storage, cdn) so a new split policy can be added without editing this.
    resources = [
      "arn:aws:iam::${local.account_id}:policy/${local.name_prefix}-github-deploy-*",
    ]
  }

  statement {
    sid    = "IAMManagedPoliciesWrite"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:policy/${local.name_prefix}-github-deploy-*",
    ]
  }
}

resource "aws_iam_policy" "github_deploy_core_policy" {
  provider = aws.this

  name        = "${local.name_prefix}-github-deploy-core-policy"
  description = "Core deploy permissions (Cognito, IAM) for the GitHub and local-dev roles"
  policy      = data.aws_iam_policy_document.github_deploy_policy.json

  tags = {
    Name        = "${local.name_prefix}-github-deploy-core-policy"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

resource "aws_iam_role_policy_attachment" "github_deploy_core" {
  provider = aws.this

  role       = data.aws_iam_role.github_oidc_deploy_role.name
  policy_arn = aws_iam_policy.github_deploy_core_policy.arn
}

resource "aws_iam_role_policy_attachment" "local_dev_core" {
  count    = var.attach_deploy_policies_to_local_dev_role ? 1 : 0
  provider = aws.this

  role       = data.aws_iam_role.local_dev_role[0].name
  policy_arn = aws_iam_policy.github_deploy_core_policy.arn
}

# IAM policy changes take a few seconds to propagate before subsequent AWS API
# calls from the same session observe them. Any resource whose create
# permission lives in the core policy must gate on this sleep.
#
# The `triggers` map forces a replacement (destroy + recreate, sleeping 15s on
# create) whenever the policy document changes — not only on first creation.
# Without triggers the sleep is a no-op on later applies and a race opens
# between PutPolicy returning and IAM finishing propagation.
resource "time_sleep" "iam_propagation" {
  create_duration = "15s"

  triggers = {
    policy_hash = sha256(aws_iam_policy.github_deploy_core_policy.policy)
  }

  depends_on = [aws_iam_role_policy_attachment.github_deploy_core]
}

# ─────────────────────────────────────────────────────────────────────────────
# Storage permissions — static site bucket, access log bucket, and the
# Terraform state backend.
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "github_deploy_storage_policy" {

  # ListAllMyBuckets has no resource-level permission scope. It also backs the
  # GetCanonicalUserId call used by the log bucket ACL.
  statement {
    sid    = "S3ListAllBuckets"
    effect = "Allow"
    actions = [
      "s3:ListAllMyBuckets",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "S3BucketManage"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:GetBucketVersioning",
      "s3:PutBucketVersioning",
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketPublicAccessBlock",
      "s3:GetBucketOwnershipControls",
      "s3:PutBucketOwnershipControls",
      "s3:GetEncryptionConfiguration",
      "s3:PutEncryptionConfiguration",
      "s3:GetBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:GetBucketTagging",
      "s3:PutBucketTagging",
      "s3:GetBucketAcl",
      "s3:PutBucketAcl",
      "s3:GetBucketLogging",
      "s3:PutBucketLogging",
      "s3:GetLifecycleConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:GetBucketCORS",
      "s3:GetBucketWebsite",
      "s3:GetBucketRequestPayment",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetReplicationConfiguration",
      "s3:GetAccelerateConfiguration",
      "s3:GetIntelligentTieringConfiguration",
    ]
    resources = concat(
      [aws_s3_bucket.site.arn],
      local.enable_logging ? [aws_s3_bucket.logs[0].arn] : [],
    )
  }

  statement {
    sid    = "S3SiteObjectsAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "${aws_s3_bucket.site.arn}/*",
    ]
  }

  statement {
    sid    = "S3TerraformStateBackend"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "arn:aws:s3:::${var.terraform_state_bucket}",
      "arn:aws:s3:::${var.terraform_state_bucket}/*",
    ]
  }
}

resource "aws_iam_policy" "github_deploy_storage_policy" {
  provider = aws.this

  name        = "${local.name_prefix}-github-deploy-storage-policy"
  description = "S3 site bucket, log bucket, and Terraform state backend permissions for the GitHub and local-dev roles"
  policy      = data.aws_iam_policy_document.github_deploy_storage_policy.json

  tags = {
    Name        = "${local.name_prefix}-github-deploy-storage-policy"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

resource "aws_iam_role_policy_attachment" "github_deploy_storage" {
  provider = aws.this

  role       = data.aws_iam_role.github_oidc_deploy_role.name
  policy_arn = aws_iam_policy.github_deploy_storage_policy.arn
}

resource "aws_iam_role_policy_attachment" "local_dev_storage" {
  count    = var.attach_deploy_policies_to_local_dev_role ? 1 : 0
  provider = aws.this

  role       = data.aws_iam_role.local_dev_role[0].name
  policy_arn = aws_iam_policy.github_deploy_storage_policy.arn
}

resource "time_sleep" "storage_iam_propagation" {
  create_duration = "15s"

  triggers = {
    storage_policy_hash = sha256(aws_iam_policy.github_deploy_storage_policy.policy)
  }

  depends_on = [aws_iam_role_policy_attachment.github_deploy_storage]
}

# ─────────────────────────────────────────────────────────────────────────────
# CDN / DNS / TLS permissions — CloudFront, Route 53, ACM, and optionally WAF.
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "github_deploy_cdn_policy" {

  # ─── CloudFront ────────────────────────────────────────────────────────────

  # OAC IDs are opaque at plan time and AWS supports no resource-level ARN
  # scoping for these OAC-specific actions.
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

  # Cache policies and response-headers policies are account-level CloudFront
  # resources that AWS does not expose for resource-level authorisation.
  statement {
    sid    = "CloudFrontPolicyManage"
    effect = "Allow"
    actions = [
      "cloudfront:GetCachePolicy",
      "cloudfront:GetCachePolicyConfig",
      "cloudfront:ListCachePolicies",
      "cloudfront:CreateResponseHeadersPolicy",
      "cloudfront:GetResponseHeadersPolicy",
      "cloudfront:GetResponseHeadersPolicyConfig",
      "cloudfront:UpdateResponseHeadersPolicy",
      "cloudfront:DeleteResponseHeadersPolicy",
      "cloudfront:ListResponseHeadersPolicies",
    ]
    resources = ["*"]
  }

  # ListFunctions is account-global with no resource-level permission scope.
  statement {
    sid       = "CloudFrontFunctionList"
    effect    = "Allow"
    actions   = ["cloudfront:ListFunctions"]
    resources = ["*"]
  }

  # CreateFunction is evaluated before the function exists; AWS does not honor
  # name-prefix resource constraints for this action (returns AccessDenied).
  statement {
    sid    = "CloudFrontFunctionCreate"
    effect = "Allow"
    actions = [
      "cloudfront:CreateFunction",
      "cloudfront:PublishFunction",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "CloudFrontFunctionManage"
    effect = "Allow"
    actions = [
      "cloudfront:UpdateFunction",
      "cloudfront:DeleteFunction",
      "cloudfront:DescribeFunction",
      "cloudfront:GetFunction",
      "cloudfront:TestFunction",
      "cloudfront:TagResource",
      "cloudfront:UntagResource",
      "cloudfront:ListTagsForResource",
    ]
    resources = [
      "arn:aws:cloudfront::${local.account_id}:function/${local.name_prefix}-*",
    ]
  }

  # Distribution IDs are assigned by AWS and unknown before the first apply, so
  # CreateDistribution cannot reference a specific ARN. Scoped to this account.
  statement {
    sid    = "CloudFrontDistributionManage"
    effect = "Allow"
    actions = [
      "cloudfront:CreateDistribution",
      "cloudfront:GetDistribution",
      "cloudfront:GetDistributionConfig",
      "cloudfront:UpdateDistribution",
      "cloudfront:DeleteDistribution",
      "cloudfront:ListDistributions",
      "cloudfront:CreateInvalidation",
      "cloudfront:GetInvalidation",
      "cloudfront:ListInvalidations",
      "cloudfront:TagResource",
      "cloudfront:UntagResource",
      "cloudfront:ListTagsForResource",
    ]
    resources = [
      "arn:aws:cloudfront::${local.account_id}:distribution/*",
    ]
  }

  # ─── Route 53 ──────────────────────────────────────────────────────────────

  # Zone-listing APIs have no resource-level permission scope.
  statement {
    sid    = "Route53ListGlobal"
    effect = "Allow"
    actions = [
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "Route53ZoneManage"
    effect = "Allow"
    actions = [
      "route53:GetHostedZone",
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets",
      "route53:GetChange",
      "route53:ListTagsForResource",
    ]
    # Deliberately not scoped to this zone's ID. The ID comes from
    # data.aws_route53_zone.this, which is read with the deploy role's own
    # credentials — so scoping the grant to it would make the policy that
    # authorises the lookup depend on the lookup succeeding. That deadlocks the
    # first apply in a fresh account.
    resources = [
      "arn:aws:route53:::hostedzone/*",
      "arn:aws:route53:::change/*",
    ]
  }

  # ─── ACM ───────────────────────────────────────────────────────────────────

  # ListCertificates is a list API that AWS requires on "*".
  statement {
    sid    = "ACMListGlobal"
    effect = "Allow"
    actions = [
      "acm:ListCertificates",
    ]
    resources = ["*"]
  }

  # Read-only: the wildcard certificate is looked up, not managed, by this
  # module. CloudFront certificates must live in us-east-1.
  statement {
    sid    = "ACMCertificateRead"
    effect = "Allow"
    actions = [
      "acm:DescribeCertificate",
      "acm:GetCertificate",
      "acm:ListTagsForCertificate",
    ]
    resources = [
      "arn:aws:acm:us-east-1:${local.account_id}:certificate/*",
    ]
  }

  # ─── WAF (only when enabled) ───────────────────────────────────────────────

  dynamic "statement" {
    for_each = var.enable_waf ? [1] : []

    content {
      sid    = "WAFWebACLManage"
      effect = "Allow"
      actions = [
        "wafv2:CreateWebACL",
        "wafv2:GetWebACL",
        "wafv2:UpdateWebACL",
        "wafv2:DeleteWebACL",
        "wafv2:ListWebACLs",
        "wafv2:AssociateWebACL",
        "wafv2:DisassociateWebACL",
        "wafv2:TagResource",
        "wafv2:UntagResource",
        "wafv2:ListTagsForResource",
        "wafv2:GetLoggingConfiguration",
      ]
      # Web ACL IDs are generated by AWS, so CreateWebACL cannot name one.
      # Scoped to this account's global (CloudFront) WAF scope.
      resources = [
        "arn:aws:wafv2:us-east-1:${local.account_id}:global/webacl/*",
        "arn:aws:wafv2:us-east-1:${local.account_id}:global/managedruleset/*",
      ]
    }
  }

  # Managed rule groups are AWS-owned and must be readable to reference them.
  dynamic "statement" {
    for_each = var.enable_waf ? [1] : []

    content {
      sid    = "WAFManagedRuleGroupsRead"
      effect = "Allow"
      actions = [
        "wafv2:DescribeManagedRuleGroup",
        "wafv2:ListAvailableManagedRuleGroups",
      ]
      resources = ["*"]
    }
  }
}

resource "aws_iam_policy" "github_deploy_cdn_policy" {
  provider = aws.this

  name        = "${local.name_prefix}-github-deploy-cdn-policy"
  description = "CloudFront, Route 53, ACM, and WAF permissions for the GitHub and local-dev roles"
  policy      = data.aws_iam_policy_document.github_deploy_cdn_policy.json

  tags = {
    Name        = "${local.name_prefix}-github-deploy-cdn-policy"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

resource "aws_iam_role_policy_attachment" "github_deploy_cdn" {
  provider = aws.this

  role       = data.aws_iam_role.github_oidc_deploy_role.name
  policy_arn = aws_iam_policy.github_deploy_cdn_policy.arn
}

resource "aws_iam_role_policy_attachment" "local_dev_cdn" {
  count    = var.attach_deploy_policies_to_local_dev_role ? 1 : 0
  provider = aws.this

  role       = data.aws_iam_role.local_dev_role[0].name
  policy_arn = aws_iam_policy.github_deploy_cdn_policy.arn
}

# CloudFront Function APIs reject calls made before the CDN policy has
# propagated (CreateFunction returns AccessDenied), so this sleep is longer.
resource "time_sleep" "cdn_iam_propagation" {
  create_duration = "45s"

  triggers = {
    cdn_policy_sha = sha256(aws_iam_policy.github_deploy_cdn_policy.policy)
  }

  depends_on = [
    aws_iam_policy.github_deploy_cdn_policy,
    aws_iam_role_policy_attachment.github_deploy_cdn,
  ]
}
