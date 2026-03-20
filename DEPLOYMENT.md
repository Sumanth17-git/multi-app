# Deployment Guide

## Prerequisites

| Tool       | Version  | Purpose                        |
|------------|----------|--------------------------------|
| Docker     | 20.10+   | Build images                   |
| Maven      | 3.8+     | Build WARs (inside Docker)     |
| kubectl    | 1.25+    | Interact with Kubernetes       |
| Helm       | 3.10+    | Deploy chart                   |
| kind       | 0.20+    | Local Kubernetes cluster       |
| AWS CLI    | 2.x      | ECR login (EKS only)           |

---

## PART A — Local Kubernetes (kind)

### A1. Create kind cluster

```bash
kind create cluster --name platform --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
EOF
```

### A2. Install NGINX Ingress Controller

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/kind/deploy.yaml

# Wait for it to be ready
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s
```

### A3. Build Docker images

```bash
cd c:/Users/Santosh/Documents/multi-app

docker build --target profile-core      -t platform:core      .
docker build --target profile-reporting -t platform:reporting .
docker build --target profile-mobile    -t platform:mobile    .

# Verify
docker images platform
```

### A4. Load images into kind

```bash
kind load docker-image platform:core      --name platform
kind load docker-image platform:reporting --name platform
kind load docker-image platform:mobile    --name platform
```

### A5. Deploy with Helm

```bash
helm install platform ./helm/multi-app-platform \
  -f ./helm/multi-app-platform/values/values-dev.yaml \
  --namespace platform \
  --create-namespace

# Watch pods come up (wait for all 3 to be Running)
kubectl get pods -n platform -w
```

Expected output:
```
NAME                                                    READY   STATUS    RESTARTS
platform-multi-app-platform-core-xxxxx                  1/1     Running   0
platform-multi-app-platform-reporting-xxxxx             1/1     Running   0
platform-multi-app-platform-mobile-xxxxx                1/1     Running   0
```

### A6. Verify all resources

```bash
kubectl get all -n platform
kubectl get ingress -n platform
```

---

## PART B — EKS (Production)

### B1. Create ECR repositories

```bash
AWS_ACCOUNT=123456789012
AWS_REGION=us-east-1

for profile in core reporting mobile; do
  aws ecr create-repository \
    --repository-name platform/${profile} \
    --region ${AWS_REGION}
