output "hosted_zone_id" {
  description = "ID of the Route 53 hosted zone serving the site domain."
  value       = data.aws_route53_zone.this.id
}

output "hosted_zone_name" {
  description = "Name of the Route 53 hosted zone serving the site domain."
  value       = data.aws_route53_zone.this.name
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket holding the static site build."
  value       = aws_s3_bucket.site.bucket
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket holding the static site build."
  value       = aws_s3_bucket.site.arn
}

output "s3_bucket_regional_domain_name" {
  description = "Regional domain name of the static site S3 bucket."
  value       = aws_s3_bucket.site.bucket_regional_domain_name
}

output "logs_bucket_name" {
  description = "Name of the access log bucket, or null when enable_access_logging is false."
  value       = one(aws_s3_bucket.logs[*].bucket)
}

output "acm_certificate_arn" {
  description = "ARN of the ACM certificate attached to the CloudFront distribution."
  value       = data.aws_acm_certificate.wildcard.arn
}

output "acm_certificate_domain" {
  description = "Domain of the ACM certificate attached to the CloudFront distribution."
  value       = data.aws_acm_certificate.wildcard.domain
}

output "cloudfront_distribution_id" {
  description = "ID of the CloudFront distribution (used for cache invalidation on deploy)."
  value       = aws_cloudfront_distribution.site.id
}

output "cloudfront_domain_name" {
  description = "CloudFront-assigned domain name of the distribution."
  value       = aws_cloudfront_distribution.site.domain_name
}

output "cloudfront_distribution_arn" {
  description = "ARN of the CloudFront distribution."
  value       = aws_cloudfront_distribution.site.arn
}

output "response_headers_policy_id" {
  description = "ID of the CloudFront response headers policy carrying the HSTS and framing configuration."
  value       = aws_cloudfront_response_headers_policy.security.id
}

output "waf_web_acl_arn" {
  description = "ARN of the WAF web ACL attached to the distribution, or null when enable_waf is false."
  value       = one(aws_wafv2_web_acl.site[*].arn)
}

output "site_url" {
  description = "Public HTTPS URL of the deployed site."
  value       = "https://${var.domain_name}"
}

output "github_oidc_deploy_role_arn" {
  description = "ARN of the IAM role GitHub Actions assumes to deploy this environment."
  value       = data.aws_iam_role.github_oidc_deploy_role.arn
}

output "local_dev_role_arn" {
  description = "ARN of the shared IAM role developers assume for local Terraform runs, or null when this environment does not attach policies to it."
  value       = one(data.aws_iam_role.local_dev_role[*].arn)
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID — injected into the frontend build as NEXT_PUBLIC_USER_POOL_ID."
  value       = aws_cognito_user_pool.this.id
}

output "cognito_user_pool_arn" {
  description = "ARN of the Cognito User Pool."
  value       = aws_cognito_user_pool.this.arn
}

output "cognito_client_id" {
  description = "Cognito App Client ID — injected into the frontend build as NEXT_PUBLIC_CLIENT_ID."
  value       = aws_cognito_user_pool_client.this.id
}
