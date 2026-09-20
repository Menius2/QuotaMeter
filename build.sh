#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$ROOT_DIR/build"
APP_DIR="$OUT_DIR/QuotaMeter.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
ICON_FILE="$ROOT_DIR/AppIcon.icns"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

swiftc \
  -parse-as-library \
  -O \
  -framework AppKit \
  -framework Combine \
  -framework Security \
  -framework SwiftUI \
  -framework WebKit \
  "$ROOT_DIR/QuotaMeter.swift" \
  -o "$MACOS_DIR/QuotaMeter"

cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -f "$ICON_FILE" ]]; then
  cp "$ICON_FILE" "$RESOURCES_DIR/AppIcon.icns"
fi
chmod +x "$MACOS_DIR/QuotaMeter"

echo "Built: $APP_DIR"
