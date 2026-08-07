# Copy to terraform.tfvars (gitignored). Shared project identity, DNS zone, GitHub,
# and AWS account live in infra/common.tfvars (via common.auto.tfvars symlink).
# Site hostname and state bucket are derived from project_name — no need to set
# domain_name or terraform_state_bucket here unless you use domain_name_override.

# ─── Hardening ────────────────────────────────────────────────────────────────

mfa_configuration      = "OFF"
advanced_security_mode = "OFF"
enable_waf             = false
