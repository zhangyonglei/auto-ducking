#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

./scripts/auto-version.sh

VERSION=$(cat VERSION | tr -d '[:space:]')
BUILD=$(date +%Y%m%d%H%M)

if [ ! -f Resources/AppIcon.icns ] || [ scripts/generate-icon.swift -nt Resources/AppIcon.icns ]; then
  echo "Generating app icon..."
  swift scripts/generate-icon.swift
fi

echo "Building AutoDucking $VERSION (build $BUILD)..."
swift build -c release --product AutoDucking

BIN_PATH=$(swift build -c release --show-bin-path)
APP="$ROOT/build/AutoDucking.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/AutoDucking" "$APP/Contents/MacOS/AutoDucking"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"

sed \
  -e "s/@VERSION@/$VERSION/g" \
  -e "s/@BUILD@/$BUILD/g" \
  Resources/Info.plist.template > "$APP/Contents/Info.plist"

plutil -lint "$APP/Contents/Info.plist" > /dev/null
codesign --force --sign - "$APP" > /dev/null 2>&1 || echo "warning: ad-hoc codesign failed"

echo "App: $APP"
echo "Version: $VERSION (build $BUILD)"

if [ "${1:-}" = "--open" ]; then
  open "$APP"
fi
