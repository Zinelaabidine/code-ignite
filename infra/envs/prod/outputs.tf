output "site_url" {
  description = "Public HTTPS URL of the prod site."
  value       = module.static_site.site_url
}

output "s3_bucket_name" {
  description = "S3 bucket holding the prod static site build."
  value       = module.static_site.s3_bucket_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID for prod (used for cache invalidation on deploy)."
  value       = module.static_site.cloudfront_distribution_id
}

output "github_oidc_deploy_role_arn" {
  description = "IAM role GitHub Actions assumes to deploy prod."
  value       = module.static_site.github_oidc_deploy_role_arn
}

output "local_dev_role_arn" {
  description = "IAM role developers assume for local Terraform runs."
  value       = module.static_site.local_dev_role_arn
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID — built into the frontend as NEXT_PUBLIC_USER_POOL_ID."
  value       = module.static_site.cognito_user_pool_id
}

output "cognito_client_id" {
  description = "Cognito App Client ID — built into the frontend as NEXT_PUBLIC_CLIENT_ID."
  value       = module.static_site.cognito_client_id
}
