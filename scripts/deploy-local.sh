#!/usr/bin/env bash
# deploy-local.sh — run the same job as .github/workflows/deploy.yml, locally,
# with no GitHub Actions involved.
#
#   ./scripts/deploy-local.sh <dev|staging|prod> [options]
#
# Mirrors deploy.yml step for step:
#   1. ci checks       (ci.yml: frontend lint/typecheck/test/build, terraform
#                        fmt/validate/lockfiles, IaC + secret scan, npm audit)
#   2. terraform apply (targeted IAM policies → ECR repo → Lambda image push →
#                        full plan → destructive-plan guard → apply)
#   3. frontend build  (Cognito IDs baked in from terraform output)
#   4. S3 sync + CloudFront invalidation + prune
#
# The worker image is never built or deployed here — it runs on a developer's
# own machine, never in AWS (see docs/code-playground-hosted-api-plan.md §0).
# Only backend/Dockerfile.lambda is pushed to module.run_api's ECR, tagged with
# the current git SHA (same as TF_VAR_backend_image_tag in deploy.yml).
#
# Authentication is whatever `aws` already resolves in your shell (profile,
# env vars, SSO, or an assumed local-dev-role — see --assume-role below). This
# script never manages credentials for you; it only shows you the identity it
# is about to deploy with and asks you to confirm.
#
# Usage:
#   ./scripts/deploy-local.sh dev
#   ./scripts/deploy-local.sh prod --frontend-only
#   ./scripts/deploy-local.sh staging --profile my-sso-profile
#
# Options:
#   --frontend-only       Skip terraform; only build + deploy the frontend.
#   --infra-only          Skip the frontend; only run terraform apply.
#   --skip-checks         Skip the ci.yml-equivalent checks (not recommended).
#   --skip-security       Skip the IaC/secret scan + npm audit (not recommended).
#   --skip-backend-image  Skip ECR apply + Lambda image build/push (infra still
#                          plans/applies; image_tag stays at its prior value
#                          unless you export TF_VAR_backend_image_tag yourself).
#   --allow-destroy       Permit a terraform plan that deletes/replaces resources.
#   --yes                 Skip interactive confirmations (still shown, not asked).
#   --profile <name>      AWS CLI profile to use for this run.
#   --assume-role <arn>   STS-assume this role before doing anything else
#                          (e.g. the project's <project>-local-dev-role). Add
#                          --mfa-serial if the role's trust policy requires MFA.
#   --mfa-serial <arn>    MFA device ARN, used with --assume-role.
#   -h, --help             Show this help.
#
# Optional env (mirrors deploy.yml vars.API_BASE_URL):
#   API_BASE_URL / NEXT_PUBLIC_API_BASE_URL — baked into the frontend build.
#   Unset leaves the playground's "not available" path (see frontend/lib/env.ts).
#
# PROD SAFETY: deploying to prod always requires typing "prod" to confirm,
# even with --yes. There is no flag that skips it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

step() { echo -e "\n${BLUE}==> $1${NC}"; }
pass() { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}! $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}" >&2; exit 1; }

# Use frontend/.nvmrc in this shell when the active node is too old (nvm, fnm, volta).
ensure_project_node_version() {
  local nvmrc_path="frontend/.nvmrc"
  [[ -f "$nvmrc_path" ]] || return 0

  local required_major
  required_major="$(tr -dc '0-9' < "$nvmrc_path")"
  [[ -n "$required_major" ]] || return 0

  local current_major
  current_major="$(node -e 'console.log(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)"
  if [[ "$current_major" -ge "$required_major" ]]; then
    return 0
  fi

  local before
  before="$(node -v 2>/dev/null || echo unknown)"

  if [[ -z "${NVM_DIR:-}" ]]; then
    export NVM_DIR="${HOME}/.nvm"
  fi
  if [[ -s "${NVM_DIR}/nvm.sh" ]]; then
    # shellcheck disable=SC1090
    . "${NVM_DIR}/nvm.sh"
    if nvm use "$required_major" >/dev/null 2>&1; then
      pass "Node $before → $(node -v) (nvm, frontend/.nvmrc)"
      return 0
    fi
    if nvm install "$required_major" >/dev/null 2>&1 && nvm use "$required_major" >/dev/null 2>&1; then
      pass "Node $before → $(node -v) (nvm install, frontend/.nvmrc)"
      return 0
    fi
  fi

  if command -v fnm >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    eval "$(fnm env --shell bash)"
    if ( cd frontend && fnm use --install-if-missing ); then
      pass "Node $before → $(node -v) (fnm, frontend/.nvmrc)"
      return 0
    fi
  fi

  if command -v volta >/dev/null 2>&1; then
    if ( cd frontend && volta install "node@${required_major}" >/dev/null 2>&1 ); then
      pass "Node $before → $(node -v) (volta, frontend/.nvmrc)"
      return 0
    fi
  fi

  fail "Node $(node -v) is too old — this project requires Node >=$required_major (see frontend/.nvmrc). Install it (e.g. nvm install $required_major) or activate it in this shell, then re-run."
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is not installed or not on PATH"
}

