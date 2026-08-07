# ─────────────────────────────────────────────────────────────────────────────
# WAF web ACL for the CloudFront distribution. Optional — billed per web ACL,
# per rule, and per million requests — so `enable_waf` defaults to false.
#
# A web ACL scoped to CloudFront must be created in us-east-1 regardless of
# where the rest of the stack lives, hence the aws.us_east_1 provider.
#
# The value here is mostly the rate limit: Cognito sign-in and sign-up run
# straight from the browser against a public User Pool, so throttling per-IP
# request floods is the cheapest defence against credential stuffing.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_wafv2_web_acl" "site" {
  count    = var.enable_waf ? 1 : 0
  provider = aws.us_east_1

  name        = "${local.name_prefix}-web-acl"
  description = "Managed rules and per-IP rate limiting for ${var.domain_name}"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "RateLimitPerIP"
    priority = 3

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit_per_5min
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-web-acl"
    sampled_requests_enabled   = true
  }

  tags = {
    Name        = "${local.name_prefix}-web-acl"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}
