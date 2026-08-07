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
# The state bucket name used to live independently in two files per root
# (backend.hcl and terraform.tfvars) across four roots — eight places that
# could silently drift. It now lives in exactly two files at the repo root,
# infra/common-backend.hcl (`bucket`) and infra/common.tfvars
# (`terraform_state_bucket`), and every root's own backend.hcl /
# common.auto.tfvars is a symlink back to those two files. So there are two
# checks: the two shared files must agree with each other, and every root
# must actually still be reading them via a symlink rather than a local copy
# that could drift again.
# ---------------------------------------------------------------------------
step "state bucket name consistency"

COMMON_BACKEND="infra/common-backend.hcl"
COMMON_TFVARS="infra/common.tfvars"

if [[ -f "$COMMON_BACKEND" && -f "$COMMON_TFVARS" ]]; then
  # [[:space:]] rather than \s: BSD sed (macOS's /usr/bin/sed) does not support
  # \s in -E mode, so it silently fails to match and prints the whole line
  # unchanged — which then never compares equal to the other side, even when
  # the actual bucket names agree. [[:space:]] is POSIX and works on both.
  backend_bucket="$(grep -E '^[[:space:]]*bucket[[:space:]]*=' "$COMMON_BACKEND" |
    head -1 | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')"
  tfvars_bucket="$(grep -E '^[[:space:]]*terraform_state_bucket[[:space:]]*=' "$COMMON_TFVARS" |
    head -1 | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')"

  if [[ "$backend_bucket" != "$tfvars_bucket" ]]; then
    echo "    $COMMON_BACKEND bucket:            '$backend_bucket'" >&2
    echo "    $COMMON_TFVARS terraform_state_bucket: '$tfvars_bucket'" >&2
    fail "state bucket name differs between $COMMON_BACKEND and $COMMON_TFVARS"
  fi
  pass "state bucket name consistent between $COMMON_BACKEND and $COMMON_TFVARS"
else
  warn "$COMMON_BACKEND / $COMMON_TFVARS not found — skipping (copy the .example files to set them up)"
fi

step "shared config symlinks"
symlink_errors=0
for root in "${TERRAFORM_ROOTS[@]}"; do
  for name in backend.hcl common.auto.tfvars common-domain.auto.tfvars; do
    f="$root/$name"
    [[ -e "$f" || -L "$f" ]] || continue # not set up yet in this root — fine
    # infra/bootstrap doesn't declare hosted_zone_name/certificate_domain_name,
    # so it intentionally has no common-domain.auto.tfvars symlink.
    if [[ ! -L "$f" ]]; then
      echo -e "${RED}  $f is a real file, not a symlink to a shared file under infra/${NC}" >&2
      symlink_errors=$((symlink_errors + 1))
    fi
  done
done
if [[ "$symlink_errors" -gt 0 ]]; then
  fail "$symlink_errors root(s) have a local copy instead of a symlink — shared values can drift again. Re-create with: ln -sf ../common-backend.hcl infra/bootstrap/backend.hcl (adjust relative path per root)."
else
  pass "every root reads shared config through a symlink"
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
