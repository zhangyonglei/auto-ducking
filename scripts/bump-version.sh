#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

KIND="${1:-patch}"
VERSION_FILE="$ROOT/VERSION"
CHANGELOG="$ROOT/CHANGELOG.md"

if [[ "$KIND" != "patch" && "$KIND" != "minor" && "$KIND" != "major" ]]; then
  echo "Usage: $0 [patch|minor|major]" >&2
  exit 1
fi

version=$(cat "$VERSION_FILE" | tr -d '[:space:]')
major=$(echo "$version" | cut -d. -f1)
minor=$(echo "$version" | cut -d. -f2)
patch=$(echo "$version" | cut -d. -f3)

case "$KIND" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
esac

new_version="$major.$minor.$patch"
today=$(date +%Y-%m-%d)

echo "$new_version" > "$VERSION_FILE"

awk -v new="$new_version" -v today="$today" '
  BEGIN { inserted=0 }
  /^## \[未发布\]/ && !inserted {
    print "## [未发布]"
    print ""
    print "## [" new "] - " today
    inserted=1
    next
  }
  { print }
  END {
    if (!inserted) {
      print "## [" new "] - " today
    }
  }
' "$CHANGELOG" > "$CHANGELOG.tmp"
mv "$CHANGELOG.tmp" "$CHANGELOG"

echo "Bumped version to $new_version"
