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

  domain_name             = local.domain_name
  hosted_zone_name        = var.hosted_zone_name
  certificate_domain_name = var.certificate_domain_name

  github_owner = var.github_owner
  github_repo  = var.github_repo

  terraform_state_bucket = local.terraform_state_bucket

  mfa_configuration      = var.mfa_configuration
  advanced_security_mode = var.advanced_security_mode
  enable_waf             = var.enable_waf

  # Keep more history in prod: a bad deploy is recoverable from a noncurrent
  # version, and access logs are the only forensic record there is.
  site_noncurrent_version_retention_days = 90
  log_retention_days                     = 365

  cognito_deletion_protection = "ACTIVE"

  # Code-playground API origin — same CloudFront /runs* + /healthz wiring as
  # dev (docs/code-playground-hosted-api-plan.md). Terraform orders
  # module.run_api before this module from these references.
  api_origin_domain_name       = module.run_api.function_url_domain_name
  api_origin_access_control_id = module.run_api.origin_access_control_id
}

# Code playground run pipeline: SQS + jobs bucket + runtime IAM. Worker stays
# on a developer's machine (never in AWS); attach_runtime_policies lets that
# local process drain this env's queue. Deploy-policy attachment stays off —
# exactly one environment owns local-dev deploy grants (conventionally dev).
module "run_pipeline" {
  source = "../../modules/run-pipeline"

  providers = {
    aws.this = aws
  }

  project_name = var.project_name
  environment  = "prod"
  aws_region   = var.aws_region

  attach_deploy_policies_to_local_dev_role  = false
  attach_runtime_policies_to_local_dev_role = true
}

# Hosted API: zip-packaged Lambda behind CloudFront OAC. See
# docs/code-playground-hosted-api-plan.md.
module "run_api" {
  source = "../../modules/run-api"

  providers = {
    aws.this = aws
  }

  project_name = var.project_name
  environment  = "prod"
  aws_region   = var.aws_region

  attach_deploy_policies_to_local_dev_role = false

  aws_region_for_app   = var.aws_region
  jobs_bucket_name     = module.run_pipeline.jobs_bucket_name
  runs_queue_url       = module.run_pipeline.runs_queue_url
  cognito_user_pool_id = module.static_site.cognito_user_pool_id
  cognito_client_id    = module.static_site.cognito_client_id
  run_api_policy_arn   = module.run_pipeline.run_api_policy_arn
}
