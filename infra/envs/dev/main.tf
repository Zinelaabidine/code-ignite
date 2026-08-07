# ---------------------------------------------------------------------------
# dev environment
#
# All environment-specific values come from terraform.tfvars (gitignored) or
# TF_VAR_* in CI — see terraform.tfvars.example. Nothing here identifies the
# project, so this file is identical across forks.
# ---------------------------------------------------------------------------

module "static_site" {
  source = "../../modules/static-site"

  providers = {
    aws.this      = aws
    aws.us_east_1 = aws.us_east_1
  }

  project_name = var.project_name
  environment  = "dev"
  aws_region   = var.aws_region

  domain_name             = local.domain_name
  hosted_zone_name        = var.hosted_zone_name
  certificate_domain_name = var.certificate_domain_name

  github_owner = var.github_owner
  github_repo  = var.github_repo

  terraform_state_bucket = local.terraform_state_bucket

  # The local-dev IAM role is account-global and shared by all environments.
  # It only exists if infra/bootstrap's local_dev_iam_users is non-empty — an
  # empty list there (the default) means no role to attach anything to. Flip
  # this to true here (and only here — attach from exactly one environment)
  # once you've added yourself to local_dev_iam_users and re-applied bootstrap.
  attach_deploy_policies_to_local_dev_role = false

  # Hardening knobs, tunable per environment.
  mfa_configuration      = var.mfa_configuration
  advanced_security_mode = var.advanced_security_mode
  enable_waf             = var.enable_waf

  # dev churns through builds; keep less history than prod.
  site_noncurrent_version_retention_days = 7
  log_retention_days                     = 30
}
