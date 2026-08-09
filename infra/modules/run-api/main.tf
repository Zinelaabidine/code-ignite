# Account ID is never hardcoded — every constructed ARN in this module derives
# from this data source so the template drops into any AWS account unchanged.
data "aws_caller_identity" "current" {
  provider = aws.this
}

# Created once in infra/bootstrap, per environment. This module never manages
# the trust policy — only iam-deploy.tf's own managed policy, attached here.
# Its name-prefix wildcard grant (IAMManagedPoliciesWrite in
# static-site/iam-github-oidc.tf) already covers creating THIS module's own
# github-deploy-run-api-policy — see iam-deploy.tf's header comment.
data "aws_iam_role" "github_oidc_deploy_role" {
  provider = aws.this

  name = "${local.name_prefix}-github-deploy-role"
}

# Shared across all envs — created once in infra/bootstrap, and only when
# local_dev_iam_users there is non-empty. Looked up only when this module's
# own deploy policy needs attaching to it.
data "aws_iam_role" "local_dev_role" {
  count    = var.attach_deploy_policies_to_local_dev_role ? 1 : 0
  provider = aws.this

  name = "${var.project_name}-local-dev-role"
}
