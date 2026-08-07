locals {
  name_prefix      = "${var.project_name}-${var.environment}"
  github_repo_full = "${var.github_owner}/${var.github_repo}"
  account_id       = data.aws_caller_identity.current.account_id

  # S3 bucket names are globally unique, so the site domain — itself already
  # unique — is the natural source. Changing this renames (and therefore
  # replaces) the bucket, which `prevent_destroy` in s3.tf will refuse.
  bucket_name = replace(var.domain_name, ".", "-")
  logs_bucket_name = substr(
    "${replace(var.domain_name, ".", "-")}-logs",
    0,
    63,
  )

  enable_logging = var.enable_access_logging

  # Canonical user ID of the AWS account CloudFront uses to deliver standard
  # access logs. Fixed and documented by AWS; it is the same in every partition
  # region and is the only way to grant CloudFront write access to a log bucket.
  cloudfront_log_delivery_canonical_id = "c4c1ede66af53448b93c283ce9448c4ba468c9432aa01d700d3878632f77d2d0"

  # Headers CloudFront has no first-class field for.
  custom_response_headers = {
    # Deny the browser access to hardware and ambient APIs this app never uses.
    "Permissions-Policy"                = "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=(), interest-cohort=()"
    "Cross-Origin-Opener-Policy"        = "same-origin"
    "Cross-Origin-Resource-Policy"      = "same-origin"
    "X-Permitted-Cross-Domain-Policies" = "none"
  }
}
