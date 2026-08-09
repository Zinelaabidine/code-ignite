output "site_url" {
  description = "Public HTTPS URL of the dev site."
  value       = module.static_site.site_url
}

output "s3_bucket_name" {
  description = "S3 bucket holding the dev static site build."
  value       = module.static_site.s3_bucket_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID for dev (used for cache invalidation on deploy)."
  value       = module.static_site.cloudfront_distribution_id
}

output "github_oidc_deploy_role_arn" {
  description = "IAM role GitHub Actions assumes to deploy dev."
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

output "runs_queue_url" {
  description = "SQS queue URL — CODEIGNITE_RUNS_QUEUE_URL for the local backend .env."
  value       = module.run_pipeline.runs_queue_url
}

output "jobs_bucket_name" {
  description = "S3 bucket holding job input/result objects — CODEIGNITE_JOBS_BUCKET for the local backend .env."
  value       = module.run_pipeline.jobs_bucket_name
}

output "run_api_ecr_repository_url" {
  description = "ECR repository URL deploy.yml pushes the backend/Dockerfile.lambda image to."
  value       = module.run_api.ecr_repository_url
}

output "run_api_function_url" {
  description = "The run-api Lambda's own Function URL. Not the public entry point — CloudFront (site_url + /runs or /healthz) is; requesting this URL directly is expected to fail with an IAM auth error, since only CloudFront's OAC-signed requests are permitted (see infra/modules/run-api/lambda.tf)."
  value       = "https://${module.run_api.function_url_domain_name}/"
}
