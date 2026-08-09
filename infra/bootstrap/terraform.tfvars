# Bootstrap-only values. project_name, GitHub names, region, and DNS zone live
# in infra/common.tfvars (common.auto.tfvars symlink).

github_owner_id = "24265677"
github_repo_id  = "1326972080"

create_oidc_provider = false

state_noncurrent_version_retention_days = 90

local_dev_iam_users = [
  "arn:aws:iam::886601940523:user/terraadmin",
]
