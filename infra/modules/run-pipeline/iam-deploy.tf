# ─────────────────────────────────────────────────────────────────────────────
# Deploy-time permissions — create/manage the queue, DLQ, jobs bucket, and the
# run-api/run-worker runtime IAM policies (iam-runtime.tf). Attached to the
# GitHub deploy role always, and to the local-dev role when
# attach_deploy_policies_to_local_dev_role is true.
#
# This is a separate managed policy from static-site's github_deploy_* ones —
# not merged into them — so the two modules stay independently composable:
# a fork that drops run-pipeline loses exactly this policy and nothing else.
#
# Mirrors the split rationale in static-site/iam-github-oidc.tf: permissions
# live in their own policy per concern rather than one inline policy, and the
# same chicken-and-egg problem applies (the role needs this policy attached
# before it can create the resources it authorizes) — deploy.yml applies this
# module's IAM resources with -target before the rest, same as it does for
# static_site.
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "github_deploy_run_pipeline_policy" {

  # ─── SQS ───────────────────────────────────────────────────────────────────

  # Resources are built by name (local.runs_queue_arn / local.runs_dlq_arn),
  # not read from aws_sqs_queue.runs.arn / aws_sqs_queue.runs_dlq.arn.
  # Referencing the real resource attributes here would make this policy
  # document depend on the queues, while the queues themselves depend_on this
  # policy's propagation sleep for permission to be created — a cycle
  # Terraform refuses to plan. The queue and topic names are chosen by this
  # module, not assigned by AWS, so the ARN is fully knowable in advance.
  statement {
    sid    = "SQSQueueManage"
    effect = "Allow"
    actions = [
      "sqs:CreateQueue",
      "sqs:DeleteQueue",
      "sqs:GetQueueAttributes",
      "sqs:SetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:TagQueue",
      "sqs:UntagQueue",
      "sqs:ListQueueTags",
    ]
    resources = [
      local.runs_queue_arn,
      local.runs_dlq_arn,
    ]
  }

  # ─── S3 (bucket management only — no object-level access; that's
  # iam-runtime.tf's concern) ──────────────────────────────────────────────────

  # Same reasoning as SQSQueueManage above: built from local.jobs_bucket_arn,
  # not aws_s3_bucket.jobs.arn, to avoid a cycle through the bucket's own
  # depends_on of this policy's propagation sleep.
  statement {
    sid    = "S3JobsBucketManage"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:GetBucketVersioning",
      "s3:PutBucketVersioning",
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketPublicAccessBlock",
      "s3:GetBucketOwnershipControls",
      "s3:PutBucketOwnershipControls",
      "s3:GetEncryptionConfiguration",
      "s3:PutEncryptionConfiguration",
      "s3:GetBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:GetBucketTagging",
      "s3:PutBucketTagging",
      "s3:GetLifecycleConfiguration",
      "s3:PutLifecycleConfiguration",
    ]
    resources = [local.jobs_bucket_arn]
  }

  # ─── IAM — the run-api / run-worker managed policies ───────────────────────

  # Policy IDs/versions are not knowable before CreatePolicy runs, so this is
  # scoped to the name prefix rather than an exact ARN — the same pattern
  # static-site's IAMManagedPoliciesWrite uses for its own deploy policies.
  statement {
    sid    = "IAMRuntimePoliciesManage"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:policy/${local.name_prefix}-run-*",
    ]
  }

  # Only needed when there is a local-dev role to attach the runtime policies
  # to (attach_runtime_policies_to_local_dev_role) — the GitHub deploy role
  # itself never runs the API or worker, so it never needs these actions
  # against its own role.
  dynamic "statement" {
    for_each = length(data.aws_iam_role.local_dev_role) > 0 ? [1] : []

    content {
      sid    = "IAMRuntimePoliciesAttachToLocalDev"
      effect = "Allow"
      actions = [
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:ListAttachedRolePolicies",
      ]
      resources = [data.aws_iam_role.local_dev_role[0].arn]
    }
  }
}

resource "aws_iam_policy" "github_deploy_run_pipeline_policy" {
  provider = aws.this

  name        = "${local.name_prefix}-github-deploy-run-pipeline-policy"
  description = "SQS queue/DLQ, jobs bucket, and runtime IAM policy management for the GitHub and local-dev roles"
  policy      = data.aws_iam_policy_document.github_deploy_run_pipeline_policy.json

  tags = {
    Name        = "${local.name_prefix}-github-deploy-run-pipeline-policy"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

resource "aws_iam_role_policy_attachment" "github_deploy_run_pipeline" {
  provider = aws.this

  role       = data.aws_iam_role.github_oidc_deploy_role.name
  policy_arn = aws_iam_policy.github_deploy_run_pipeline_policy.arn
}

resource "aws_iam_role_policy_attachment" "local_dev_run_pipeline_deploy" {
  count    = var.attach_deploy_policies_to_local_dev_role ? 1 : 0
  provider = aws.this

  role       = data.aws_iam_role.local_dev_role[0].name
  policy_arn = aws_iam_policy.github_deploy_run_pipeline_policy.arn
}

# Same propagation gate as static-site's iam_propagation: any resource whose
# create permission lives in this policy must depend_on this sleep, and the
# triggers map re-fires it on policy changes, not just first create.
resource "time_sleep" "run_pipeline_iam_propagation" {
  create_duration = "15s"

  triggers = {
    policy_hash = sha256(aws_iam_policy.github_deploy_run_pipeline_policy.policy)
  }

  depends_on = [aws_iam_role_policy_attachment.github_deploy_run_pipeline]
}
