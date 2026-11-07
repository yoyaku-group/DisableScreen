#!/bin/bash
# build-runclosed-app.sh — assemble RunClosed.app, the A14-T1 SMAppService
# carrier bundle (ADR 017).
#
# Layout produced:
#   RunClosed.app/Contents/MacOS/RunClosed                    — menu-bar app
#   RunClosed.app/Contents/MacOS/runclosed-cli                — management CLI
#                                                               (run from inside
#                                                               the bundle: the
#                                                               plist resolves
#                                                               against the
#                                                               main bundle.
#                                                               NOT named
#                                                               `runclosed`:
#                                                               APFS is
#                                                               case-insensitive
#                                                               — it would be
#                                                               the SAME file as
#                                                               `RunClosed`.)
#   RunClosed.app/Contents/MacOS/runclosed-privileged-helper — root daemon
#   RunClosed.app/Contents/Library/LaunchDaemons/<plist>      — daemon plist
#                                                               (BundleProgram
#                                                               points back at
#                                                               MacOS/)
#
# Signing: SIGN_IDENTITY env var (default '-', ad-hoc). The LIVE SMAppService
# registration cycle requires a real identity, e.g.:
#   SIGN_IDENTITY="Developer ID Application: YOYAKU (YZYJJPX484)" \
#     bash scripts/build-runclosed-app.sh
#
# Every slice is signed with the hardened runtime (`--options runtime
# --timestamp`), which notarization requires; both flags are valid under an
# ad-hoc identity too. To notarize a Developer ID build:
#   ditto -c -k --sequesterRsrc --keepParent build/RunClosed.app build/RunClosed.zip
#   xcrun notarytool submit build/RunClosed.zip --keychain-profile <profile> --wait
#   xcrun stapler staple build/RunClosed.app
#   spctl -a -vv build/RunClosed.app
#
# Usage: bash scripts/build-runclosed-app.sh
#        OUT_DIR=build CONFIG=release SIGN_IDENTITY=... bash scripts/...
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="${OUT_DIR:-build}"
APP="$OUT_DIR/RunClosed.app"
CONFIG="${CONFIG:-release}"
IDENTITY="${SIGN_IDENTITY:--}"

echo "==> swift build ($CONFIG, arm64, all products)"
# NOTE: a single `--product` flag only builds that product (repeat flags are
# not cumulative in SwiftPM) — build the whole package instead.
arch -arm64 swift build -c "$CONFIG"
BIN="$(arch -arm64 swift build -c "$CONFIG" --show-bin-path)"
test -x "$BIN/RunClosedMenuBar" || { echo "missing $BIN/RunClosedMenuBar" >&2; exit 1; }
test -x "$BIN/RunClosedHelper"  || { echo "missing $BIN/RunClosedHelper" >&2; exit 1; }
test -x "$BIN/runclosed"        || { echo "missing $BIN/runclosed" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" \
         "$APP/Contents/Library/LaunchDaemons" \
         "$APP/Contents/Library/LaunchAgents"

cp "$BIN/RunClosedMenuBar" "$APP/Contents/MacOS/RunClosed"
cp "$BIN/runclosed"        "$APP/Contents/MacOS/runclosed-cli"
cp "$BIN/RunClosedHelper"  "$APP/Contents/MacOS/runclosed-privileged-helper"
cp Resources/com.benjaminbelaga.runclosed.helper.plist \
   "$APP/Contents/Library/LaunchDaemons/"
# ADR 024 — the per-user recovery backstop agent. `SMAppService.agent(
# plistName:)` resolves it against this bundle's LaunchAgents directory, and
# its BundleProgram points back at the runclosed-cli copied above, so the job
# dies with the app instead of surviving a deleted bundle.
#
# The plist carries NO log path and needs no substitution. `StandardOutPath`
# and `StandardErrorPath` are fixed bytes in a signed bundle, so whatever path
# they name belongs to the machine that BUILT the bundle: installed by another
# account, the agent would write its diagnostics into a directory the running
# user may not own, or fail the open and lose them. launchd expands no variable
# there, so there is no correct value to substitute. The agent writes its own
# trace under NSHomeDirectory()/Library/Logs/RunClosed/backstop.log, resolved at
# RUNTIME by the process launchd started as the right user (review round 16).
cp Resources/com.benjaminbelaga.runclosed.backstop.plist \
   "$APP/Contents/Library/LaunchAgents/"
# The directory itself is created at runtime by `prepareLogDirectory()`, so a
# bundle installed on another machine is not left with a missing directory.

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.benjaminbelaga.RunClosed</string>
    <key>CFBundleName</key><string>RunClosed</string>
    <key>CFBundleDisplayName</key><string>RunClosed</string>
    <key>CFBundleExecutable</key><string>RunClosed</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3.0</string>
    <key>CFBundleVersion</key><string>4</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>fr</string>
    </array>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Localizations — English string tables are the base; French ships as a
# translation. English is also the product default (CFBundleDevelopmentRegion),
# so a language we don't ship falls back to English.
mkdir -p "$APP/Contents/Resources"
for lproj in en.lproj fr.lproj; do
    if [ -f "$lproj/Localizable.strings" ]; then
        mkdir -p "$APP/Contents/Resources/$lproj"
        cp "$lproj/Localizable.strings" "$APP/Contents/Resources/$lproj/"
    fi
done

echo "==> signing (identity: $IDENTITY, hardened runtime)"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/runclosed-privileged-helper"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/runclosed-cli"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/RunClosed"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"

echo "==> verify signature (strict)"
codesign --verify --strict --verbose=1 "$APP"

echo "==> verify"
plutil -lint "$APP/Contents/Library/LaunchDaemons/"*.plist
plutil -lint "$APP/Contents/Library/LaunchAgents/"*.plist
echo "--- structure"
(cd "$OUT_DIR" && find RunClosed.app -print | sort)
echo "--- bundle signature"
codesign -dv "$APP" 2>&1 | sed -n '1,6p'
echo "OK: $APP"
