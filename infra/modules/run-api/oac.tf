# Mirrors static-site's S3 Origin Access Control (static-site/cloudfront.tf):
# CloudFront signs every request to the Function URL with SigV4, and the
# Function URL's own authorization_type = "AWS_IAM" (lambda.tf) validates
# that signature — a direct request to the Function URL's own domain, not
# signed by this OAC, is rejected before it reaches application code. Same
# shape of protection the static site's origin already has, applied to the
# API origin.
resource "aws_cloudfront_origin_access_control" "api" {
  provider = aws.this

  name                              = "${local.name_prefix}-run-api-oac"
  description                       = "OAC for the run-api Lambda Function URL origin"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}
