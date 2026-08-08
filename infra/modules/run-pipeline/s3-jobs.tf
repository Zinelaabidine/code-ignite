# The jobs bucket. Holds jobs/{job_id}/input.json and .../result.json — the
# only result store until there's a query S3 can't answer (see
# docs/code-playground-implementation-plan.md §8, "deliberately not doing
# yet: a database"). Private by default; nothing serves this bucket publicly,
# so unlike the static site bucket there is no CloudFront/OAC layer here —
# only the TLS-only deny in s3-jobs-policy.tf.
resource "aws_s3_bucket" "jobs" {
  provider = aws.this

  bucket = "${local.name_prefix}-jobs"

  # s3:CreateBucket is granted by the deploy-time policy created in this same
  # module (iam-deploy.tf) — wait for it to propagate before the first apply
  # tries to use it.
  depends_on = [time_sleep.run_pipeline_iam_propagation]

  # Deliberately no prevent_destroy, unlike the site bucket and Cognito pool.
  # Every object here already carries a 7-day (by default) expiry — nothing
  # in this bucket is meant to outlive that, so there is no durable state a
  # destroy could take by surprise.
  tags = {
    Name        = "${local.name_prefix}-jobs"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket_public_access_block" "jobs" {
  provider = aws.this

  bucket = aws_s3_bucket.jobs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "jobs" {
  provider = aws.this

  bucket = aws_s3_bucket.jobs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "jobs" {
  provider = aws.this

  bucket = aws_s3_bucket.jobs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Versioning is required on every bucket in this repo (see CLAUDE.md §6), even
# an ephemeral one — the lifecycle rule below expires noncurrent versions on
# the same schedule as current ones, so it costs nothing extra here.
resource "aws_s3_bucket_versioning" "jobs" {
  provider = aws.this

  bucket = aws_s3_bucket.jobs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "jobs" {
  provider = aws.this

  bucket = aws_s3_bucket.jobs.id

  depends_on = [aws_s3_bucket_versioning.jobs]

  rule {
    id     = "expire-jobs"
    status = "Enabled"

    filter {
      prefix = "jobs/"
    }

    expiration {
      days = var.jobs_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.jobs_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
