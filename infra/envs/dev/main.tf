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

  # The code-playground API's CloudFront origin — see
  # docs/code-playground-hosted-api-plan.md. Both null until module.run_api
  # exists below; Terraform infers the apply order (run_api before
  # static_site) from these references.
  api_origin_domain_name       = module.run_api.function_url_domain_name
  api_origin_access_control_id = module.run_api.origin_access_control_id
}

# Code playground run pipeline: SQS queue + DLQ, jobs S3 bucket, and the
# run-api / run-worker runtime IAM policies. See
# docs/code-playground-implementation-plan.md stage 2. Not yet wired into
# staging or prod — dev is where the API and worker actually run in phase 1
# (docs/code-playground-plan.md is local-first).
module "run_pipeline" {
  source = "../../modules/run-pipeline"

  providers = {
    aws.this = aws
  }

  project_name = var.project_name
  environment  = "dev"
  aws_region   = var.aws_region

  # Same account-global-role caveat as static_site above, and off for the
  # same reason: this only works once you've added yourself to
  # local_dev_iam_users in infra/bootstrap and re-applied it. Flip to true
  # here (and only here) once that's done — this lets you `terraform apply`
  # this module locally.
  attach_deploy_policies_to_local_dev_role = false

  # On: the worker runs on a developer's own machine against this real
  # queue and bucket, per docs/code-playground-hosted-api-plan.md — there is
  # no worker anywhere in AWS to grant this to instead. Requires the same
  # local_dev_iam_users prerequisite as the flag above.
  attach_runtime_policies_to_local_dev_role = true
}

# Code playground API, hosted: a Lambda running api/app.py unmodified behind
# a CloudFront-OAC-protected Function URL. The worker is deliberately not
# here — it stays on a developer's machine, reading the queue/bucket above
# via the local-dev role. See docs/code-playground-hosted-api-plan.md for
# why (no AWS compute runs untrusted code) and §4 for this module's shape.
module "run_api" {
  source = "../../modules/run-api"

  providers = {
    aws.this = aws
  }

  project_name = var.project_name
  environment  = "dev"
  aws_region   = var.aws_region

  # Same account-global-role caveat as the modules above.
  attach_deploy_policies_to_local_dev_role = false

  aws_region_for_app   = var.aws_region
  jobs_bucket_name     = module.run_pipeline.jobs_bucket_name
  runs_queue_url       = module.run_pipeline.runs_queue_url
  cognito_user_pool_id = module.static_site.cognito_user_pool_id
  cognito_client_id    = module.static_site.cognito_client_id
  run_api_policy_arn   = module.run_pipeline.run_api_policy_arn

  # Set by deploy.yml (TF_VAR_backend_image_tag) to the commit SHA it just
  # built and pushed to this module's ECR repository. The default only
  # matters before the first image has ever been pushed — CreateFunction
  # will fail against it, which is the point: it forces an explicit,
  # deliberate first image push rather than silently deploying a
  # function that references nothing.
  image_tag = var.backend_image_tag
}
