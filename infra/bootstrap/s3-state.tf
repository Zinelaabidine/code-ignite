# ─── Terraform Remote State ───────────────────────────────────────────────────
#
# This bucket holds the state for bootstrap AND for every environment root.
# Losing it means losing the record of everything Terraform manages, so it is
# versioned, encrypted, TLS-only, and protected against destroy unless
# decommissioning (see state_bucket_force_destroy in terraform.tfvars.example).

resource "aws_s3_bucket" "terraform_state" {
  bucket = local.terraform_state_bucket

  # Versioned state objects must be emptied before bucket delete (decommission only).
  # Apply after setting state_bucket_force_destroy = true so destroy uses force_destroy.
  force_destroy = var.state_bucket_force_destroy

  # Deleting this bucket orphans every managed resource in the account. Remove this
  # block only for intentional full decommission (see terraform.tfvars.example).
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = local.terraform_state_bucket
  }
}

resource "aws_s3_bucket_versioning" "state_versioning" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state_encryption" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state_block" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state_ownership" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Versioning is on, so every apply leaves a noncurrent state file behind. Without
# an expiry the bucket grows without bound; with one, recent history is still
# available for recovery.
resource "aws_s3_bucket_lifecycle_configuration" "state_lifecycle" {
  bucket = aws_s3_bucket.terraform_state.id

  depends_on = [aws_s3_bucket_versioning.state_versioning]

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.state_noncurrent_version_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Terraform state contains resource identifiers and, for some providers,
# secrets. Refuse any request that did not arrive over TLS.
data "aws_iam_policy_document" "terraform_state" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.terraform_state.arn,
      "${aws_s3_bucket.terraform_state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  policy = data.aws_iam_policy_document.terraform_state.json

  depends_on = [aws_s3_bucket_public_access_block.state_block]
}
