#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

[[ -d "${APP_BUNDLE}" ]] || die "Missing app bundle. Run make dist-build first."

codesign --force --deep --sign "${MAC_SIGNING_IDENTITY}" \
    --timestamp --options runtime "${APP_BUNDLE}"
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

log "Signed ${APP_BUNDLE}"
