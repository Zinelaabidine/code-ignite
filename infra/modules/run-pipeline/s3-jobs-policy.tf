data "aws_iam_policy_document" "jobs_bucket_policy" {
  # Refuse anything that did not arrive over TLS. Covers the API's and
  # worker's own reads/writes as well as anyone else's.
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.jobs.arn,
      "${aws_s3_bucket.jobs.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "jobs" {
  provider = aws.this

  bucket = aws_s3_bucket.jobs.id
  policy = data.aws_iam_policy_document.jobs_bucket_policy.json

  # A bucket policy can trip the "public policy" heuristic if it lands before
  # the public access block does — same ordering static-site's s3-policy.tf
  # uses for the site bucket.
  depends_on = [aws_s3_bucket_public_access_block.jobs]
}
