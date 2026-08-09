# Two consequences of signing that the application had to be built around,
# recorded here because both look like application bugs from the outside:
#
#   1. OAC writes its own SigV4 signature into the `Authorization` header,
#      discarding whatever the viewer sent. A Cognito bearer token cannot
#      travel that way, so the frontend sends it in
#      `X-Codeignite-Authorization` and api/auth.py reads that first. The
#      documented alternative, signing_behavior = "no-override", passes the
#      viewer's header through only by NOT signing the request — which
#      lambda.tf's authorization_type = "AWS_IAM" then rejects. Keeping the
#      token in its own header preserves both layers.
#   2. OAC signs with SigV4 but does not hash the request body, and Lambda
#      function URLs reject UNSIGNED-PAYLOAD, so any request WITH a body
#      (POST /runs) must carry `x-amz-content-sha256` computed by the
#      caller. lib/runs/client.ts does this.
#
# Both failures are silent and misleading: (1) surfaces as a 401 from a
# perfectly valid token, and (2) as a 403 that the distribution-wide
# custom_error_response in static-site/cloudfront.tf rewrites into a 404.
# See https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-lambda.html
#
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
