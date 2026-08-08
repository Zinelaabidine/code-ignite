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
# Every root loads infra/common.tfvars via a common.auto.tfvars symlink.
# State bucket at init: scripts/state-bucket-name.sh (project_name + AWS account).
# ---------------------------------------------------------------------------
step "shared config symlinks"
symlink_errors=0
for root in "${TERRAFORM_ROOTS[@]}"; do
  f="$root/common.auto.tfvars"
  [[ -e "$f" || -L "$f" ]] || continue
  if [[ ! -L "$f" ]]; then
    echo -e "${RED}  $f is a real file, not a symlink to infra/common.tfvars${NC}" >&2
    symlink_errors=$((symlink_errors + 1))
  fi
done
if [[ "$symlink_errors" -gt 0 ]]; then
  fail "$symlink_errors root(s) have a local copy of common.auto.tfvars — use: ln -sf ../../common.tfvars common.auto.tfvars (adjust path per root)."
else
  pass "every root loads infra/common.tfvars through a symlink"
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
    # Dropping remote backend for validate. Stale .terraform/ still references the
    # previous state bucket after project_name changes; init -backend=false then
    # tries to read that bucket and fails (e.g. apptemplate → codeignite).
    rm -rf .terraform
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

# --- Backend ---
if [[ -d backend/src/codeignite ]]; then
  if [[ ! -d backend/.venv ]]; then
    fail "backend/.venv missing — run: cd backend && python3.12 -m venv .venv && source .venv/bin/activate && pip install -e '.[dev]'"
  fi

  step "backend format"
  (cd backend && .venv/bin/ruff format --check .)
  pass "backend format"

  step "backend lint"
  (cd backend && .venv/bin/ruff check .)
  pass "backend lint"

  step "backend type-check"
  (cd backend && .venv/bin/mypy --strict src)
  pass "backend type-check"

  step "backend tests"
  # Docker-dependent tests are marked `docker` — see backend/README.md.
  (cd backend && .venv/bin/pytest -m "not docker")
  pass "backend tests"
else
  warn "backend/src/codeignite not present yet — skipping backend checks"
fi

echo -e "\n${GREEN}All pre-commit checks passed.${NC}"
