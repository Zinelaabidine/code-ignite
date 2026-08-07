# Copy to terraform.tfvars (gitignored) and fill in.
#
# aws_region, project_name, github_owner, github_repo, and
# terraform_state_bucket live in infra/common.tfvars; hosted_zone_name and
# certificate_domain_name live in infra/common-domain.tfvars. Both are loaded
# automatically here via the common.auto.tfvars and common-domain.auto.tfvars
# symlinks. Only this environment's domain and hardening knobs stay here.
#
# terraform_state_bucket (in common.tfvars) MUST equal the `bucket` in
# backend.hcl (infra/common-backend.hcl, also symlinked in) —
# scripts/pre-commit-check.sh asserts that they match.

domain_name = "apptemplate-dev.openspacenexus.store"

# ─── Hardening ────────────────────────────────────────────────────────────────

# Cognito MFA (TOTP): OFF | OPTIONAL | ON
mfa_configuration = "OFF"

# Cognito threat protection: OFF | AUDIT | ENFORCED.
# AUDIT and ENFORCED are billed per monthly active user.
advanced_security_mode = "OFF"

# WAF managed rules + per-IP rate limiting on CloudFront. Billed per web ACL,
# per rule, and per million requests.
enable_waf = false
