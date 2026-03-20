#!/bin/bash
# =============================================================================
# build-and-push.sh
# Builds all 3 profile Docker images and pushes to Docker Hub
#
# Usage:
#   ./build/build-and-push.sh
# =============================================================================

set -e

DOCKER_USER="sumanth17121988"
REPO="${DOCKER_USER}/multi-app-platform"

echo "============================================="
echo " Multi-App Platform — Build & Push"
echo " Registry : ${DOCKER_USER}"
echo "============================================="

# -----------------------------------------------------------------------------
# Step 1 — Docker Hub login
# -----------------------------------------------------------------------------
echo ""
echo "[1/5] Logging in to Docker Hub..."
docker login -u "${DOCKER_USER}"

# -----------------------------------------------------------------------------
# Step 2 — Build all 3 profile images
# -----------------------------------------------------------------------------
echo ""
echo "[2/5] Building profile-core..."
docker build --target profile-core \
  -t "${REPO}:core" \
  .

echo ""
echo "[3/5] Building profile-reporting..."
docker build --target profile-reporting \
  -t "${REPO}:reporting" \
  .

echo ""
echo "[4/5] Building profile-mobile..."
docker build --target profile-mobile \
  -t "${REPO}:mobile" \
  .

# -----------------------------------------------------------------------------
# Step 3 — Push all images
# -----------------------------------------------------------------------------
echo ""
echo "[5/5] Pushing all images to Docker Hub..."

docker push "${REPO}:core"
docker push "${REPO}:reporting"
docker push "${REPO}:mobile"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "============================================="
echo " Done. Images pushed:"
echo "   ${REPO}:core"
echo "   ${REPO}:reporting"
echo "   ${REPO}:mobile"
echo ""
echo " Verify at:"
echo "   https://hub.docker.com/r/${REPO}/tags"
echo "============================================="
