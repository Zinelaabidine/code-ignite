# Static site bucket. Private by default — reachable only through CloudFront
# via the Origin Access Control policy in s3-policy.tf.
resource "aws_s3_bucket" "site" {
  provider = aws.this

  bucket = local.bucket_name

  # The bucket name derives from the site domain, so renaming the domain would
  # otherwise silently destroy and recreate this bucket (and everything in it)
  # in a single apply. Make that an error instead.
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = local.bucket_name
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket_public_access_block" "site" {
  provider = aws.this

  bucket = aws_s3_bucket.site.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "site" {
  provider = aws.this

  bucket = aws_s3_bucket.site.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "site" {
  provider = aws.this

  bucket = aws_s3_bucket.site.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  provider = aws.this

  bucket = aws_s3_bucket.site.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Every deploy runs `aws s3 sync --delete`, which turns the previous build into
# noncurrent versions and delete markers. Without an expiry rule the bucket
# accumulates every build ever shipped.
resource "aws_s3_bucket_lifecycle_configuration" "site" {
  provider = aws.this

  bucket = aws_s3_bucket.site.id

  depends_on = [aws_s3_bucket_versioning.site]

  rule {
    id     = "expire-noncurrent-site-objects"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.site_noncurrent_version_retention_days
    }

    expiration {
      expired_object_delete_marker = true
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# S3 server access logs complement CloudFront's: they record requests that
# reached the origin, which is how you notice something bypassing the CDN.
resource "aws_s3_bucket_logging" "site" {
  count    = local.enable_logging ? 1 : 0
  provider = aws.this

  bucket = aws_s3_bucket.site.id

  target_bucket = aws_s3_bucket.logs[0].id
  target_prefix = "s3-access/"
}
