#!/usr/bin/env bash
# Run all local checks before committing. Safe to run manually:
#   ./scripts/pre-commit-check.sh
#
# Mirrors .github/workflows/ci.yml. If you add a check to one, add it to the
# other — CI is the gate, this is just the fast feedback.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

step() {
  echo -e "\n${BLUE}==> $1${NC}"
}

pass() {
  echo -e "${GREEN}✓ $1${NC}"
}

warn() {
  echo -e "${YELLOW}! $1${NC}"
}

fail() {
  echo -e "${RED}✗ $1${NC}" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "$1 is not installed or not on PATH"
  fi
}

require_cmd terraform
require_cmd node
require_cmd npm

TERRAFORM_ENVS=(dev staging prod)
TERRAFORM_ROOTS=(infra/bootstrap infra/envs/dev infra/envs/staging infra/envs/prod)

# ---------------------------------------------------------------------------
# The state bucket name lives in two places that Terraform cannot reconcile on
# its own: `bucket` in backend.hcl (where state is stored) and
# `terraform_state_bucket` in terraform.tfvars (which builds the IAM grant on
# that bucket). When they disagree, `terraform init` in CI fails with
# AccessDenied — and the error points nowhere near the cause.
#
# This check is the reason that class of bug cannot come back.
# ---------------------------------------------------------------------------
step "state bucket name consistency"
mismatches=0
checked=0
for root in "${TERRAFORM_ROOTS[@]}"; do
  backend_file="$root/backend.hcl"
  tfvars_file="$root/terraform.tfvars"

  # Both are gitignored, so a fresh clone legitimately has neither.
  [[ -f "$backend_file" && -f "$tfvars_file" ]] || continue

  # [[:space:]] rather than \s: BSD sed (macOS's /usr/bin/sed) does not support
  # \s in -E mode, so it silently fails to match and prints the whole line
  # unchanged — which then never compares equal to the other side, even when
  # the actual bucket names agree. [[:space:]] is POSIX and works on both.
  backend_bucket="$(grep -E '^[[:space:]]*bucket[[:space:]]*=' "$backend_file" |
    head -1 | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')"
  tfvars_bucket="$(grep -E '^[[:space:]]*terraform_state_bucket[[:space:]]*=' "$tfvars_file" |
    head -1 | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')"

  checked=$((checked + 1))
  if [[ "$backend_bucket" != "$tfvars_bucket" ]]; then
    echo -e "${RED}  $root${NC}" >&2
    echo "    backend.hcl bucket:              '$backend_bucket'" >&2
    echo "    terraform.tfvars state bucket:   '$tfvars_bucket'" >&2
    mismatches=$((mismatches + 1))
  fi
done

if [[ "$mismatches" -gt 0 ]]; then
  fail "state bucket name differs between backend.hcl and terraform.tfvars in $mismatches root(s)"
elif [[ "$checked" -eq 0 ]]; then
  warn "no backend.hcl + terraform.tfvars pairs found — skipping (copy the .example files to set them up)"
else
  pass "state bucket name consistent across $checked root(s)"
fi

# --- Terraform format ---
step "terraform fmt (check)"
if terraform fmt -check -recursive infra/; then
  pass "terraform fmt"
else
  fail "terraform fmt failed — run: terraform fmt -recursive infra/"
fi

# --- Terraform validate (all roots, no remote backend, no credentials needed) ---
for root in "${TERRAFORM_ROOTS[@]}"; do
  if [[ ! -d "$root" ]]; then
    fail "missing terraform root directory: $root"
  fi

  step "terraform validate ($root)"
  (
    cd "$root"
    # -reconfigure: without it, -backend=false reuses whatever backend was
    # cached in .terraform/ by a previous real `terraform init
    # -backend-config=...` in this directory (e.g. an earlier experiment
    # pointed at a bucket that no longer exists or isn't accessible), and
    # validate fails trying to refresh that stale remote state instead of
    # running as the local, credential-free check it's meant to be.
    terraform init -backend=false -reconfigure -input=false >/dev/null
    terraform validate
  )
  pass "terraform validate ($root)"
done

# --- Provider lock files must be committed ---
step "provider lock files"
missing_locks=()
for root in "${TERRAFORM_ROOTS[@]}"; do
  [[ -f "$root/.terraform.lock.hcl" ]] || missing_locks+=("$root")
done
if [[ ${#missing_locks[@]} -gt 0 ]]; then
  fail "missing .terraform.lock.hcl in: ${missing_locks[*]}
  Generate with: terraform -chdir=<root> providers lock -platform=linux_amd64 -platform=darwin_arm64"
fi
pass "provider lock files present"

# --- Frontend ---
if [[ ! -d frontend/node_modules ]]; then
  fail "frontend/node_modules missing — run: cd frontend && npm ci"
fi

step "frontend format"
(cd frontend && npm run format:check)
pass "frontend format"

step "frontend lint"
(cd frontend && npm run lint)
pass "frontend lint"

step "frontend type-check"
(cd frontend && npm run typecheck)
pass "frontend type-check"

step "frontend tests"
(cd frontend && npm run test)
pass "frontend tests"

# --- Frontend build ---
# Requires frontend/.env.local: lib/env.ts throws on a missing Cognito ID rather
# than baking `undefined` into the bundle.
step "frontend build"
(cd frontend && npm run build)
pass "frontend build"

echo -e "\n${GREEN}All pre-commit checks passed.${NC}"