usage() {
  sed -n '2,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

# ─── Parse arguments ──────────────────────────────────────────────────────────

ENVIRONMENT=""
FRONTEND_ONLY=false
INFRA_ONLY=false
SKIP_CHECKS=false
SKIP_SECURITY=false
SKIP_BACKEND_IMAGE=false
ALLOW_DESTROY=false
AUTO_YES=false
AWS_PROFILE_ARG=""
ASSUME_ROLE_ARN=""
MFA_SERIAL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    dev|staging|prod)
      [[ -n "$ENVIRONMENT" ]] && fail "environment given twice: '$ENVIRONMENT' and '$1'"
      ENVIRONMENT="$1"
      shift
      ;;
    --frontend-only) FRONTEND_ONLY=true; shift ;;
    --infra-only) INFRA_ONLY=true; shift ;;
    --skip-checks) SKIP_CHECKS=true; shift ;;
    --skip-security) SKIP_SECURITY=true; shift ;;
    --skip-backend-image) SKIP_BACKEND_IMAGE=true; shift ;;
    --allow-destroy) ALLOW_DESTROY=true; shift ;;
    --yes) AUTO_YES=true; shift ;;
    --profile) AWS_PROFILE_ARG="${2:-}"; [[ -n "$AWS_PROFILE_ARG" ]] || fail "--profile requires a value"; shift 2 ;;
    --assume-role) ASSUME_ROLE_ARN="${2:-}"; [[ -n "$ASSUME_ROLE_ARN" ]] || fail "--assume-role requires a value"; shift 2 ;;
    --mfa-serial) MFA_SERIAL="${2:-}"; [[ -n "$MFA_SERIAL" ]] || fail "--mfa-serial requires a value"; shift 2 ;;
    -h|--help) usage ;;
    *) fail "unknown argument: $1 (--help for usage)" ;;
  esac
done

[[ -n "$ENVIRONMENT" ]] || fail "missing environment: dev | staging | prod (--help for usage)"
if [[ "$FRONTEND_ONLY" == true && "$INFRA_ONLY" == true ]]; then
  fail "--frontend-only and --infra-only are mutually exclusive"
fi

TF_DIR="infra/envs/$ENVIRONMENT"
DEPLOY_INFRA=true
DEPLOY_FRONTEND=true
[[ "$FRONTEND_ONLY" == true ]] && DEPLOY_INFRA=false
[[ "$INFRA_ONLY" == true ]] && DEPLOY_FRONTEND=false

echo -e "${BOLD}Target environment: $ENVIRONMENT  ($TF_DIR)${NC}"

# ─── Pre-flight ───────────────────────────────────────────────────────────────

step "checking required tools"
require_cmd terraform
require_cmd node
require_cmd npm
require_cmd aws
require_cmd jq
if ! command -v trivy >/dev/null 2>&1; then
  if [[ "$SKIP_SECURITY" == true ]]; then
    warn "trivy not installed — security scan will be skipped (--skip-security)"
  else
    fail "trivy is not installed. Install it (e.g. 'brew install trivy') or re-run with --skip-security to proceed without the IaC/secret scan."
  fi
