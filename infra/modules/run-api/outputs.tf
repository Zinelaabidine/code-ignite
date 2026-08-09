output "lambda_function_name" {
  description = "Name of the run-api Lambda function."
  value       = aws_lambda_function.api.function_name
}

# aws_lambda_function_url.api.function_url is the full URL
# ("https://<id>.lambda-url.<region>.on.aws/") — CloudFront's origin{}
# block wants a bare domain name, so the scheme and trailing slash are
# stripped once here rather than in every caller.
output "function_url_domain_name" {
  description = "Bare domain name (no scheme, no trailing slash) of the Lambda Function URL — consumed by infra/modules/static-site's api_origin_domain_name variable."
  value       = trimsuffix(trimprefix(aws_lambda_function_url.api.function_url, "https://"), "/")
}

output "origin_access_control_id" {
  description = "ID of the Lambda-type CloudFront OAC — consumed by infra/modules/static-site's api_origin_access_control_id variable."
  value       = aws_cloudfront_origin_access_control.api.id
}
