#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_ROOT}/build.conf"

DIST_DIR="${PROJECT_ROOT}/dist"
BUILD_DIR="${DIST_DIR}/build"
OUTPUT_DIR="${DIST_DIR}/output"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
APP_EXECUTABLE="${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"
RESOURCES_DIR="${APP_BUNDLE}/Contents/Resources"
DMG_PATH="${OUTPUT_DIR}/${APP_NAME}_v${VERSION}.dmg"
ZIP_PATH="${OUTPUT_DIR}/${APP_NAME}_v${VERSION}.zip"

log() {
    printf '\033[0;32m%s\033[0m\n' "$*"
}

warn() {
    printf '\033[1;33m%s\033[0m\n' "$*" >&2
}

die() {
    printf '\033[0;31m%s\033[0m\n' "$*" >&2
    exit 1
}
