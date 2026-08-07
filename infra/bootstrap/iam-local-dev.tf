# ─── Local Developer Role ─────────────────────────────────────────────────────
#
# Used by local IAM users running Terraform on workstations. Never referenced in
# the GitHub deploy trust policy. The app module attaches the same deploy
# managed policies to it (from whichever environment sets
# `attach_deploy_policies_to_local_dev_role`), so this role carries the full
# deploy blast radius.
#
# Because of that blast radius, assuming it requires MFA. A leaked long-lived
# access key alone is not enough.
#
# The role is only created when `local_dev_iam_users` is non-empty: IAM rejects
# a trust policy whose principal list is empty, so the default of `[]` would
# otherwise fail the very first apply.

data "aws_iam_policy_document" "local_dev_trust" {
  count = local.create_local_dev_role ? 1 : 0

  statement {
    sid     = "AllowLocalIAMUsersWithMFA"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "AWS"
      # Explicit user/role ARNs only. Wildcards (e.g. arn:aws:iam::*:root) are
      # intentionally disallowed — see the validation on the variable.
      identifiers = var.local_dev_iam_users
    }

    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }

    # Reject a session that MFA'd hours ago; force a recent second factor.
    condition {
      test     = "NumericLessThan"
      variable = "aws:MultiFactorAuthAge"
      values   = ["3600"]
    }
  }
}

resource "aws_iam_role" "local_dev" {
  count = local.create_local_dev_role ? 1 : 0

  name        = "${var.project_name}-local-dev-role"
  description = "Assumed by local developers running Terraform (MFA required). Not used by GitHub Actions."

  assume_role_policy   = data.aws_iam_policy_document.local_dev_trust[0].json
  max_session_duration = 3600

  tags = {
    Name = "${var.project_name}-local-dev-role"
  }
}
