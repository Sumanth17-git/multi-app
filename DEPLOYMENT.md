# Deployment Guide

## Prerequisites

| Tool    | Version | Purpose                  |
|---------|---------|--------------------------|
| Docker  | 20.10+  | Build and push images    |
| kubectl | 1.25+   | Interact with Kubernetes |
| Helm    | 3.10+   | Deploy chart             |

---

## PART A — Build and Push Images to Docker Hub

### A1. Login to Docker Hub

```bash
docker login -u sumanth17121988
```

### A2. Clone the repository

```bash
git clone https://github.com/Sumanth17-git/multi-app.git
cd multi-app
```

### A3. Build all 3 profile images

```bash
# core — nexus + sentinel + carehub + scheduler (4 WARs)
docker build --target profile-core      -t sumanth17121988/platform:core      .

# reporting — nexus + sentinel + scheduler (3 WARs)
docker build --target profile-reporting -t sumanth17121988/platform:reporting .

# mobile — nexus + sentinel + carehub (3 WARs)
docker build --target profile-mobile    -t sumanth17121988/platform:mobile    .

# Verify
docker images sumanth17121988/platform
```

### A4. Push to Docker Hub

```bash
docker push sumanth17121988/platform:core
docker push sumanth17121988/platform:reporting
docker push sumanth17121988/platform:mobile
```

Verify at: https://hub.docker.com/r/sumanth17121988/platform/tags

---

## PART B — Deploy to Kubernetes

### B1. Verify kubectl is pointing to your cluster

```bash
kubectl cluster-info
kubectl get nodes
```

### B2. Install Helm (if not installed)

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### B3. Deploy with Helm

```bash
cd ~/multi-app

helm install platform ./helm/multi-app-platform \
  --namespace platform \
  --create-namespace

# Watch pods come up
kubectl get pods -n platform -w
```

Expected (all 3 must reach 1/1 Running):
```
NAME                                                   READY   STATUS    RESTARTS
platform-multi-app-platform-core-xxxxx                 1/1     Running   0
platform-multi-app-platform-reporting-xxxxx            1/1     Running   0
platform-multi-app-platform-mobile-xxxxx               1/1     Running   0
```

### B4. Verify all resources

```bash
kubectl get deployments -n platform
kubectl get services   -n platform
kubectl get ingress    -n platform
```

---

## PART C — Testing

### C1. Port-forward services

```bash
kubectl port-forward svc/platform-multi-app-platform-core      8001:80 -n platform &
kubectl port-forward svc/platform-multi-app-platform-reporting 8002:80 -n platform &
kubectl port-forward svc/platform-multi-app-platform-mobile    8003:80 -n platform &

sleep 2
```

### C2. Health checks

```bash
curl http://localhost:8001/healthz
curl http://localhost:8002/healthz
curl http://localhost:8003/healthz
```

### C3. Intra-profile chains

```bash
# core: nexus → sentinel → carehub
curl "http://localhost:8001/nexus/route?target=carehub"

# core: nexus → sentinel → scheduler
curl "http://localhost:8001/nexus/route?target=scheduler"

# reporting: nexus → sentinel → scheduler
curl "http://localhost:8002/nexus/route?target=scheduler"

# mobile: nexus → sentinel → carehub
curl "http://localhost:8003/nexus/route?target=carehub"
```

### C4. Cross-profile chains

```bash
# core nexus → reporting pod (sentinel → scheduler)
curl "http://localhost:8001/nexus/cross-profile?to=reporting"

# core nexus → mobile pod (sentinel → carehub)
curl "http://localhost:8001/nexus/cross-profile?to=mobile"
```

### C5. End-to-end API — all 3 profiles in one call

```bash
curl http://localhost:8001/nexus/full-chain | python3 -m json.tool
```

### C6. Inspect pod internals

```bash
CORE_POD=$(kubectl get pod -n platform -l app.kubernetes.io/component=core -o jsonpath='{.items[0].metadata.name}')

# Check baked server.xml
kubectl exec -n platform ${CORE_POD} -- cat /opt/tomcat/conf/server.xml

# Check baked NGINX conf
kubectl exec -n platform ${CORE_POD} -- cat /etc/nginx/conf.d/platform.conf

# Check env vars (PROFILE, SERVICE_URL, CATALINA_OPTS)
kubectl exec -n platform ${CORE_POD} -- env | grep -E 'PROFILE|SERVICE_URL|CATALINA'

# Check running processes
kubectl exec -n platform ${CORE_POD} -- ps aux
```

### C7. Pod logs

```bash
kubectl logs -f -n platform -l app.kubernetes.io/component=core
kubectl logs -f -n platform -l app.kubernetes.io/component=reporting
kubectl logs -f -n platform -l app.kubernetes.io/component=mobile
```

---

## PART D — Upgrade

```bash
# After building and pushing a new image version
helm upgrade platform ./helm/multi-app-platform \
  --namespace platform

kubectl rollout status deployment/platform-multi-app-platform-core      -n platform
kubectl rollout status deployment/platform-multi-app-platform-reporting  -n platform
kubectl rollout status deployment/platform-multi-app-platform-mobile     -n platform
```

## PART E — Rollback

```bash
helm rollback platform --namespace platform
helm history platform  --namespace platform
```

## PART F — Cleanup

```bash
helm uninstall platform --namespace platform
kubectl delete namespace platform
```

---

## Troubleshooting

| Problem | Command |
|---|---|
| Pod stuck in `Pending` | `kubectl describe pod -n platform <pod-name>` |
| Pod in `CrashLoopBackOff` | `kubectl logs -n platform <pod-name>` |
| Image pull error | `kubectl describe pod -n platform <pod-name> \| grep -A5 Events` |
| Port-forward refused | `kubectl get svc -n platform` |
| Helm release exists | `helm uninstall platform -n platform` then reinstall |
