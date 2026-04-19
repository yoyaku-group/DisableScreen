#!/bin/bash
# Build DisableScreen.app bundle.
# Layout:
#   Contents/MacOS/DisableScreen        = compiled Obj-C launcher (SMAppService + execs python3)
#   Contents/Resources/main.py          = PyObjC menubar app
#   Contents/Resources/<lang>.lproj/... = Localizable.strings per language
#   Contents/Info.plist
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$SCRIPT_DIR/DisableScreen.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

# Compile Obj-C launcher.
# Absolute python3 path is hardcoded in launcher.m because loginwindow's PATH is
# /usr/bin:/bin:/usr/sbin:/sbin and /usr/bin/python3 is the Apple stub without PyObjC.
clang -fobjc-arc -framework Foundation -framework ServiceManagement \
      -o "$MACOS/DisableScreen" "$SCRIPT_DIR/launcher.m"

# Bundle the Python app.
cp "$SCRIPT_DIR/main.py" "$RES/main.py"
cp "$SCRIPT_DIR/Info.plist" "$APP/Contents/Info.plist"
[ -f "$SCRIPT_DIR/AppIcon.icns" ] && cp "$SCRIPT_DIR/AppIcon.icns" "$RES/AppIcon.icns"

# Copy localization bundles.
for d in "$SCRIPT_DIR"/*.lproj; do
    [ -d "$d" ] && cp -R "$d" "$RES/"
done

# Ad-hoc sign (SMAppService requires a signed binary).
codesign --force --sign - "$APP"

echo "Built: $APP"
