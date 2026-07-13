#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

[[ -f "${DMG_PATH}" ]] || die "Missing DMG. Run make dmg first."

# Wrangler 4.110 requires Node 22+. This machine's Homebrew Node satisfies it
# without changing the shell's global/asdf Node selection.
if [[ -x /opt/homebrew/opt/node/bin/node ]]; then
    export PATH="/opt/homebrew/opt/node/bin:${PATH}"
fi

WRANGLER="${PROJECT_ROOT}/site/node_modules/.bin/wrangler"
[[ -x "${WRANGLER}" ]] \
    || die "Wrangler is missing. Run npm install in ${PROJECT_ROOT}/site."

R2_PREFIX="${R2_PATH%/}"
VERSIONED_KEY="${R2_PREFIX}/$(basename "${DMG_PATH}")"
LATEST_KEY="${R2_PREFIX}/${APP_NAME}_latest.dmg"

upload_dmg() {
    local key="$1"
    local filename="$2"
    log "Uploading ${DMG_PATH} to r2://${R2_BUCKET}/${key}"
    "${WRANGLER}" r2 object put "${R2_BUCKET}/${key}" \
        --file "${DMG_PATH}" \
        --content-type application/x-apple-diskimage \
        --content-disposition "attachment; filename=${filename}" \
        --cache-control "public, max-age=300" \
        --remote
}

upload_dmg "${VERSIONED_KEY}" "$(basename "${DMG_PATH}")"
upload_dmg "${LATEST_KEY}" "${APP_NAME}.dmg"

log "Uploaded r2://${R2_BUCKET}/${VERSIONED_KEY}"
log "Uploaded r2://${R2_BUCKET}/${LATEST_KEY}"
