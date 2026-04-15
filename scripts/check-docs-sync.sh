#!/usr/bin/env bash
# check-docs-sync.sh — fail fast if generated OpenAPI spec drifts from source.
#
# Regenerates generated/swagger.json via tsoa and compares against the
# committed copy. Any diff = the controllers changed without regenerating
# the spec (and likely without updating the docs at web/src/app/docs/*).
#
# Run locally before pushing; CI runs the same check on every PR.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SPEC="generated/swagger.json"

echo "→ Regenerating $SPEC via tsoa..."
npm run --silent spec > /dev/null

if ! git diff --quiet --exit-code -- "$SPEC"; then
  echo ""
  echo "✗ $SPEC is out of sync with the controllers."
  echo ""
  echo "  Likely cause: you changed something under src/controllers/** and"
  echo "  forgot to run 'npm run spec'. Stage the regenerated file and"
  echo "  update the matching doc pages — see the table in CLAUDE.md."
  echo ""
  echo "  Diff preview:"
  git --no-pager diff --stat -- "$SPEC"
  exit 1
fi

echo "✓ $SPEC is in sync with the controllers."

# Reminder (non-fatal) — flag source changes that typically need doc updates.
CHANGED="$(git diff --name-only HEAD 2>/dev/null || true)"
STAGED="$(git diff --name-only --cached 2>/dev/null || true)"
ALL="$(printf '%s\n%s\n' "$CHANGED" "$STAGED" | sort -u)"

needs_docs=0
while IFS= read -r file; do
  case "$file" in
    src/controllers/*|prisma/schema.prisma|src/services/*|src/providers/*)
      needs_docs=1
      ;;
  esac
done <<< "$ALL"

if [ "$needs_docs" -eq 1 ]; then
  docs_touched=0
  while IFS= read -r file; do
    case "$file" in
      web/src/app/docs/*|README.md|CLAUDE.md)
        docs_touched=1
        ;;
    esac
  done <<< "$ALL"

  if [ "$docs_touched" -eq 0 ]; then
    echo ""
    echo "⚠  You touched controllers / schema / services / providers but"
    echo "   didn't update any doc page or README. Check the Documentation"
    echo "   Invariants table in CLAUDE.md before opening a PR."
  fi
fi
