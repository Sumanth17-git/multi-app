#!/bin/bash
# =============================================================================
# build-and-push.sh
# Builds all 3 profile Docker images and pushes to Docker Hub
#
# Usage:
#   ./build/build-and-push.sh
#   ./build/build-and-push.sh 1.0.1        # custom tag
# =============================================================================

set -e

DOCKER_USER="sumanth17121988"
REPO="${DOCKER_USER}/platform"
TAG="${1:-latest}"

echo "============================================="
echo " Multi-App Platform — Build & Push"
echo " Registry : ${DOCKER_USER}"
echo " Tag      : ${TAG}"
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
  -t "${REPO}:core-${TAG}" \
  .

echo ""
echo "[3/5] Building profile-reporting..."
docker build --target profile-reporting \
  -t "${REPO}:reporting" \
  -t "${REPO}:reporting-${TAG}" \
  .

echo ""
echo "[4/5] Building profile-mobile..."
docker build --target profile-mobile \
  -t "${REPO}:mobile" \
  -t "${REPO}:mobile-${TAG}" \
  .

# -----------------------------------------------------------------------------
# Step 3 — Push all images
# -----------------------------------------------------------------------------
echo ""
echo "[5/5] Pushing all images to Docker Hub..."

docker push "${REPO}:core"
docker push "${REPO}:core-${TAG}"

docker push "${REPO}:reporting"
docker push "${REPO}:reporting-${TAG}"

docker push "${REPO}:mobile"
docker push "${REPO}:mobile-${TAG}"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "============================================="
echo " Done. Images pushed:"
echo "   ${REPO}:core"
echo "   ${REPO}:core-${TAG}"
echo "   ${REPO}:reporting"
echo "   ${REPO}:reporting-${TAG}"
echo "   ${REPO}:mobile"
echo "   ${REPO}:mobile-${TAG}"
echo ""
echo " Verify at:"
echo "   https://hub.docker.com/r/${REPO}/tags"
echo "============================================="
