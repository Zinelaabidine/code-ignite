#!/usr/bin/env bash
# Install tracked git hooks into .git/hooks (run once per clone).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_SRC="$ROOT/scripts/git-hooks"
HOOKS_DST="$ROOT/.git/hooks"

if [[ ! -d "$ROOT/.git" ]]; then
  echo "error: .git directory not found — run this from the repo root" >&2
  exit 1
fi

mkdir -p "$HOOKS_DST"

for hook in "$HOOKS_SRC"/*; do
  name="$(basename "$hook")"
  target="$HOOKS_DST/$name"
  ln -sf "../../scripts/git-hooks/$name" "$target"
  chmod +x "$hook"
  echo "installed hook: $name -> scripts/git-hooks/$name"
done

chmod +x "$ROOT/scripts/pre-commit-check.sh"
echo "done — pre-commit checks will run before every git commit"