fi
# frontend/package.json pins "engines": { "node": ">=24" } (see frontend/.nvmrc).
# Below that, vite/vitest's ESM build fails with a cryptic ERR_REQUIRE_ESM deep
# inside `npm run test` instead of a clear version error — activate .nvmrc here.
ensure_project_node_version

pass "required tools present"

[[ -f "$TF_DIR/terraform.tfvars" ]] || fail "$TF_DIR/terraform.tfvars is missing. cp $TF_DIR/terraform.tfvars.example $TF_DIR/terraform.tfvars and fill it in."
[[ -f "$TF_DIR/common.auto.tfvars" ]] || fail "$TF_DIR/common.auto.tfvars is missing. It should be a symlink to infra/common.tfvars — see infra/common.tfvars.example."
[[ -f "infra/common.tfvars" ]] || fail "infra/common.tfvars is missing. cp infra/common.tfvars.example infra/common.tfvars and fill it in."

# ─── AWS authentication ───────────────────────────────────────────────────────

if [[ -n "$AWS_PROFILE_ARG" ]]; then
  export AWS_PROFILE="$AWS_PROFILE_ARG"
fi

assume_deploy_role() {
  [[ -n "$ASSUME_ROLE_ARN" ]] || return 0
  local session_name="${1:-local-deploy-$(date +%s)}"
  step "assuming role $ASSUME_ROLE_ARN ($session_name)"
  local assume_args=(--role-arn "$ASSUME_ROLE_ARN" --role-session-name "$session_name" --duration-seconds 3600)
  if [[ -n "$MFA_SERIAL" ]]; then
    local MFA_CODE
    read -rp "MFA token code for $MFA_SERIAL: " MFA_CODE
    assume_args+=(--serial-number "$MFA_SERIAL" --token-code "$MFA_CODE")
  fi
  local creds_json
  creds_json="$(aws sts assume-role "${assume_args[@]}" --output json)" \
    || fail "sts assume-role failed"
  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  export AWS_SESSION_TOKEN
  AWS_ACCESS_KEY_ID="$(jq -r '.Credentials.AccessKeyId' <<<"$creds_json")"
  AWS_SECRET_ACCESS_KEY="$(jq -r '.Credentials.SecretAccessKey' <<<"$creds_json")"
  AWS_SESSION_TOKEN="$(jq -r '.Credentials.SessionToken' <<<"$creds_json")"
  unset AWS_PROFILE
  pass "assumed role, session valid until $(jq -r '.Credentials.Expiration' <<<"$creds_json")"
}

assume_deploy_role "local-deploy-$(date +%s)"

step "AWS identity"
CALLER_JSON="$(aws sts get-caller-identity --output json)" \
  || fail "no valid AWS credentials. Configure a profile (--profile), assume a role (--assume-role), or run 'aws configure' / 'aws sso login' first."
echo "$CALLER_JSON" | jq .
CALLER_ACCOUNT="$(jq -r '.Account' <<<"$CALLER_JSON")"

# aws_region lives in infra/common.tfvars now (shared across every root via
# the common.auto.tfvars symlink), not in $TF_DIR/terraform.tfvars.
# [[:space:]] rather than \s: BSD sed (macOS's /usr/bin/sed) doesn't support
# \s in -E mode, so it silently fails to match and prints the whole line back.
AWS_REGION_VAL="$(grep -E '^[[:space:]]*aws_region[[:space:]]*=' "infra/common.tfvars" | head -1 | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')"
AWS_REGION_VAL="${AWS_REGION_VAL:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION_VAL"
export AWS_REGION="$AWS_REGION_VAL"

# Same tag deploy.yml uses (github.sha) — must exist in ECR before the
# untargeted apply creates/updates aws_lambda_function.api. When
# --skip-backend-image, leave TF_VAR alone unless the caller already set it;
# otherwise resolve the prior tag from state after terraform init (below).
IMAGE_TAG="$(git rev-parse HEAD)"
if [[ "$SKIP_BACKEND_IMAGE" != true ]]; then
  export TF_VAR_backend_image_tag="${TF_VAR_backend_image_tag:-$IMAGE_TAG}"
fi

# Optional frontend API URL (deploy.yml: vars.API_BASE_URL). Prefer an
# explicit NEXT_PUBLIC_* if the caller already set one.
API_BASE_URL_VAL="${NEXT_PUBLIC_API_BASE_URL:-${API_BASE_URL:-}}"

