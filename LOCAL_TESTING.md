# Local Testing Instructions

## Architecture
- 3 Docker images, one per profile
- Profile is baked at BUILD time — no runtime env switching
- Each image has its own WARs + server.xml + NGINX conf

---

## Step 1 — Build Images

```bash
cd multi-app

# Build all 3 profiles
./build/build-all.sh

# Or build individually
docker build --target profile-core      -t platform:core      .
docker build --target profile-reporting -t platform:reporting .
docker build --target profile-mobile    -t platform:mobile    .
```

---

## Step 2 — Run Each Profile Container

```bash
# core — all 4 WARs
docker run -d --name platform-core      -p 80:80   platform:core

# reporting — nexus + sentinel + scheduler
docker run -d --name platform-reporting -p 8080:80 platform:reporting

# mobile — nexus + sentinel + carehub
docker run -d --name platform-mobile    -p 8081:80 platform:mobile
```

---

## Step 3 — Test REST Endpoints

### core (port 80)
```bash
curl http://localhost/healthz
curl http://localhost/nexus/health
curl http://localhost/nexus/info
curl http://localhost/sentinel/health
curl http://localhost/sentinel/info
curl http://localhost/carehub/health
curl http://localhost/carehub/info
curl http://localhost/scheduler/health
curl http://localhost/scheduler/info
```

### reporting (port 8080) — carehub returns 404
```bash
curl http://localhost:8080/nexus/health
curl http://localhost:8080/sentinel/health
curl http://localhost:8080/scheduler/health
curl http://localhost:8080/carehub/health      # expects 404
```

### mobile (port 8081) — scheduler returns 404
```bash
curl http://localhost:8081/nexus/health
curl http://localhost:8081/sentinel/health
curl http://localhost:8081/carehub/health
curl http://localhost:8081/scheduler/health    # expects 404
```

---

## Step 4 — Inspect Baked Configs

```bash
# Verify server.xml is profile-specific (no template markers)
docker exec platform-core      cat /opt/tomcat/conf/server.xml
docker exec platform-reporting cat /opt/tomcat/conf/server.xml

# Verify NGINX conf is profile-specific
docker exec platform-core      cat /etc/nginx/conf.d/platform.conf
docker exec platform-reporting cat /etc/nginx/conf.d/platform.conf

# Verify S6 process supervision
docker exec platform-core s6-svstat /var/run/s6/services/nginx
docker exec platform-core s6-svstat /var/run/s6/services/tomcat

# Check running JVM
docker exec platform-core ps aux | grep java
```

---

## Step 5 — Cleanup

```bash
docker stop platform-core platform-reporting platform-mobile
docker rm   platform-core platform-reporting platform-mobile
docker rmi  platform:core platform:reporting platform:mobile
```
