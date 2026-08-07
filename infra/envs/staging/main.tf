# ---------------------------------------------------------------------------
# staging environment — mirrors prod configuration.
#
# All environment-specific values come from terraform.tfvars (gitignored) or
# TF_VAR_* in CI — see terraform.tfvars.example.
# ---------------------------------------------------------------------------

module "static_site" {
  source = "../../modules/static-site"

  providers = {
    aws.this      = aws
    aws.us_east_1 = aws.us_east_1
  }

  project_name = var.project_name
  environment  = "staging"
  aws_region   = var.aws_region

  domain_name             = var.domain_name
  hosted_zone_name        = var.hosted_zone_name
  certificate_domain_name = var.certificate_domain_name

  github_owner = var.github_owner
  github_repo  = var.github_repo

  terraform_state_bucket = var.terraform_state_bucket

  mfa_configuration      = var.mfa_configuration
  advanced_security_mode = var.advanced_security_mode
  enable_waf             = var.enable_waf

  site_noncurrent_version_retention_days = 30
  log_retention_days                     = 90
}
