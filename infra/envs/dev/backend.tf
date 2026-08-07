terraform {
  # PARTIAL BACKEND CONFIGURATION — see infra/bootstrap/backend.tf for the
  # reasoning. In short: an S3 backend block cannot read variables, so
  # hardcoding the bucket here lets it drift out of sync with
  # `terraform_state_bucket`, which is what builds the IAM grant on that
  # bucket. When the two disagree, every `terraform init` in CI fails with
  # AccessDenied — which is exactly the bug this template shipped with.
  #
  #   local:  terraform init -backend-config=backend.hcl
  #   CI:     terraform init -backend-config="bucket=$TF_STATE_BUCKET"
  backend "s3" {
    key          = "dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
