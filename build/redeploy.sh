#!/bin/bash
# =============================================================================
# redeploy.sh — Uninstall and reinstall the Helm chart
# Usage: ./build/redeploy.sh
# =============================================================================

set -e

RELEASE="platform"
NAMESPACE="platform"
CHART="./helm/multi-app-platform"

echo "============================================="
echo " Multi-App Platform — Redeploy"
echo " Release   : ${RELEASE}"
echo " Namespace : ${NAMESPACE}"
echo "============================================="

# -----------------------------------------------------------------------------
# Step 1 — Uninstall existing release
# -----------------------------------------------------------------------------
echo ""
echo "[1/4] Uninstalling existing Helm release..."
if helm status ${RELEASE} --namespace ${NAMESPACE} &>/dev/null; then
  helm uninstall ${RELEASE} --namespace ${NAMESPACE}
  echo "      Uninstalled."
else
  echo "      No existing release found, skipping."
fi

# -----------------------------------------------------------------------------
# Step 2 — Wait for pods to terminate
# -----------------------------------------------------------------------------
echo ""
echo "[2/4] Waiting for pods to terminate..."
kubectl wait --for=delete pod \
  -l app.kubernetes.io/instance=${RELEASE} \
  -n ${NAMESPACE} \
  --timeout=60s 2>/dev/null || true
echo "      Done."

# -----------------------------------------------------------------------------
# Step 3 — Install fresh
# -----------------------------------------------------------------------------
echo ""
echo "[3/4] Installing Helm chart..."
helm install ${RELEASE} ${CHART} \
  --namespace ${NAMESPACE} \
  --create-namespace

# -----------------------------------------------------------------------------
# Step 4 — Wait for pods to be ready
# -----------------------------------------------------------------------------
echo ""
echo "[4/4] Waiting for all pods to be ready..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/instance=${RELEASE} \
  -n ${NAMESPACE} \
  --timeout=120s

echo ""
echo "============================================="
echo " All pods ready. Services:"
kubectl get svc -n ${NAMESPACE}
echo ""
echo " Node IP:"
kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}'
echo ""
echo "============================================="
