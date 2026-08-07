#!/usr/bin/env bash
# Print Terraform remote state bucket name from project_name in infra/common.tfvars
# and the current AWS account (sts get-caller-identity). Used at terraform init
# because the S3 backend block cannot read .tfvars.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON_TFVARS="${1:-$ROOT/infra/common.tfvars}"

tfvars_get() {
  local key="$1"
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "$COMMON_TFVARS" |
    head -1 |
    sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/'
}

if [[ ! -f "$COMMON_TFVARS" ]]; then
  echo "state-bucket-name: $COMMON_TFVARS not found" >&2
  exit 1
fi

project_name="$(tfvars_get project_name)"
if [[ -z "$project_name" ]]; then
  echo "state-bucket-name: set project_name in $COMMON_TFVARS" >&2
  exit 1
fi

account_id="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || true
if [[ -z "$account_id" || "$account_id" == "None" ]]; then
  echo "state-bucket-name: AWS credentials required (aws sts get-caller-identity failed)" >&2
  exit 1
fi

echo "${project_name}-terraform-state-${account_id}"
