#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

[[ -d "${APP_BUNDLE}" ]] || die "Missing app bundle. Run make notarize first."

STAGE_DIR="${BUILD_DIR}/dmg-stage"
rm -rf "${STAGE_DIR}" "${DMG_PATH}"
mkdir -p "${STAGE_DIR}" "${OUTPUT_DIR}"

cp -R "${APP_BUNDLE}" "${STAGE_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGE_DIR}/Applications"

log "Creating ${DMG_PATH}"
hdiutil create -volname "${APP_DISPLAY_NAME}" -srcfolder "${STAGE_DIR}" \
    -ov -format UDZO "${DMG_PATH}"

codesign --force --sign "${MAC_SIGNING_IDENTITY}" --timestamp "${DMG_PATH}"

log "Submitting DMG to Apple notarization"
xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "${MAC_NOTARIZE_PROFILE}" --wait
xcrun stapler staple "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"

log "Built ${DMG_PATH}"
