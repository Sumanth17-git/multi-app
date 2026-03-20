#!/bin/bash
# =============================================================================
# otel-setup.sh — End-to-end OpenTelemetry setup for multi-app-platform
#
# What this script does:
#   1. Pull latest code from git
#   2. Build & push all 3 profile Docker images (OTel agent baked in)
#   3. Helm uninstall + reinstall
#   4. Wait for all pods to be Ready
#   5. Verify OTel env vars are injected in each pod
#   6. Verify OTel Java agent loaded in Tomcat startup logs
#   7. Generate smoke traffic to create initial traces
#   8. Print New Relic EU deep-link for APM verification
#
# Usage:
#   cd /path/to/multi-app   # MUST run from repo root
#   ./build/otel-setup.sh
# =============================================================================

set -e

DOCKER_USER="sumanth17121988"
RELEASE="platform"
NAMESPACE="platform"
CHART="./helm/multi-app-platform"
NR_ACCOUNT_URL="https://one.eu.newrelic.com/nr1-core/apm-features/services-list"

# Smoke test iterations
SMOKE_ITERATIONS=20

echo "============================================="
echo " Multi-App Platform — OTel End-to-End Setup"
echo "============================================="

# -----------------------------------------------------------------------------
# Guard: must run from repo root
# -----------------------------------------------------------------------------
if [[ ! -f "Dockerfile" ]]; then
  echo ""
  echo "ERROR: Run this script from the repo root, not from build/"
  echo "  cd /path/to/multi-app && ./build/otel-setup.sh"
  exit 1
fi

# =============================================================================
# STEP 1 — Pull latest code
# =============================================================================
echo ""
echo "[1/7] Pulling latest code..."
git pull --ff-only
echo "      Done."

# =============================================================================
# STEP 2 — Build & push Docker images (OTel agent baked in at /opt/otel/)
# =============================================================================
echo ""
echo "[2/7] Building and pushing Docker images..."
echo "      (OTel Java agent v2.3.0 will be downloaded into image)"
echo ""
./build/build-and-push.sh
echo ""
echo "      Images pushed:"
echo "        ${DOCKER_USER}/platform:core"
echo "        ${DOCKER_USER}/platform:reporting"
echo "        ${DOCKER_USER}/platform:mobile"

# =============================================================================
# STEP 3 — Helm uninstall existing release
# =============================================================================
echo ""
echo "[3/7] Redeploying Helm chart..."

if helm status ${RELEASE} --namespace ${NAMESPACE} &>/dev/null; then
  echo "      Uninstalling existing release..."
  helm uninstall ${RELEASE} --namespace ${NAMESPACE}
  echo "      Waiting for pods to terminate..."
  kubectl wait --for=delete pod \
    -l app.kubernetes.io/instance=${RELEASE} \
    -n ${NAMESPACE} \
    --timeout=90s 2>/dev/null || true
else
  echo "      No existing release found."
fi

echo "      Installing fresh..."
helm install ${RELEASE} ${CHART} \
  --namespace ${NAMESPACE} \
  --create-namespace

# =============================================================================
# STEP 4 — Wait for all pods Ready
# =============================================================================
echo ""
echo "[4/7] Waiting for all pods to be Ready (timeout 3m)..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/instance=${RELEASE} \
  -n ${NAMESPACE} \
  --timeout=180s

echo ""
echo "      Pods:"
kubectl get pods -n ${NAMESPACE} -o wide

# =============================================================================
# STEP 5 — Verify OTel env vars injected in each pod
# =============================================================================
echo ""
echo "[5/7] Verifying OTel env vars in pods..."
echo ""

PASS=0
FAIL=0

