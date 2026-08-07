# Copy to backend.hcl (gitignored) and set the state bucket name.
#
#   terraform init -backend-config=backend.hcl
#
# This value MUST equal `terraform_state_bucket` in terraform.tfvars — the
# former tells Terraform where state lives, the latter tells IAM which bucket
# the deploy roles may read and write.

bucket = "apptemplate-terraform-state-886601940523"
