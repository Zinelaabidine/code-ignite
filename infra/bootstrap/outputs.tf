output "bootstrap_ci_role_arn" {
  description = "ARN of the bootstrap CI role assumed by bootstrap.yml via OIDC (no static keys)."
  value       = aws_iam_role.bootstrap_ci.arn
}

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider — created by this apply, or an existing one that was reused. See create_oidc_provider."
  value       = local.github_oidc_provider_arn
}

output "github_deploy_role_arns" {
  description = "Map of environment name to GitHub Actions deploy role ARN."
  value       = { for env, r in aws_iam_role.github_deploy : env => r.arn }
}

output "local_dev_role_arn" {
  description = "ARN of the local-developer IAM role, or null when local_dev_iam_users is empty. Not used by GitHub Actions."
  value       = one(aws_iam_role.local_dev[*].arn)
}

output "terraform_state_bucket" {
  description = "Name of the S3 bucket used for Terraform remote state. Use this value for `bucket` in every root's backend.hcl."
  value       = aws_s3_bucket.terraform_state.id
}

output "account_id" {
  description = "AWS account ID the bootstrap resources were created in."
  value       = data.aws_caller_identity.current.account_id
}
