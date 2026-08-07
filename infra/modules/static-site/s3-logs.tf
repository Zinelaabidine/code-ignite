# ─────────────────────────────────────────────────────────────────────────────
# Access log bucket — CloudFront standard logs and S3 server access logs.
#
# DELIBERATE EXCEPTION TO THE "BucketOwnerEnforced EVERYWHERE" RULE (CLAUDE.md
# §6): CloudFront standard logging writes objects using an ACL grant to the AWS
# log-delivery account. It is the one AWS log producer that still cannot be
# authorised with a bucket policy, so this bucket — and only this bucket — uses
# BucketOwnerPreferred with a single explicit grant. Nothing untrusted can write
# here: the grant names one AWS-owned canonical user.
#
# The bucket holds no application data. If you would rather not run an
# ACL-enabled bucket at all, set `enable_access_logging = false` and move to
# CloudFront standard logging v2 (CloudWatch delivery), which is policy-based.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "logs" {
  count    = local.enable_logging ? 1 : 0
  provider = aws.this

  bucket = local.logs_bucket_name

  tags = {
    Name        = local.logs_bucket_name
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  count    = local.enable_logging ? 1 : 0
  provider = aws.this

  bucket = aws_s3_bucket.logs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "logs" {
  count    = local.enable_logging ? 1 : 0
  provider = aws.this

  bucket = aws_s3_bucket.logs[0].id

  rule {
    # See the header comment — required by CloudFront standard logging.
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "logs" {
  count    = local.enable_logging ? 1 : 0
  provider = aws.this

  bucket = aws_s3_bucket.logs[0].id

  access_control_policy {
    # The account that owns the bucket keeps full control.
    grant {
      grantee {
        id   = data.aws_canonical_user_id.current[0].id
        type = "CanonicalUser"
      }
      permission = "FULL_CONTROL"
    }

    # The AWS CloudFront log-delivery account, so it can write log objects.
    grant {
      grantee {
        id   = local.cloudfront_log_delivery_canonical_id
        type = "CanonicalUser"
      }
      permission = "FULL_CONTROL"
    }

    owner {
      id = data.aws_canonical_user_id.current[0].id
    }
  }

  # The ACL cannot be set until ownership controls permit ACLs at all.
  depends_on = [
    aws_s3_bucket_ownership_controls.logs,
    aws_s3_bucket_public_access_block.logs,
  ]
}

resource "aws_s3_bucket_versioning" "logs" {
  count    = local.enable_logging ? 1 : 0
  provider = aws.this

  bucket = aws_s3_bucket.logs[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  count    = local.enable_logging ? 1 : 0
  provider = aws.this

  bucket = aws_s3_bucket.logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      # SSE-KMS is not supported as a target for S3 server access logging.
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  count    = local.enable_logging ? 1 : 0
  provider = aws.this

  bucket = aws_s3_bucket.logs[0].id

  depends_on = [aws_s3_bucket_versioning.logs]

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "logs_bucket_policy" {
  count = local.enable_logging ? 1 : 0

  # S3 server access logging is policy-based (unlike CloudFront's), so the
  # logging service principal is granted here rather than through the ACL.
  statement {
    sid    = "AllowS3ServerAccessLogging"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs[0].arn}/s3-access/*"]

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.site.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.logs[0].arn,
      "${aws_s3_bucket.logs[0].arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  count    = local.enable_logging ? 1 : 0
  provider = aws.this

  bucket = aws_s3_bucket.logs[0].id
  policy = data.aws_iam_policy_document.logs_bucket_policy[0].json

  depends_on = [aws_s3_bucket_public_access_block.logs]
}
