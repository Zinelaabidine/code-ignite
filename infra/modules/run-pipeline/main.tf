# Shared data sources — account ID and the two IAM roles this module either
# looks up (never creates) or attaches its own managed policies to.

# Account ID is never hardcoded — every constructed ARN in this module derives
# from this data source so the template drops into any AWS account unchanged.
data "aws_caller_identity" "current" {
  provider = aws.this
}

# Created once in infra/bootstrap, per environment. This module never manages
# the trust policy — only iam-deploy.tf's own managed policy, attached here.
data "aws_iam_role" "github_oidc_deploy_role" {
  provider = aws.this

  name = "${local.name_prefix}-github-deploy-role"
}

# Shared across all envs — created once in infra/bootstrap, and only when
# local_dev_iam_users there is non-empty. Looked up once and reused by both
# the deploy-time policy (iam-deploy.tf) and the runtime policies
# (iam-runtime.tf), each gated by its own variable.
data "aws_iam_role" "local_dev_role" {
  count    = (var.attach_deploy_policies_to_local_dev_role || var.attach_runtime_policies_to_local_dev_role) ? 1 : 0
  provider = aws.this

  name = "${var.project_name}-local-dev-role"
}
