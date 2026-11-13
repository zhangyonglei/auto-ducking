#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CHANGELOG="$ROOT/CHANGELOG.md"
VERSION_FILE="$ROOT/VERSION"

if [ ! -f "$CHANGELOG" ] || [ ! -f "$VERSION_FILE" ]; then
  exit 0
fi

# Only bump when the "未发布" section actually contains changelog entries.
has_entries=$(awk '
  /^## \[未发布\]/ { inside=1; next }
  /^## \[/ { inside=0 }
  inside && /^[[:space:]]*[-*]/ { found=1 }
  END { print found ? "yes" : "no" }
' "$CHANGELOG")

if [ "$has_entries" != "yes" ]; then
  exit 0
fi

version=$(cat "$VERSION_FILE" | tr -d '[:space:]')
major=$(echo "$version" | cut -d. -f1)
minor=$(echo "$version" | cut -d. -f2)
patch=$(echo "$version" | cut -d. -f3)
patch=$((patch + 1))
new_version="$major.$minor.$patch"
today=$(date +%Y-%m-%d)

awk -v new="$new_version" -v today="$today" '
  /^## \[未发布\]/ {
    print "## [未发布]"
    print ""
    print "## [" new "] - " today
    next
  }
  { print }
' "$CHANGELOG" > "$CHANGELOG.tmp"
mv "$CHANGELOG.tmp" "$CHANGELOG"

echo "$new_version" > "$VERSION_FILE"
echo "Auto-bumped version to $new_version (changelog entry published)"
