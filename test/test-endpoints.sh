#!/bin/bash
# =============================================================================
# test-endpoints.sh — Full endpoint test for multi-app-platform on EKS
# Usage: ./test/test-endpoints.sh
# =============================================================================

set +e

NODE_IP="52.91.155.184"   # Use either node — NodePort is available on both

CORE_PORT="32099"
REPORTING_PORT="32764"
MOBILE_PORT="32727"

CORE="http://${NODE_IP}:${CORE_PORT}"
REPORTING="http://${NODE_IP}:${REPORTING_PORT}"
MOBILE="http://${NODE_IP}:${MOBILE_PORT}"

PASS=0
FAIL=0

check() {
  local label="$1"
  local url="$2"
  local response
  local http_code

  http_code=$(curl -s -o /tmp/resp.json -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")

  if [ "$http_code" == "200" ]; then
    echo "  [PASS] ${label}"
    echo "         $(cat /tmp/resp.json)"
    PASS=$((PASS+1))
  else
    echo "  [FAIL] ${label} — HTTP ${http_code}"
    echo "         $(cat /tmp/resp.json)"
    FAIL=$((FAIL+1))
  fi
}

echo ""
echo "============================================="
echo " Multi-App Platform — Endpoint Tests"
echo " Node IP : ${NODE_IP}"
echo "============================================="

# -----------------------------------------------------------------------------
echo ""
echo "[1] Health Checks"
# -----------------------------------------------------------------------------
check "core    /healthz"     "${CORE}/healthz"
check "reporting /healthz"   "${REPORTING}/healthz"
check "mobile   /healthz"    "${MOBILE}/healthz"

# -----------------------------------------------------------------------------
echo ""
echo "[2] WAR Health Endpoints"
# -----------------------------------------------------------------------------
check "core nexus    /nexus/health"     "${CORE}/nexus/health"
check "core sentinel /sentinel/health"  "${CORE}/sentinel/health"
check "core carehub  /carehub/health"   "${CORE}/carehub/health"
check "core scheduler /scheduler/health" "${CORE}/scheduler/health"

check "reporting nexus     /nexus/health"     "${REPORTING}/nexus/health"
check "reporting sentinel  /sentinel/health"  "${REPORTING}/sentinel/health"
check "reporting scheduler /scheduler/health" "${REPORTING}/scheduler/health"

check "mobile nexus    /nexus/health"    "${MOBILE}/nexus/health"
check "mobile sentinel /sentinel/health" "${MOBILE}/sentinel/health"
check "mobile carehub  /carehub/health"  "${MOBILE}/carehub/health"

# -----------------------------------------------------------------------------
echo ""
echo "[3] Intra-Profile Routing (nexus → sentinel → WAR)"
# -----------------------------------------------------------------------------
check "core   nexus → carehub"    "${CORE}/nexus/route?target=carehub"
check "core   nexus → scheduler"  "${CORE}/nexus/route?target=scheduler"
check "reporting nexus → scheduler" "${REPORTING}/nexus/route?target=scheduler"
check "mobile nexus → carehub"    "${MOBILE}/nexus/route?target=carehub"

# -----------------------------------------------------------------------------
echo ""
echo "[4] Cross-Profile Routing (core → reporting/mobile via K8s DNS)"
# -----------------------------------------------------------------------------
check "core nexus → reporting pod" "${CORE}/nexus/cross-profile?to=reporting"
check "core nexus → mobile pod"    "${CORE}/nexus/cross-profile?to=mobile"

# -----------------------------------------------------------------------------
echo ""
echo "[5] End-to-End Full Chain (all 3 profiles in one call)"
# -----------------------------------------------------------------------------
echo ""
echo "  [RUN] GET ${CORE}/nexus/full-chain"
curl -s --max-time 30 "${CORE}/nexus/full-chain" | python3 -m json.tool
echo ""

# -----------------------------------------------------------------------------
echo ""
echo "============================================="
echo " Results: ${PASS} passed, ${FAIL} failed"
echo "============================================="