echo ""
if [[ "$AUTO_YES" != true ]]; then
  read -rp "Deploying to '$ENVIRONMENT' in AWS account $CALLER_ACCOUNT as the identity above. Continue? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || fail "aborted"
fi
if [[ "$ENVIRONMENT" == "prod" ]]; then
  read -rp "This targets PRODUCTION. Type 'prod' to confirm: " prod_confirm
  [[ "$prod_confirm" == "prod" ]] || fail "aborted — confirmation text did not match"
fi

# docker is only required when we will push the Lambda image.
if [[ "$DEPLOY_INFRA" == true && "$SKIP_BACKEND_IMAGE" != true ]]; then
  require_cmd docker
fi

# ─── Checks (mirrors ci.yml) ──────────────────────────────────────────────────

step "installing frontend dependencies"
(cd frontend && npm ci)

if [[ "$SKIP_CHECKS" == true ]]; then
  warn "skipping ci.yml-equivalent checks (--skip-checks)"
else
  step "frontend + terraform checks (scripts/pre-commit-check.sh)"
  ./scripts/pre-commit-check.sh
fi

if [[ "$SKIP_SECURITY" == true ]]; then
  warn "skipping security scan (--skip-security)"
elif command -v trivy >/dev/null 2>&1; then
  step "IaC misconfiguration scan (trivy config infra/)"
  # `trivyignores` is the aquasecurity/trivy-action GitHub Action's input name
  # (ci.yml uses it) — the trivy CLI itself calls the same flag --ignorefile.
  trivy config infra --exit-code 1 --severity HIGH,CRITICAL --ignorefile .trivyignore
  pass "no HIGH/CRITICAL IaC misconfigurations"

  step "secret scan (trivy fs .)"
  trivy fs . --scanners secret --exit-code 1 --severity MEDIUM,HIGH,CRITICAL
  pass "no committed secrets found"

  step "npm audit (frontend, high+)"
  (cd frontend && npm audit --audit-level=high)
  pass "npm audit clean"
fi

# True when this env root declares module.run_api (currently only dev).
env_has_run_api() {
  grep -qE '^[[:space:]]*module[[:space:]]+"run_api"[[:space:]]*\{' "$TF_DIR/main.tf" 2>/dev/null
}

# ─── Terraform ─────────────────────────────────────────────────────────────────

