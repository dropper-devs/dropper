#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

[[ -d "${APP_BUNDLE}" ]] || die "Missing app bundle. Run make sign first."

mkdir -p "${OUTPUT_DIR}"
rm -f "${ZIP_PATH}"

log "Creating notarization archive"
ditto -c -k --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"

log "Submitting app to Apple notarization"
xcrun notarytool submit "${ZIP_PATH}" \
    --keychain-profile "${MAC_NOTARIZE_PROFILE}" --wait

log "Stapling app"
xcrun stapler staple "${APP_BUNDLE}"
xcrun stapler validate "${APP_BUNDLE}"

log "Notarized ${APP_BUNDLE}"
