#!/bin/bash
# Build DisableScreen.app bundle
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$SCRIPT_DIR/DisableScreen.app"
MACOS="$APP/Contents/MacOS"

mkdir -p "$MACOS"

# Copy main script
cp "$SCRIPT_DIR/main.py" "$MACOS/DisableScreen"
chmod +x "$MACOS/DisableScreen"

# Copy Info.plist
cp "$SCRIPT_DIR/Info.plist" "$APP/Contents/Info.plist"

echo "Built: $APP"
