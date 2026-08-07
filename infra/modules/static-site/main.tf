data "aws_route53_zone" "this" {
  provider = aws.this

  name         = var.hosted_zone_name
  private_zone = false
}

# Account ID is never hardcoded — every constructed ARN in this module derives
# from this data source so the template drops into any AWS account unchanged.
data "aws_caller_identity" "current" {
  provider = aws.this
}

# Needed to express the bucket owner in the log bucket ACL. CloudFront standard
# logging is the one AWS feature here that still requires an ACL grant rather
# than a bucket policy.
data "aws_canonical_user_id" "current" {
  count    = local.enable_logging ? 1 : 0
  provider = aws.this
}
