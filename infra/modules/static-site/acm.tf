# CloudFront requires its viewer certificate to live in us-east-1.
#
# The certificate itself is NOT managed here: a single wildcard cert is shared
# by every environment, so putting it in one environment's state would make
# that environment's destroy break the others. Issue it once (manually or in a
# separate root) and reference it by domain.
data "aws_acm_certificate" "wildcard" {
  provider = aws.us_east_1

  domain      = var.certificate_domain_name
  statuses    = ["ISSUED"]
  most_recent = true
}
