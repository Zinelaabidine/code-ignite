terraform {
  # PARTIAL BACKEND CONFIGURATION.
  #
  # `bucket` is deliberately omitted. An S3 backend block cannot interpolate
  # variables, so hardcoding the name here duplicates it across four roots and
  # lets it drift out of sync with `var.terraform_state_bucket` — which is what
  # builds the IAM grant on the state bucket. When those two disagree, every
  # `terraform init` in CI fails with AccessDenied.
  #
  # Supply it at init time instead, from a single source:
  #
  #   local:  terraform init -backend-config=backend.hcl
  #   CI:     terraform init -backend-config="bucket=$TF_STATE_BUCKET"
  #
  # See backend.hcl.example. `scripts/pre-commit-check.sh` asserts that the
  # bucket in backend.hcl matches terraform_state_bucket in terraform.tfvars.
  #
  # FIRST RUN ONLY (the bucket does not exist yet):
  #   terraform init -backend=false
  #   terraform apply -var-file=terraform.tfvars
  #   terraform init -backend-config=backend.hcl -migrate-state
  backend "s3" {
    key          = "bootstrap/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