done
```

### B2. Build and push images to ECR

```bash
AWS_ACCOUNT=123456789012
AWS_REGION=us-east-1
ECR=${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com

# Login
aws ecr get-login-password --region ${AWS_REGION} \
  | docker login --username AWS --password-stdin ${ECR}

# Build
cd c:/Users/Santosh/Documents/multi-app
docker build --target profile-core      -t ${ECR}/platform/core:1.0.0      .
docker build --target profile-reporting -t ${ECR}/platform/reporting:1.0.0 .
docker build --target profile-mobile    -t ${ECR}/platform/mobile:1.0.0    .

# Push
docker push ${ECR}/platform/core:1.0.0
docker push ${ECR}/platform/reporting:1.0.0
docker push ${ECR}/platform/mobile:1.0.0
```

### B3. Update values-prod.yaml

Edit `helm/multi-app-platform/values/values-prod.yaml`:
```yaml
global:
  imageRegistry: "123456789012.dkr.ecr.us-east-1.amazonaws.com"

profiles:
  core:
    image:
      repository: platform/core
      tag: "1.0.0"
  reporting:
    image:
      repository: platform/reporting
      tag: "1.0.0"
  mobile:
    image:
      repository: platform/mobile
      tag: "1.0.0"
```

### B4. Configure kubectl for EKS

```bash
aws eks update-kubeconfig \
  --region us-east-1 \
  --name your-cluster-name
```

### B5. Deploy with Helm

```bash
helm install platform ./helm/multi-app-platform \
  -f ./helm/multi-app-platform/values/values-prod.yaml \
  --namespace platform \
  --create-namespace

kubectl get pods -n platform -w
```

---

## PART C — Testing

### C1. Set up access (Local kind)

```bash
# Port-forward each profile service
kubectl port-forward svc/platform-multi-app-platform-core      8001:80 -n platform &
kubectl port-forward svc/platform-multi-app-platform-reporting 8002:80 -n platform &
kubectl port-forward svc/platform-multi-app-platform-mobile    8003:80 -n platform &
```

For EKS use the ALB DNS or real hostnames instead of localhost ports.

---

### C2. Health checks

```bash
# NGINX health (all 3 profiles)
curl http://localhost:8001/healthz   # {"status":"UP","profile":"core"}
curl http://localhost:8002/healthz   # {"status":"UP","profile":"reporting"}
curl http://localhost:8003/healthz   # {"status":"UP","profile":"mobile"}
```

---

### C3. Individual WAR endpoints

```bash
# core — all 4 WARs
curl http://localhost:8001/nexus/health
curl http://localhost:8001/nexus/info
curl http://localhost:8001/sentinel/health
curl http://localhost:8001/sentinel/validate
curl http://localhost:8001/carehub/health
curl http://localhost:8001/carehub/records
curl http://localhost:8001/scheduler/health
curl http://localhost:8001/scheduler/appointments

# reporting — nexus + sentinel + scheduler only
curl http://localhost:8002/nexus/health
curl http://localhost:8002/scheduler/appointments
curl http://localhost:8002/carehub/health      # expects 404

# mobile — nexus + sentinel + carehub only
curl http://localhost:8003/nexus/health
curl http://localhost:8003/carehub/records
curl http://localhost:8003/scheduler/health    # expects 404
```

---

### C4. Intra-profile chain (nexus → sentinel → data WAR)

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

---

### C5. Inter-profile chain (cross-profile via K8s Service DNS)

```bash
# core nexus calls reporting pod (nexus → sentinel → scheduler)
curl "http://localhost:8001/nexus/cross-profile?to=reporting"

# core nexus calls mobile pod (nexus → sentinel → carehub)
curl "http://localhost:8001/nexus/cross-profile?to=mobile"
```

---

### C6. THE end-to-end API — all 3 profiles in one call

```bash
curl http://localhost:8001/nexus/full-chain
```

Expected response structure:
```json
{
  "endpoint"   : "/nexus/full-chain",
  "calledFrom" : "core",
  "elapsedMs"  : 95,
  "ts"         : "2026-03-20T10:00:00Z",

  "core": {
    "profile"  : "core",
    "type"     : "intra-profile",
    "transport": "localhost",
    "chain"    : ["nexus", "sentinel", "carehub", "scheduler"],
    "auth"     : { "valid": true, "user": "system-user" },
    "carehub"  : { "records": [...] },
    "scheduler": { "appointments": [...] }
  },

  "reporting": {
    "profile"  : "reporting",
    "type"     : "cross-profile",
    "transport": "k8s-service-dns",
    "chain"    : ["nexus", "sentinel", "scheduler"],
    "response" : { "auth": {...}, "data": { "appointments": [...] } }
  },

  "mobile": {
    "profile"  : "mobile",
    "type"     : "cross-profile",
    "transport": "k8s-service-dns",
    "chain"    : ["nexus", "sentinel", "carehub"],
    "response" : { "auth": {...}, "data": { "records": [...] } }
  }
}
```

---

### C7. Inspect what's running inside pods

```bash
CORE_POD=$(kubectl get pod -n platform -l app.kubernetes.io/component=core -o jsonpath='{.items[0].metadata.name}')

# Check baked server.xml
kubectl exec -n platform ${CORE_POD} -- cat /opt/tomcat/conf/server.xml

# Check baked NGINX conf
kubectl exec -n platform ${CORE_POD} -- cat /etc/nginx/conf.d/platform.conf

# Check environment variables (verify service URLs are injected)
kubectl exec -n platform ${CORE_POD} -- env | grep -E 'PROFILE|SERVICE_URL|CATALINA'

# Check S6 process supervision
kubectl exec -n platform ${CORE_POD} -- s6-svstat /var/run/s6/services/nginx
kubectl exec -n platform ${CORE_POD} -- s6-svstat /var/run/s6/services/tomcat

# Check running processes (should see nginx + java)
kubectl exec -n platform ${CORE_POD} -- ps aux
```

---

### C8. Check pod logs

```bash
# Live logs from core pod
kubectl logs -f -n platform -l app.kubernetes.io/component=core

# Logs from a specific pod
kubectl logs -n platform ${CORE_POD}

# Previous pod logs (if pod restarted)
kubectl logs -n platform ${CORE_POD} --previous
```

---

## PART D — Upgrade and Rollback

```bash
# Upgrade to new image version
helm upgrade platform ./helm/multi-app-platform \
  -f ./helm/multi-app-platform/values/values-prod.yaml \
  --namespace platform

# Watch rollout
kubectl rollout status deployment/platform-multi-app-platform-core -n platform
kubectl rollout status deployment/platform-multi-app-platform-reporting -n platform
kubectl rollout status deployment/platform-multi-app-platform-mobile -n platform

# Rollback if something breaks
helm rollback platform --namespace platform

# Check Helm history
helm history platform -n platform
```

---

## PART E — Cleanup

```bash
# Uninstall Helm release
helm uninstall platform --namespace platform

# Delete namespace
kubectl delete namespace platform

# Delete kind cluster (local only)
kind delete cluster --name platform

# Remove local Docker images
docker rmi platform:core platform:reporting platform:mobile
```
