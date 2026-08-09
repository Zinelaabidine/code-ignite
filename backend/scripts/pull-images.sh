#!/usr/bin/env bash
# Pre-pulls every sandbox image in domain/languages.py.LANGUAGES.
#
# Without this, the *first* run of a language pays for its own image pull
# inside the job's own timeout — a cold `node:22-alpine` pull can easily
# blow past the 8s inner `timeout` before the container even starts running
# code. Run this once after cloning, and again after adding or re-pinning a
# language entry.
#
#   backend/scripts/pull-images.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -d .venv ]]; then
  echo "backend/.venv missing — run: python3.12 -m venv .venv && source .venv/bin/activate && pip install -e '.[dev]'" >&2
  exit 1
fi

# LANGUAGES is Python data, not shell-parseable config — ask it directly
# rather than hardcoding a second copy of the image list here that could
# drift from the registry.
images="$(.venv/bin/python -c '
from codeignite.domain.languages import LANGUAGES
for language in sorted(LANGUAGES):
    print(LANGUAGES[language].image)
')"

while IFS= read -r image; do
  [[ -z "$image" ]] && continue
  echo "pulling $image"
  docker pull "$image"
done <<<"$images"