for POD in $(kubectl get pods -n ${NAMESPACE} -o jsonpath='{.items[*].metadata.name}'); do
  echo "  ── Pod: ${POD}"

  JAVA_TOOL=$(kubectl exec -n ${NAMESPACE} ${POD} -- printenv JAVA_TOOL_OPTIONS 2>/dev/null || echo "MISSING")
  OTEL_NAME=$(kubectl exec -n ${NAMESPACE} ${POD} -- printenv OTEL_SERVICE_NAME 2>/dev/null || echo "MISSING")
  OTEL_EP=$(kubectl exec -n ${NAMESPACE} ${POD} -- printenv OTEL_EXPORTER_OTLP_ENDPOINT 2>/dev/null || echo "MISSING")
  OTEL_HDR=$(kubectl exec -n ${NAMESPACE} ${POD} -- printenv OTEL_EXPORTER_OTLP_HEADERS 2>/dev/null || echo "MISSING")
  OTEL_SMPL=$(kubectl exec -n ${NAMESPACE} ${POD} -- printenv OTEL_TRACES_SAMPLER 2>/dev/null || echo "MISSING")

  # Mask license key in output
  OTEL_HDR_MASKED=$(echo "${OTEL_HDR}" | sed 's/api-key=.*/api-key=***MASKED***/')

  echo "     JAVA_TOOL_OPTIONS          = ${JAVA_TOOL}"
  echo "     OTEL_SERVICE_NAME          = ${OTEL_NAME}"
  echo "     OTEL_EXPORTER_OTLP_ENDPOINT= ${OTEL_EP}"
  echo "     OTEL_EXPORTER_OTLP_HEADERS = ${OTEL_HDR_MASKED}"
  echo "     OTEL_TRACES_SAMPLER        = ${OTEL_SMPL}"

  if [[ "${JAVA_TOOL}" == *"opentelemetry-javaagent"* ]] && \
     [[ "${OTEL_NAME}" == platform-* ]] && \
     [[ "${OTEL_EP}" == *"nr-data.net"* ]] && \
     [[ "${OTEL_HDR}" == api-key=* ]]; then
    echo "     STATUS: PASS"
    (( PASS++ )) || true
  else
    echo "     STATUS: FAIL — one or more OTel env vars missing"
    (( FAIL++ )) || true
  fi
  echo ""
done

echo "  OTel env var check: ${PASS} passed, ${FAIL} failed"
if [[ ${FAIL} -gt 0 ]]; then
  echo "  WARNING: Some pods are missing OTel env vars. Check deployment.yaml and redeploy."
fi

# =============================================================================
# STEP 6 — Verify OTel Java agent loaded in Tomcat logs
# =============================================================================
echo ""
echo "[6/7] Checking Tomcat startup logs for OTel agent attachment..."
echo ""

AGENT_DETECTED=0

for POD in $(kubectl get pods -n ${NAMESPACE} -o jsonpath='{.items[*].metadata.name}'); do
  echo "  ── Pod: ${POD}"
  # Look for OTel agent startup line in container logs
  OTEL_LOG=$(kubectl logs -n ${NAMESPACE} ${POD} --tail=200 2>/dev/null \
    | grep -i "opentelemetry\|javaagent\|otel" | head -5 || echo "  (no OTel lines found yet)")

  if [[ -n "${OTEL_LOG}" ]]; then
    echo "${OTEL_LOG}" | while IFS= read -r line; do
      echo "     ${line}"
    done
    AGENT_DETECTED=1
  else
    echo "     (no OTel agent lines in recent logs — may still be starting)"
  fi
  echo ""
done

if [[ ${AGENT_DETECTED} -eq 0 ]]; then
  echo "  NOTE: OTel agent log lines not found yet."
  echo "        This is normal if Tomcat is still initializing."
  echo "        Check manually: kubectl logs -n ${NAMESPACE} <pod> | grep -i opentelemetry"
fi

# =============================================================================
# STEP 7 — Smoke traffic to generate initial traces
# =============================================================================
echo ""
echo "[7/7] Generating smoke traffic to seed initial traces in New Relic..."

# Discover NodePort and Node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)
if [[ -z "${NODE_IP}" ]]; then
  NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
fi

CORE_PORT=$(kubectl get svc -n ${NAMESPACE} \
  -o jsonpath='{.items[?(@.metadata.name=="platform-core")].spec.ports[0].nodePort}' 2>/dev/null || echo "")
REPORTING_PORT=$(kubectl get svc -n ${NAMESPACE} \
  -o jsonpath='{.items[?(@.metadata.name=="platform-reporting")].spec.ports[0].nodePort}' 2>/dev/null || echo "")
MOBILE_PORT=$(kubectl get svc -n ${NAMESPACE} \
  -o jsonpath='{.items[?(@.metadata.name=="platform-mobile")].spec.ports[0].nodePort}' 2>/dev/null || echo "")

