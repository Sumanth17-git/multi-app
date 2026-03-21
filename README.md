# Multi-App Platform — Deployment Guide

## Prerequisites
- EKS cluster running with `kubectl` configured
- Helm 3 installed
- Docker logged in to Docker Hub (`docker login`)
- AWS CLI configured

---

## Full Deployment (Fresh Environment)

### Step 1 — Clean up any manually created RBAC (if exists)
```bash
kubectl delete serviceaccount otel-collector -n platform 2>/dev/null || true
kubectl delete clusterrolebinding otel-collector 2>/dev/null || true
kubectl delete clusterrole otel-collector 2>/dev/null || true
```

### Step 2 — Install OTel Collector DaemonSet
```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
helm install otel-collector open-telemetry/opentelemetry-collector \
  -f helm/otel-collector-values.yaml \
  --namespace platform \
  --create-namespace
```

### Step 3 — Build & push images
```bash
./build/build-and-push.sh
```

### Step 4 — Install app
```bash
helm install platform ./helm/multi-app-platform \
  --namespace platform \
  --create-namespace
```

### Step 5 — Verify OTel env vars in all pods
```bash
for profile in core reporting mobile; do
  echo "=== platform-$profile ==="
  kubectl exec -n platform deploy/platform-multi-app-platform-$profile -- printenv | grep OTEL
  echo ""
done
```

Expected for each profile:
```
JAVA_TOOL_OPTIONS=-javaagent:/opt/otel/opentelemetry-javaagent.jar
OTEL_SERVICE_NAME=platform-<profile>
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector-opentelemetry-collector.platform.svc.cluster.local:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_PROPAGATORS=tracecontext,baggage
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.10
OTEL_RESOURCE_ATTRIBUTES=profile=<profile>,team=platform
OTEL_LOGS_EXPORTER=otlp
OTEL_METRICS_EXPORTER=otlp
OTEL_SEMCONV_STABILITY_OPT_IN=http/dup
```

### Step 6 — Wait for all pods ready
```bash
kubectl rollout status deployment -n platform --timeout=3m
kubectl get pods -n platform
```

### Step 7 — Generate smoke traffic
```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')
for i in $(seq 1 50); do
  curl -s -o /dev/null http://${NODE_IP}:31000/nexus/route?target=carehub
  curl -s -o /dev/null http://${NODE_IP}:31000/nexus/cross-profile?to=reporting
  curl -s -o /dev/null http://${NODE_IP}:31001/nexus/route?target=scheduler
  curl -s -o /dev/null http://${NODE_IP}:31002/nexus/route?target=carehub
done
```

---

## Redeployment (Code or Helm Changes Only)

```bash
# App only (no image rebuild)
helm upgrade platform ./helm/multi-app-platform --namespace platform

# Collector only (if otel-collector-values.yaml changed)
helm upgrade otel-collector open-telemetry/opentelemetry-collector \
  --namespace platform \
  -f ./helm/otel-collector-values.yaml

# Both app + new images
./build/build-and-push.sh
helm upgrade platform ./helm/multi-app-platform --namespace platform
```

---

## Run Tests
```bash
./test/test-endpoints.sh
```

---

## Script Reference

| Script | When to use |
|--------|-------------|
| `./build/build-and-push.sh` | Code or Dockerfile changed — build all 3 profile images and push to Docker Hub |
| `./build/build-all.sh` | Local build only, no push (inspect layers, test locally) |
| `./build/redeploy.sh` | Helm chart/values changed only — uninstall + reinstall app |
| `./build/otel-setup.sh` | Full end-to-end setup from scratch including smoke tests |

---

## NodePorts

| Profile | NodePort |
|---------|----------|
| core | 31000 |
| reporting | 31001 |
| mobile | 31002 |

---

## New Relic APM

Services appear under: **APM & Services → Services - OpenTelemetry**

| Service | Description |
|---------|-------------|
| `platform-core` | Core profile (nexus, sentinel, carehub, scheduler WARs) |
| `platform-reporting` | Reporting profile |
| `platform-mobile` | Mobile profile |
