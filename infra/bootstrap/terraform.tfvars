# Bootstrap-only values. project_name, aws_account_id, GitHub, region, and DNS
# zone live in infra/common.tfvars (common.auto.tfvars symlink).

create_oidc_provider = false

state_noncurrent_version_retention_days = 90

local_dev_iam_users = [
  # "arn:aws:iam::000000000000:user/terraadmin",
]
