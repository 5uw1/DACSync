#!/bin/bash
# Notarizes and staples build/DACSync.app, which must already be signed
# with a real Developer ID Application identity (scripts/build-app.sh does
# this automatically when one is installed — ad-hoc signed builds will be
# rejected by Apple's notary service).
#
# Requires an App Store Connect API key (Developer role is enough) via
# three env vars:
#   ASC_KEY_ID      - the key's Key ID
#   ASC_ISSUER_ID   - the key's Issuer ID
#   ASC_API_KEY_P8  - path to the downloaded AuthKey_<ID>.p8 file
#
# Usage: ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_API_KEY_P8=... scripts/notarize.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_BUNDLE="build/DACSync.app"
NOTARIZE_ZIP="build/DACSync-notarize.zip"

: "${ASC_KEY_ID:?Set ASC_KEY_ID (App Store Connect API key ID)}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID (App Store Connect API issuer ID)}"
: "${ASC_API_KEY_P8:?Set ASC_API_KEY_P8 to the path of your AuthKey_*.p8 file}"

if [ ! -d "$APP_BUNDLE" ]; then
  echo "error: $APP_BUNDLE not found — run scripts/build-app.sh first" >&2
  exit 1
fi

SIGNATURE=$(codesign -dv "$APP_BUNDLE" 2>&1 || true)
if echo "$SIGNATURE" | grep -q "adhoc"; then
  echo "error: $APP_BUNDLE is ad-hoc signed. Install a Developer ID Application" >&2
  echo "       certificate first (see README), then rebuild with scripts/build-app.sh" >&2
  echo "       before notarizing." >&2
  exit 1
fi

echo "==> Zipping for submission"
rm -f "$NOTARIZE_ZIP"
ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"

echo "==> Submitting to Apple's notary service (this can take a few minutes)"
xcrun notarytool submit "$NOTARIZE_ZIP" \
  --key "$ASC_API_KEY_P8" \
  --key-id "$ASC_KEY_ID" \
  --issuer "$ASC_ISSUER_ID" \
  --wait

echo "==> Stapling the notarization ticket to $APP_BUNDLE"
xcrun stapler staple "$APP_BUNDLE"

echo "==> Verifying"
xcrun stapler validate "$APP_BUNDLE"
spctl --assess --type execute --verbose "$APP_BUNDLE"

rm -f "$NOTARIZE_ZIP"
echo "==> Done: $APP_BUNDLE is notarized and stapled — safe to zip and distribute as-is"
