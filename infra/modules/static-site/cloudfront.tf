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

# For the code-playground API behaviors only (below): every response here is
# per-user and authenticated (a bearer token identifies the caller and scopes
# what they can read — see api/routes_runs.py's 404-not-403 ownership check).
# Caching any of it at the edge would serve one user's run result to another.
data "aws_cloudfront_cache_policy" "caching_disabled" {
  count    = var.api_origin_domain_name != null ? 1 : 0
  provider = aws.this

  name = "Managed-CachingDisabled"
}

# Forwards the Authorization header (the bearer token api/auth.py verifies)
# and the querystring, but not the Host header — the Lambda Function URL
# neither expects nor validates this distribution's own hostname.
data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  count    = var.api_origin_domain_name != null ? 1 : 0
  provider = aws.this

  name = "Managed-AllViewerExceptHostHeader"
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

  # The code-playground API — a Lambda Function URL, treated as a custom
  # (plain HTTPS) origin. Absent entirely when api_origin_domain_name is
  # null, so this distribution's shape is unchanged in any environment
  # without infra/modules/run-api (staging, prod, today).
  dynamic "origin" {
    for_each = var.api_origin_domain_name != null ? [1] : []

    content {
      domain_name              = var.api_origin_domain_name
      origin_id                = "lambda-run-api"
      origin_access_control_id = var.api_origin_access_control_id

      custom_origin_config {
        http_port                = 80
        https_port               = 443
        origin_protocol_policy   = "https-only"
        origin_ssl_protocols     = ["TLSv1.2"]
        origin_read_timeout      = 30
        origin_keepalive_timeout = 5
      }
    }
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

  # /runs* and /healthz — routed to the Lambda origin above instead of S3.
  # Deliberately no function_association: the Next.js extensionless-URL
  # rewrite above applies only to the default behavior's HTML routes and
  # must never touch these paths, which are real API routes, not pages.
  dynamic "ordered_cache_behavior" {
    for_each = var.api_origin_domain_name != null ? local.api_path_patterns : []

    content {
      path_pattern           = ordered_cache_behavior.value
      target_origin_id       = "lambda-run-api"
      viewer_protocol_policy = "redirect-to-https"
      compress               = true

      # POST /runs is the write path (submit_run in api/routes_runs.py); GET
      # is everything else. OPTIONS is unused (no CORS preflight — see
      # docs/code-playground-hosted-api-plan.md §1, same-origin means no
      # preflight is ever sent) but costs nothing to allow through.
      allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods  = ["GET", "HEAD"]

      cache_policy_id            = data.aws_cloudfront_cache_policy.caching_disabled[0].id
      origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer_except_host[0].id
      response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
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
  #
  # custom_error_response is distribution-wide, not per-behavior — CloudFront
  # has no per-origin equivalent — so a genuine 404 from the API origin
  # (api/routes_runs.py's get_run(), returned for an unknown or
  # not-yours job_id) gets its body swapped for this static 404.html too,
  # and cached at the edge for error_caching_min_ttl despite the /runs*
  # behavior's own CachingDisabled policy. Judged acceptable: the status
  # code itself is untouched (still 404, response_code below), which is all
  # frontend/lib/runs/client.ts actually reads on a non-ok response — it
  # never parses the body on this path — and a cached 404 for a bogus or
  # foreign job_id is harmless (a real job's input.json exists in S3 before
  # its job_id is ever returned to a caller, so a valid ID does not 404
  # and then later succeed).
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