if [[ "$DEPLOY_INFRA" == true ]]; then
  step "terraform init ($TF_DIR)"
  STATE_BUCKET="$(./scripts/state-bucket-name.sh)"
  terraform -chdir="$TF_DIR" init -input=false -reconfigure -backend-config="bucket=${STATE_BUCKET}"

  # Same chicken-and-egg fix as deploy.yml: the deploy/local-dev role's own
  # permissions are defined in this Terraform, so a brand-new environment must
  # attach those policies to itself before it can create anything else.
  # Idempotent and harmless once the policies already exist and are attached.
  step "apply IAM deploy policies first"
  iam_targets=(
    -target=module.static_site.aws_iam_policy.github_deploy_core_policy
    -target=module.static_site.aws_iam_role_policy_attachment.github_deploy_core
    -target=module.static_site.time_sleep.iam_propagation
    -target=module.static_site.aws_iam_policy.github_deploy_storage_policy
    -target=module.static_site.aws_iam_role_policy_attachment.github_deploy_storage
    -target=module.static_site.time_sleep.storage_iam_propagation
    -target=module.static_site.aws_iam_policy.github_deploy_cdn_policy
    -target=module.static_site.aws_iam_role_policy_attachment.github_deploy_cdn
    -target=module.static_site.time_sleep.cdn_iam_propagation
  )
  if env_has_run_api; then
    iam_targets+=(
      -target=module.run_pipeline.aws_iam_policy.github_deploy_run_pipeline_policy
      -target=module.run_pipeline.aws_iam_role_policy_attachment.github_deploy_run_pipeline
      -target=module.run_pipeline.time_sleep.run_pipeline_iam_propagation
      -target=module.run_api.aws_iam_policy.github_deploy_run_api_policy
      -target=module.run_api.aws_iam_role_policy_attachment.github_deploy_run_api
      -target=module.run_api.time_sleep.run_api_iam_propagation
    )
  fi
  terraform -chdir="$TF_DIR" apply -refresh=false -auto-approve -input=false \
    "${iam_targets[@]}" \
    || warn "targeted IAM apply failed or had nothing to do — continuing to full plan"

  # deploy.yml re-assumes the OIDC role so the new policy grants take effect
  # before ECR create / image push. Same idea when --assume-role was used.
  if [[ -n "$ASSUME_ROLE_ARN" ]]; then
    assume_deploy_role "local-deploy-refresh-$(date +%s)"
  else
    warn "IAM policies may take a few seconds to propagate; if ECR/Lambda steps fail with AccessDenied, re-run."
  fi

  if [[ "$SKIP_BACKEND_IMAGE" == true ]]; then
    if [[ -z "${TF_VAR_backend_image_tag:-}" ]] && env_has_run_api; then
      # Keep the Lambda on whatever tag is already in state so plan does not
      # flip image_uri to the unused default "unset".
      prior_uri="$(terraform -chdir="$TF_DIR" show -json 2>/dev/null | jq -r '
        .. | objects | select(.type? == "aws_lambda_function" and .name? == "api")
          | .values.image_uri // empty
      ' 2>/dev/null | head -1 || true)"
      if [[ -n "$prior_uri" && "$prior_uri" == *:* ]]; then
        export TF_VAR_backend_image_tag="${prior_uri##*:}"
        pass "reusing deployed image tag from state: $TF_VAR_backend_image_tag"
      else
        warn "no prior Lambda image_uri in state — set TF_VAR_backend_image_tag or omit --skip-backend-image"
      fi
    fi
    warn "skipping ECR apply + Lambda image push (--skip-backend-image); TF_VAR_backend_image_tag=${TF_VAR_backend_image_tag:-<unset>}"
  elif env_has_run_api; then
    # Image must exist in ECR before aws_lambda_function.api can reference the
    # tag — CreateFunction fails against a missing tag. Repository first.
    step "apply run-api ECR repository"
    terraform -chdir="$TF_DIR" apply -auto-approve -input=false \
      -target=module.run_api.aws_ecr_repository.api

    step "build and push backend Lambda image (tag=$TF_VAR_backend_image_tag)"
    # Match deploy.yml: Docker on Darwin fills an empty credsStore with
    # osxkeychain (headless login → err -25308). Use ecr-login instead.
    DOCKER_CONFIG="$(mktemp -d "${TMPDIR:-/tmp}/deploy-local-docker.XXXXXX")"
    export DOCKER_CONFIG
    cleanup_docker_config() { rm -rf "$DOCKER_CONFIG"; }
    trap cleanup_docker_config EXIT
    if [ -d "${HOME}/.docker/cli-plugins" ]; then
      ln -sfn "${HOME}/.docker/cli-plugins" "$DOCKER_CONFIG/cli-plugins"
    fi

    repo_url="$(terraform -chdir="$TF_DIR" output -raw run_api_ecr_repository_url)"
    registry="${repo_url%%/*}"
    if ! command -v docker-credential-ecr-login >/dev/null 2>&1; then
      fail "docker-credential-ecr-login not on PATH (required for headless ECR auth on macOS)"
    fi
    printf '%s\n' "{\"auths\":{},\"credHelpers\":{\"${registry}\":\"ecr-login\"}}" \
      > "$DOCKER_CONFIG/config.json"

    image="${repo_url}:${TF_VAR_backend_image_tag}"
    docker build -f backend/Dockerfile.lambda -t "$image" backend
    docker push "$image"
    pass "pushed $image"
    trap - EXIT
    cleanup_docker_config
  else
    warn "$TF_DIR has no module.run_api — skipping Lambda image build (staging/prod may not host the API yet)"
  fi

  step "terraform plan (TF_VAR_backend_image_tag=$TF_VAR_backend_image_tag)"
  terraform -chdir="$TF_DIR" plan -out=tfplan -input=false

  step "checking for destructive changes"
  terraform -chdir="$TF_DIR" show -json tfplan > "$TF_DIR/tfplan.json"
  destructive="$(jq -r '
    [ .resource_changes[]?
      | select(.change.actions | index("delete"))
      | .address ] | join("\n")
  ' "$TF_DIR/tfplan.json")"
  rm -f "$TF_DIR/tfplan.json"

  if [[ -n "$destructive" ]]; then
    warn "this plan destroys or replaces resources:"
    echo "$destructive"
    if [[ "$ALLOW_DESTROY" == true ]]; then
      warn "--allow-destroy set — continuing"
    else
      fail "refusing to apply a destructive plan. Review the resources above, then re-run with --allow-destroy if intended."
    fi
  else
    pass "no destroys or replacements in this plan"
  fi

  echo ""
  terraform -chdir="$TF_DIR" show tfplan
  if [[ "$AUTO_YES" != true ]]; then
    read -rp "Apply this plan to '$ENVIRONMENT'? [y/N] " apply_confirm
    [[ "$apply_confirm" =~ ^[Yy]$ ]] || fail "aborted before apply"
  fi

  step "terraform apply"
  terraform -chdir="$TF_DIR" apply -input=false tfplan
  rm -f "$TF_DIR/tfplan"
  pass "terraform apply complete"
