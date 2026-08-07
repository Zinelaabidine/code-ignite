# ─────────────────────────────────────────────────────────────────────────────
# Security response headers.
#
# NO CONTENT-SECURITY-POLICY IS SENT. It was removed deliberately: Next.js
# App Router inlines its React Flight payload into every exported HTML file,
# which a strict `script-src 'self'` blocks, and keeping the two in sync would
# have coupled the CSP to every frontend build.
#
# Understand the exposure before relying on this: Amplify stores the Cognito
# ID, access and refresh tokens in cookies the page's own JavaScript can read,
# and there is no backend to fall back on — the browser holds the only
# credentials. Without a CSP, any script that executes on this origin (an XSS
# bug, a compromised dependency) can read those tokens. The headers below do
# not cover that; they address framing, MIME sniffing and referrer leakage
# only. If that trade stops being acceptable, the policy string and its
# variables are in this file's git history.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cloudfront_response_headers_policy" "security" {
  provider = aws.this

  name    = "${local.name_prefix}-security-headers"
  comment = "Security headers for ${var.domain_name}"

  security_headers_config {
    # Two years, subdomains included, preload-eligible.
    strict_transport_security {
      access_control_max_age_sec = 63072000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }

    # Stop the browser MIME-sniffing a response into something executable.
    content_type_options {
      override = true
    }

    # The only clickjacking control now that the CSP (and its frame-ancestors
    # directive) is gone.
    frame_options {
      frame_option = "DENY"
      override     = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    xss_protection {
      # Explicitly off: the legacy XSS auditor is deprecated and its filtering
      # mode introduced vulnerabilities of its own. Modern browsers ignore it.
      protection = false
      mode_block = false
      override   = true
    }
  }

  custom_headers_config {
    dynamic "items" {
      for_each = local.custom_response_headers

      content {
        header   = items.key
        value    = items.value
        override = true
      }
    }
  }

  # Hide origin implementation details from viewers.
  remove_headers_config {
    items {
      header = "x-amz-server-side-encryption"
    }
    items {
      header = "x-amz-version-id"
    }
    items {
      header = "Server"
    }
  }
}
