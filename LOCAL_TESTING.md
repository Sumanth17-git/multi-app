# Local Testing — Docker Only

## Step 1 — Build images

```bash
cd ~/multi-app

docker build --target profile-core      -t sumanth17121988/platform:core      .
docker build --target profile-reporting -t sumanth17121988/platform:reporting .
docker build --target profile-mobile    -t sumanth17121988/platform:mobile    .
```

## Step 2 — Run containers locally

```bash
# core
docker run -d --name platform-core      -p 8001:80 sumanth17121988/platform:core

# reporting
docker run -d --name platform-reporting -p 8002:80 sumanth17121988/platform:reporting

# mobile
docker run -d --name platform-mobile    -p 8003:80 sumanth17121988/platform:mobile
```

## Step 3 — Test endpoints

```bash
curl http://localhost:8001/healthz
curl http://localhost:8001/nexus/health
curl http://localhost:8001/nexus/route?target=carehub
curl http://localhost:8001/nexus/route?target=scheduler
curl http://localhost:8002/nexus/route?target=scheduler
curl http://localhost:8003/nexus/route?target=carehub
```

> Note: /nexus/cross-profile and /nexus/full-chain require pods to be running
> in Kubernetes so that K8s Service DNS resolves between profiles.

## Step 4 — Cleanup

```bash
docker stop platform-core platform-reporting platform-mobile
docker rm   platform-core platform-reporting platform-mobile
```
