locals {
  name_prefix = "${var.project_name}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id

  # Built by name, not read from aws_ecr_repository.api.arn /
  # aws_lambda_function.api.arn / aws_iam_role.lambda_execution.arn — same
  # reasoning as run-pipeline/locals.tf: the deploy policy document
  # (iam-deploy.tf) must not depend on the resources it authorizes creating,
  # or Terraform refuses to plan the cycle. ECR repository names, Lambda
  # function names, and IAM role names are all chosen by this module, not
  # assigned by AWS, so every ARN below is knowable in advance.
  ecr_repository_arn        = "arn:aws:ecr:${var.aws_region}:${local.account_id}:repository/${local.name_prefix}-run-api"
  lambda_function_arn       = "arn:aws:lambda:${var.aws_region}:${local.account_id}:function:${local.name_prefix}-run-api"
  lambda_execution_role_arn = "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-run-api-lambda-role"
}
