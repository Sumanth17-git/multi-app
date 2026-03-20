#!/bin/bash
# =============================================================================
# build-all.sh — Build all 3 profile images
#
# Usage:
#   ./build/build-all.sh              # builds all 3 profiles
#   ./build/build-all.sh core         # builds only core
#   ./build/build-all.sh reporting    # builds only reporting
#   ./build/build-all.sh mobile       # builds only mobile
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
TARGET="${1:-all}"
IMAGE_NAME="platform"

build_profile() {
    local PROFILE="$1"
    echo "=== Building image: ${IMAGE_NAME}:${PROFILE} ==="
    docker build \
        --target "profile-${PROFILE}" \
        --build-arg PROFILE="${PROFILE}" \
        -t "${IMAGE_NAME}:${PROFILE}" \
        "${PROJECT_ROOT}"
    echo "=== Done: ${IMAGE_NAME}:${PROFILE} ==="
}

case "${TARGET}" in
    core|reporting|mobile)
        build_profile "${TARGET}"
        ;;
    all)
        build_profile core
        build_profile reporting
        build_profile mobile
        echo ""
        echo "All images built:"
        docker images "${IMAGE_NAME}" --format "  {{.Repository}}:{{.Tag}}  ({{.Size}})"
        ;;
    *)
        echo "Usage: $0 [core|reporting|mobile|all]"
        exit 1
        ;;
esac
