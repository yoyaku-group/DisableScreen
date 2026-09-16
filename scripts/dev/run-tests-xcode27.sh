#!/bin/bash
# run-tests-xcode27.sh — build + test RunClosed WITHOUT accepting the Xcode 27
# license (2026-09-16 incident: overnight Xcode 26.6 → 27.0 auto-update left
# the license unaccepted, blocking the `swift`/`xcodebuild` shims; only the
# shims are license-gated, not the toolchain frontends).
#
# Usage: bash scripts/dev/run-tests-xcode27.sh
# Exit:  0 = all bundles green, non-zero otherwise.
#
# Once `sudo xcodebuild -license accept` has been run, plain
# `arch -arm64 swift build && arch -arm64 swift test` is canonical again and
# this script becomes unnecessary.

set -euo pipefail
cd "$(dirname "$0")/../.."

XC=/Applications/Xcode.app/Contents/Developer
TC="$XC/Toolchains/XcodeDefault.xctoolchain"
PLATFORM="$XC/Platforms/MacOSX.platform/Developer"
SDK="$PLATFORM/SDKs/MacOSX.sdk"
PROD=".build/out/Products/Debug"

# 1. Build everything (including test bundles) via the frontend directly.
export SDKROOT="$SDK"
arch -arm64 "$TC/usr/bin/swift" build --build-tests

# 2. Seed the runtime rpaths with the testing frameworks the bundles expect
#    (SwiftPM normally wires these via xcodebuild, which is license-gated).
mkdir -p "$PROD/PackageFrameworks"
cp -R "$PLATFORM/Library/Frameworks/" "$PROD/PackageFrameworks/" 2>/dev/null || true
cp -R "$PLATFORM/Library/PrivateFrameworks/XCTestCore.framework" \
      "$PLATFORM/Library/PrivateFrameworks/XCTestSupport.framework" \
      "$PLATFORM/Library/PrivateFrameworks/XCUnit.framework" \
      "$PLATFORM/Library/PrivateFrameworks/XCTAutomationSupport.framework" \
      "$PROD/PackageFrameworks/" 2>/dev/null || true
cp "$PLATFORM/usr/lib/"*.dylib "$PROD/" 2>/dev/null || true

# 3. Run every xctest bundle with the runner's arm64 slice (the shim at
#    /usr/bin/xctest is x86_64-first under Rosetta shells).
export DYLD_FRAMEWORK_PATH="$PROD/PackageFrameworks"
export DYLD_LIBRARY_PATH="$PROD"
rc=0
for bundle in "$PROD"/*.xctest; do
    echo "=== $(basename "$bundle") ==="
    arch -arm64 "$XC/usr/bin/xctest" "$bundle" || rc=1
done
exit $rc
