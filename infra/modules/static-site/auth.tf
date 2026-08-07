# Cognito User Pool — the only identity store in this template. The frontend
# talks to it directly through Amplify; there is no backend API in between.
resource "aws_cognito_user_pool" "this" {
  provider = aws.this

  name = "${local.name_prefix}-user-pool"

  # Self-service sign-up confirms the address with an emailed code before the
  # account becomes usable.
  auto_verified_attributes = ["email"]
  username_attributes      = ["email"]

  # Deleting a pool destroys every registered account and cannot be undone.
  # Guarded twice: AWS-side (this) and Terraform-side (the lifecycle block).
  deletion_protection = var.cognito_deletion_protection

  password_policy {
    minimum_length                   = var.password_minimum_length
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = true
    require_uppercase                = true
    temporary_password_validity_days = 3
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # OFF, ON, or OPTIONAL. TOTP only — SMS is the weakest second factor and adds
  # a per-message cost and an SNS role to manage.
  mfa_configuration = var.mfa_configuration

  dynamic "software_token_mfa_configuration" {
    for_each = var.mfa_configuration == "OFF" ? [] : [1]

    content {
      enabled = true
    }
  }

  # Threat protection: compromised-credential detection and adaptive auth.
  # Billed per monthly active user, hence off by default.
  dynamic "user_pool_add_ons" {
    for_each = var.advanced_security_mode == "OFF" ? [] : [1]

    content {
      advanced_security_mode = var.advanced_security_mode
    }
  }

  admin_create_user_config {
    # This template is self-service sign-up; admins do not pre-create accounts.
    allow_admin_create_user_only = false
  }

  # The deploy role gains cognito-idp:CreateUserPool from the core managed
  # policy; wait for that grant to propagate before the first create.
  depends_on = [time_sleep.iam_propagation]

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = "${local.name_prefix}-user-pool"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

resource "aws_cognito_user_pool_client" "this" {
  provider = aws.this

  name         = "${local.name_prefix}-user-pool-client"
  user_pool_id = aws_cognito_user_pool.this.id

  # Public SPA client — a secret cannot be kept confidential in a browser and
  # Amplify's SRP flow does not need one.
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  supported_identity_providers = ["COGNITO"]

  # Tokens live in browser storage, so they are bearer credentials for exactly
  # as long as these windows allow. AWS defaults to 30 days for refresh tokens;
  # that is a long time to hold a key to an account.
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  access_token_validity  = var.access_token_validity_minutes
  id_token_validity      = var.id_token_validity_minutes
  refresh_token_validity = var.refresh_token_validity_days

  # Issue a new refresh token on every refresh so a stolen one has a short
  # useful life and reuse is detectable.
  enable_token_revocation = true

  # Do not leak whether an address is registered on failed sign-in.
  prevent_user_existence_errors = "ENABLED"

  # The client may read and update the user's own email, and nothing else.
  # Left unset, Cognito grants the client every attribute.
  read_attributes  = ["email", "email_verified"]
  write_attributes = ["email"]
}