else
  step "terraform init ($TF_DIR) — reading existing state only"
  STATE_BUCKET="$(./scripts/state-bucket-name.sh)"
  terraform -chdir="$TF_DIR" init -input=false -reconfigure -backend-config="bucket=${STATE_BUCKET}"
fi

# ─── Frontend build + deploy ────────────────────────────────────────────────────

if [[ "$DEPLOY_FRONTEND" == true ]]; then
  step "reading terraform outputs"
  S3_BUCKET="$(terraform -chdir="$TF_DIR" output -raw s3_bucket_name)"
  CF_DIST_ID="$(terraform -chdir="$TF_DIR" output -raw cloudfront_distribution_id)"
  SITE_URL="$(terraform -chdir="$TF_DIR" output -raw site_url)"
  USER_POOL_ID="$(terraform -chdir="$TF_DIR" output -raw cognito_user_pool_id)"
  CLIENT_ID="$(terraform -chdir="$TF_DIR" output -raw cognito_client_id)"
  pass "bucket=$S3_BUCKET distribution=$CF_DIST_ID"

  step "building frontend"
  (
    cd frontend
    export NEXT_PUBLIC_AWS_REGION="$AWS_REGION_VAL"
    export NEXT_PUBLIC_USER_POOL_ID="$USER_POOL_ID"
    export NEXT_PUBLIC_CLIENT_ID="$CLIENT_ID"
    # Optional — empty resolves to null in frontend/lib/env.ts.
    export NEXT_PUBLIC_API_BASE_URL="$API_BASE_URL_VAL"
    npm run build
  )
  pass "frontend built to frontend/out"

  step "uploading hashed assets (immutable cache)"
  if [[ -d frontend/out/_next/static ]]; then
    aws s3 sync frontend/out/_next/static "s3://$S3_BUCKET/_next/static" \
      --no-progress --cache-control "public,max-age=31536000,immutable"
  fi

  step "uploading HTML and unhashed assets (must-revalidate)"
  aws s3 sync frontend/out "s3://$S3_BUCKET" \
    --no-progress --exclude "_next/static/*" --cache-control "public,max-age=0,must-revalidate"

  step "invalidating CloudFront"
  invalidation_id="$(aws cloudfront create-invalidation \
    --distribution-id "$CF_DIST_ID" --paths "/*" \
    --query 'Invalidation.Id' --output text)"
  echo "waiting for invalidation $invalidation_id to complete..."
  aws cloudfront wait invalidation-completed --distribution-id "$CF_DIST_ID" --id "$invalidation_id"
  pass "invalidation complete"

  step "pruning deleted files"
  aws s3 sync frontend/out "s3://$S3_BUCKET" --no-progress --delete --size-only
  pass "prune complete"

  echo -e "\n${GREEN}${BOLD}Deployed to $ENVIRONMENT: $SITE_URL${NC}"
else
  echo -e "\n${GREEN}${BOLD}Infra apply complete for $ENVIRONMENT (--infra-only, frontend skipped)${NC}"
fi