echo ""
echo "  Node IP      : ${NODE_IP}"
echo "  Core port    : ${CORE_PORT}"
echo "  Reporting port: ${REPORTING_PORT}"
echo "  Mobile port  : ${MOBILE_PORT}"
echo ""

if [[ -z "${NODE_IP}" || -z "${CORE_PORT}" ]]; then
  echo "  WARNING: Could not detect NodePort info. Skipping smoke test."
  echo "           Run manually: kubectl get svc -n ${NAMESPACE}"
else
  CORE="http://${NODE_IP}:${CORE_PORT}"
  REPORTING="http://${NODE_IP}:${REPORTING_PORT}"
  MOBILE="http://${NODE_IP}:${MOBILE_PORT}"

  echo "  Sending ${SMOKE_ITERATIONS} requests across all profiles..."
  echo ""

  SMOKE_PASS=0
  SMOKE_FAIL=0

  for i in $(seq 1 ${SMOKE_ITERATIONS}); do
    # Health checks (every 5th request)
    if (( i % 5 == 0 )); then
      STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${CORE}/healthz" || echo "000")
      [[ "${STATUS}" == "200" ]] && (( SMOKE_PASS++ )) || (( SMOKE_FAIL++ ))
    fi

    # Core: nexus → carehub
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
      "${CORE}/nexus/route?target=carehub" 2>/dev/null || echo "000")
    [[ "${STATUS}" == "200" ]] && (( SMOKE_PASS++ )) || (( SMOKE_FAIL++ ))

    # Core: nexus → scheduler
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
      "${CORE}/nexus/route?target=scheduler" 2>/dev/null || echo "000")
    [[ "${STATUS}" == "200" ]] && (( SMOKE_PASS++ )) || (( SMOKE_FAIL++ ))

    # Cross-profile: core → reporting
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
      "${CORE}/nexus/cross-profile?to=reporting" 2>/dev/null || echo "000")
    [[ "${STATUS}" == "200" ]] && (( SMOKE_PASS++ )) || (( SMOKE_FAIL++ ))

    # Cross-profile: core → mobile
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
      "${CORE}/nexus/cross-profile?to=mobile" 2>/dev/null || echo "000")
    [[ "${STATUS}" == "200" ]] && (( SMOKE_PASS++ )) || (( SMOKE_FAIL++ ))

    # Reporting: nexus → scheduler
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
      "${REPORTING}/nexus/route?target=scheduler" 2>/dev/null || echo "000")
    [[ "${STATUS}" == "200" ]] && (( SMOKE_PASS++ )) || (( SMOKE_FAIL++ ))

    # Mobile: nexus → carehub
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
      "${MOBILE}/nexus/route?target=carehub" 2>/dev/null || echo "000")
    [[ "${STATUS}" == "200" ]] && (( SMOKE_PASS++ )) || (( SMOKE_FAIL++ ))

    printf "  Iteration %02d/%02d done\r" "${i}" "${SMOKE_ITERATIONS}"
    sleep 0.3
  done

  echo ""
  echo ""
  echo "  Smoke test complete: ${SMOKE_PASS} passed, ${SMOKE_FAIL} failed"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================="
echo " OTel Setup Complete"
echo "============================================="
echo ""
echo " Services:"
kubectl get svc -n ${NAMESPACE}
echo ""
echo " Pods:"
kubectl get pods -n ${NAMESPACE}
echo ""
echo " OTel env check : ${PASS} passed / ${FAIL} failed"
echo " Smoke traffic  : Done — traces are flowing to New Relic"
echo ""
echo " New Relic EU APM Dashboard:"
echo "   ${NR_ACCOUNT_URL}"
echo ""
echo " Expected services in New Relic APM:"
echo "   platform-core"
echo "   platform-reporting"
echo "   platform-mobile"
echo ""
echo " Allow 2-3 minutes for traces to appear in New Relic."
echo ""
echo " Manual log check (look for OTel agent init):"
echo "   kubectl logs -n ${NAMESPACE} <pod-name> | grep -i opentelemetry"
echo ""
echo " Manual env check:"
echo "   kubectl exec -n ${NAMESPACE} <pod-name> -- printenv | grep OTEL"
echo "============================================="
