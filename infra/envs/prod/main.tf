# ---------------------------------------------------------------------------
# prod environment.
#
# The site bucket and the Cognito User Pool carry `lifecycle { prevent_destroy
# = true }` inside the module, and the pool additionally has AWS-side deletion
# protection. Both are on in every environment, not just here — a template that
# tells you to remember something before the first prod apply is a template that
# will eventually be forgotten.
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
  environment  = "prod"
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

  # Keep more history in prod: a bad deploy is recoverable from a noncurrent
  # version, and access logs are the only forensic record there is.
  site_noncurrent_version_retention_days = 90
  log_retention_days                     = 365

  cognito_deletion_protection = "ACTIVE"
}
