#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

log "Building ${APP_DISPLAY_NAME} v${VERSION}"
swift build --package-path "${PROJECT_ROOT}" -c release --product "${EXECUTABLE_PRODUCT}"
BIN_DIR="$(swift build --package-path "${PROJECT_ROOT}" -c release --show-bin-path)"
PRODUCT="${BIN_DIR}/${EXECUTABLE_PRODUCT}"
[[ -x "${PRODUCT}" ]] || die "Missing release executable at ${PRODUCT}"

rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${RESOURCES_DIR}"
cp "${PRODUCT}" "${APP_EXECUTABLE}"
cp "${PROJECT_ROOT}/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" \
    "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" \
    "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" \
    "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion ${MIN_MACOS}" \
    "${APP_BUNDLE}/Contents/Info.plist"

mkdir -p "${BUILD_DIR}"
swift "${PROJECT_ROOT}/tools/make_icon.swift" "${BUILD_DIR}"
cp "${BUILD_DIR}/${APP_NAME}.icns" "${RESOURCES_DIR}/${APP_NAME}.icns"

if [[ -d "${BIN_DIR}/${RESOURCE_BUNDLE_NAME}" ]]; then
    cp -R "${BIN_DIR}/${RESOURCE_BUNDLE_NAME}" "${RESOURCES_DIR}/"
fi

chmod +x "${APP_EXECUTABLE}"
log "Built ${APP_BUNDLE}"
