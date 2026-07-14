#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

REMOTE="${GIT_TAG_REMOTE:-origin}"
TAG="v${VERSION}"
TAG_REF="refs/tags/${TAG}"
CHECK_ONLY=false

[[ -n "${VERSION}" ]] || die "VERSION is empty in build.conf."

usage() {
    cat <<EOF
Usage: $(basename "$0") [--check]

Create or update the annotated ${TAG} tag at HEAD and push only that tag.

  --check    Validate the release tree without creating or pushing the tag.

Set TAG_MESSAGE_FILE to a text file to use it as the complete annotated tag
message. Otherwise the tag message is "${APP_DISPLAY_NAME} v${VERSION}".
EOF
}

case "${1:-}" in
    "")
        ;;
    --check)
        CHECK_ONLY=true
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    *)
        usage >&2
        die "Unknown argument: $1"
        ;;
esac

[[ $# -le 1 ]] || {
    usage >&2
    die "Too many arguments."
}

cd "${PROJECT_ROOT}"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "${PROJECT_ROOT} is not a Git working tree."

git check-ref-format "${TAG_REF}" >/dev/null 2>&1 \
    || die "VERSION produces an invalid Git tag: ${TAG}"

RELEASE_COMMIT="${RELEASE_COMMIT:-HEAD}"
COMMIT="$(git rev-parse --verify --end-of-options "${RELEASE_COMMIT}^{commit}")" \
    || die "Could not resolve the release commit: ${RELEASE_COMMIT}"
SHORT_COMMIT="$(git rev-parse --short "${COMMIT}")"

WORKTREE_STATUS="$(git status --porcelain=v1 --untracked-files=normal)"
if [[ -n "${WORKTREE_STATUS}" ]]; then
    printf '%s\n' "${WORKTREE_STATUS}" >&2
    die "Release tree is not clean. Commit the changes before releasing so the tag matches the uploaded app."
fi

git remote get-url "${REMOTE}" >/dev/null 2>&1 \
    || die "Git remote '${REMOTE}' is not configured."

TAG_MESSAGE_FILE="${TAG_MESSAGE_FILE:-}"
if [[ -n "${TAG_MESSAGE_FILE}" ]]; then
    [[ -s "${TAG_MESSAGE_FILE}" ]] \
        || die "TAG_MESSAGE_FILE does not exist or is empty: ${TAG_MESSAGE_FILE}"
fi

# Verify remote access during release preflight, before spending time building,
# notarizing, and uploading. The final invocation reads it again immediately
# before the compare-and-swap push.
REMOTE_REFS="$(git ls-remote --tags "${REMOTE}" "${TAG_REF}")" \
    || die "Could not read ${TAG} from remote '${REMOTE}'."
REMOTE_TAG_OBJECT="$(
    awk -v ref="${TAG_REF}" '$2 == ref { print $1; exit }' <<<"${REMOTE_REFS}"
)"

if [[ "${CHECK_ONLY}" == true ]]; then
    log "Release tree is clean. ${TAG} will point to ${SHORT_COMMIT}."
    exit 0
fi

OLD_LOCAL_OBJECT="$(git rev-parse --verify --quiet "${TAG_REF}" || true)"

if [[ -n "${TAG_MESSAGE_FILE}" ]]; then
    git tag --force --annotate "${TAG}" "${COMMIT}" --file "${TAG_MESSAGE_FILE}"
else
    git tag --force --annotate "${TAG}" "${COMMIT}" \
        --message "${APP_DISPLAY_NAME} v${VERSION}"
fi

if [[ -n "${REMOTE_TAG_OBJECT}" ]]; then
    LEASE="--force-with-lease=${TAG_REF}:${REMOTE_TAG_OBJECT}"
else
    LEASE="--force-with-lease=${TAG_REF}:"
fi

if ! git push "${LEASE}" "${REMOTE}" "${TAG_REF}:${TAG_REF}"; then
    if [[ -n "${OLD_LOCAL_OBJECT}" ]]; then
        git update-ref "${TAG_REF}" "${OLD_LOCAL_OBJECT}"
    else
        git update-ref -d "${TAG_REF}"
    fi
    die "Could not push ${TAG}; restored the previous local tag."
fi

if [[ -z "${REMOTE_TAG_OBJECT}" ]]; then
    log "Created ${TAG} at ${SHORT_COMMIT} and pushed it to ${REMOTE}."
else
    log "Updated ${TAG} at ${SHORT_COMMIT} and pushed it to ${REMOTE}."
fi
