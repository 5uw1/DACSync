#!/bin/bash
# Builds a release binary and wraps it into a proper DACSync.app bundle.
# DACSync is a plain SwiftPM package (no Xcode project), so there's no
# .xcodeproj to Archive — this script does by hand what Xcode would do for
# packaging: bundle structure, Info.plist, ad-hoc code signing.
#
# Usage: scripts/build-app.sh
# Output: build/DACSync.app

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="DACSync"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "==> Building release binary"
swift build -c release

echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> Ad-hoc code signing"
# Ad-hoc (-s -) is enough to run locally without a "damaged app" Gatekeeper
# error. If you have a Developer ID, sign with that instead — SMAppService
# Login Items (see LaunchAtLogin.swift) are more stable across rebuilds
# under a consistent signing identity than under a fresh ad-hoc signature
# each time.
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Done: $APP_BUNDLE"
echo "    open \"$APP_BUNDLE\""
