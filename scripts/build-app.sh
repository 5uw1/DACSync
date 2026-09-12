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

# Prefer a real Developer ID Application identity when one is installed
# (checked into the keychain via Xcode > Settings > Accounts > Manage
# Certificates, or imported from CI secrets — see scripts/notarize.sh and
# .github/workflows/build.yml). Falls back to ad-hoc for local dev when
# there's no Developer ID: SMAppService Login Items (LaunchAtLogin.swift)
# are more stable across rebuilds under a consistent signing identity than
# under a fresh ad-hoc signature each time, but ad-hoc still runs fine
# locally without one.
# The `|| true` matters: grep exits 1 when there's no match (the expected
# case without a Developer ID cert installed), and under `set -eo
# pipefail` that would otherwise abort the whole script right here.
DEVELOPER_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application:.*"' | head -1 | tr -d '"' || true)

if [ -n "$DEVELOPER_ID" ]; then
  echo "==> Signing with Developer ID: $DEVELOPER_ID"
  # --options runtime (the hardened runtime) is required for notarization;
  # harmless otherwise.
  codesign --force --deep --options runtime --sign "$DEVELOPER_ID" "$APP_BUNDLE"
  echo "==> Done: $APP_BUNDLE (Developer ID signed — run scripts/notarize.sh to notarize before distributing)"
else
  echo "==> No Developer ID Application identity found — ad-hoc signing"
  codesign --force --deep --sign - "$APP_BUNDLE"
  echo "==> Done: $APP_BUNDLE (ad-hoc signed — fine for local use, not for distribution)"
fi
echo "    open \"$APP_BUNDLE\""
