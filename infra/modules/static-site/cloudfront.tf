resource "aws_cloudfront_origin_access_control" "site" {
  provider = aws.this

  name                              = "${local.name_prefix}-oac"
  description                       = "OAC for ${var.domain_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# AWS-managed cache policy. Replaces the legacy `forwarded_values` block, which
# the provider deprecates and which cannot express modern cache keys.
# CachingOptimized: caches on URI only, forwards no cookies/headers/query
# strings, and enables Gzip and Brotli.
data "aws_cloudfront_cache_policy" "caching_optimized" {
  provider = aws.this

  name = "Managed-CachingOptimized"
}

# Next.js static export writes routes as *.html (e.g. settings.html) but
# browsers request extensionless paths (/settings). S3 REST + OAC returns 403
# for a missing key, so rewrite viewer requests before they reach the origin.
resource "aws_cloudfront_function" "nextjs_url_rewrite" {
  provider = aws.this

  name    = "${local.name_prefix}-nextjs-url-rewrite"
  runtime = "cloudfront-js-2.0"
  comment = "Map extensionless paths to .html for a Next.js static export on S3"
  publish = true
  code    = <<-EOF
    function handler(event) {
      var request = event.request;
      var uri = request.uri;

      if (uri.endsWith("/")) {
        request.uri += "index.html";
      } else if (!uri.includes(".")) {
        request.uri += ".html";
      }

      return request;
    }
  EOF

  depends_on = [time_sleep.cdn_iam_propagation]
}

resource "aws_cloudfront_distribution" "site" {
  provider = aws.this

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Static site for ${var.domain_name}"
  default_root_object = "index.html"
  price_class         = var.cloudfront_price_class
  http_version        = "http2and3"

  aliases = [var.domain_name]

  web_acl_id = var.enable_waf ? aws_wafv2_web_acl.site[0].arn : null

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3-${aws_s3_bucket.site.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-${aws_s3_bucket.site.id}"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]

    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.nextjs_url_rewrite.arn
    }
  }

  dynamic "logging_config" {
    for_each = local.enable_logging ? [1] : []

    content {
      bucket          = aws_s3_bucket.logs[0].bucket_domain_name
      prefix          = "cloudfront/"
      include_cookies = false
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # OAC returns 403 (not 404) for keys that do not exist, so both map to the
  # exported 404 page.
  custom_error_response {
    error_code            = 403
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 300
  }

  custom_error_response {
    error_code            = 404
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 300
  }

  viewer_certificate {
    acm_certificate_arn      = data.aws_acm_certificate.wildcard.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = {
    Name        = "${local.name_prefix}-cdn"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }

  depends_on = [aws_s3_bucket_acl.logs]
}
