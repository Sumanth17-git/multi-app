# OpenTelemetry Integration Guide — Real Project Setup

This guide covers everything needed to integrate OpenTelemetry APM (traces, metrics, logs)
into a real Java/Kubernetes project sending data to New Relic.

---

## Architecture Overview

```
Your App Pod (any namespace)
  └── OTel Java Agent (baked into image)
        ├── Traces  ──┐
        ├── Metrics ──┤──► OTLP HTTP (port 4318) ──► OTel Collector DaemonSet ──► New Relic
        └── Logs    ──┘                                (shared cluster infra)

OTel Collector DaemonSet also collects:
  ├── kubeletstats — pod/node CPU, memory metrics
  └── hostmetrics  — disk, network, node-level metrics
```

---

## Files to Add / Modify

### 1. Dockerfile — Bake in the OTel Java Agent

```dockerfile
ARG OTEL_AGENT_VERSION=2.3.0

RUN mkdir -p /opt/otel && \
    wget -qO /opt/otel/opentelemetry-javaagent.jar \
    "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar"
```

> The agent is downloaded once at image build time. All containers from this image
> have the agent available at `/opt/otel/opentelemetry-javaagent.jar`.

---

### 2. Kubernetes Deployment — OTel Environment Variables

Add these env vars to your Deployment spec:

```yaml
env:
  - name: JAVA_TOOL_OPTIONS
    value: "-javaagent:/opt/otel/opentelemetry-javaagent.jar"

  - name: OTEL_SERVICE_NAME
    value: "your-service-name"                  # appears as APM service in New Relic

  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://otel-collector-opentelemetry-collector.<namespace>.svc.cluster.local:4318"

  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: "http/protobuf"                      # use HTTP, not gRPC — more reliable in K8s

  - name: OTEL_PROPAGATORS
    value: "tracecontext,baggage"               # W3C standard — works with all frameworks

  - name: OTEL_TRACES_SAMPLER
    value: "parentbased_traceidratio"           # respect upstream sampling decisions

  - name: OTEL_TRACES_SAMPLER_ARG
    value: "0.10"                               # 10% in prod — set 1.0 for dev/staging

  - name: OTEL_LOGS_EXPORTER
    value: "otlp"                               # agent sends logs via OTLP (auto trace correlation)

  - name: OTEL_METRICS_EXPORTER
    value: "otlp"                               # agent sends JVM + HTTP metrics

  - name: OTEL_SEMCONV_STABILITY_OPT_IN
    value: "http/dup"                           # CRITICAL: emit both old + new semconv for New Relic APM

  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "team=your-team,service.namespace=your-namespace"
```

> **Why `OTEL_SEMCONV_STABILITY_OPT_IN=http/dup`?**
> OTel Java agent v2.x emits `http.server.request.duration` (new stable semconv) by default.
> New Relic APM requires `http.server.duration` (old semconv) to populate the Summary dashboard
> (Web transactions time, Throughput, Apdex, Error rate).
> `http/dup` tells the agent to emit both — compatible with New Relic today and future-proof.

---

### 3. OTel Collector — `otel-collector-values.yaml`

Deploy once per cluster as a DaemonSet. All namespaces share this collector.

```yaml
mode: daemonset

image:
  repository: otel/opentelemetry-collector-contrib

presets:
  logsCollection:
    enabled: false          # app logs come via OTLP from Java agent (not filelog)
  kubernetesAttributes:
    enabled: true           # enriches all signals with K8s pod/node metadata
  kubeletMetrics:
    enabled: true           # collects pod/node resource metrics
  hostMetrics:
    enabled: true           # collects node-level disk, network, CPU metrics

service:
  enabled: true
  type: ClusterIP           # reachable from all namespaces via FQDN

serviceAccount:
  create: true
  name: otel-collector

clusterRole:
  create: true              # cluster-wide — reads metadata from all namespaces
  rules:
    - apiGroups: [""]
      resources: ["pods", "nodes", "nodes/stats", "nodes/proxy", "namespaces"]
      verbs: ["get", "list", "watch"]
    - apiGroups: ["apps"]
      resources: ["replicasets", "deployments", "daemonsets", "statefulsets"]
      verbs: ["get", "list", "watch"]
    - apiGroups: ["batch"]
      resources: ["jobs", "cronjobs"]
      verbs: ["get", "list", "watch"]

extraEnvs:
  - name: K8S_NODE_NAME
    valueFrom:
      fieldRef:
        fieldPath: spec.nodeName
  - name: NEW_RELIC_LICENSE_KEY
    valueFrom:
      secretKeyRef:
        name: newrelic-license       # never hardcode — use a K8s secret
        key: key
  - name: K8S_CLUSTER_NAME
    value: "your-cluster-name"

config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
    kubeletstats:
      collection_interval: 60s
      auth_type: serviceAccount
      endpoint: "https://${env:K8S_NODE_NAME}:10250"
      insecure_skip_verify: true
    hostmetrics:
      collection_interval: 60s
      scrapers:
        cpu: {}
        memory: {}
        disk: {}
        network: {}

  processors:
    batch: {}
    memory_limiter:
      check_interval: 1s
      limit_mib: 400
    k8sattributes:
      auth_type: serviceAccount
    resource:
      attributes:
        - key: k8s.cluster.name
          value: ${env:K8S_CLUSTER_NAME}
          action: upsert

  exporters:
    otlphttp/newrelic:
      endpoint: "https://otlp.eu01.nr-data.net"   # EU account
      # endpoint: "https://otlp.nr-data.net"       # US account
      headers:
        api-key: ${env:NEW_RELIC_LICENSE_KEY}

  service:
    pipelines:
      traces:
        receivers: [otlp]
        processors: [memory_limiter, k8sattributes, resource, batch]
        exporters: [otlphttp/newrelic]
      metrics:
        receivers: [kubeletstats, hostmetrics, otlp]
        processors: [memory_limiter, k8sattributes, resource, batch]
        exporters: [otlphttp/newrelic]
      logs:
        receivers: [otlp]
        processors: [memory_limiter, k8sattributes, resource, batch]
        exporters: [otlphttp/newrelic]
```

---

### 4. `pom.xml` — Structured JSON Logging Dependencies

```xml
<!-- Structured JSON logging -->
<dependency>
  <groupId>net.logstash.logback</groupId>
  <artifactId>logstash-logback-encoder</artifactId>
  <version>7.4</version>
</dependency>

<!-- Required explicitly for WAR/Tomcat classloading -->
<dependency>
  <groupId>ch.qos.logback</groupId>
  <artifactId>logback-classic</artifactId>
  <version>1.4.11</version>
</dependency>
```

---

### 5. `logback.xml` — JSON Structured Logging

Place in `src/main/resources/logback.xml` for each service:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
    <encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">
      <providers>
        <timestamp/>
        <logLevel/>
        <threadName/>
        <loggerName/>
        <message/>
        <mdc/>                    <!-- captures trace_id, span_id from OTel agent -->
        <jsonFields>
          <field name="service" value="your-service-name"/>
        </jsonFields>
      </providers>
    </encoder>
  </appender>

  <root level="INFO">
    <appender-ref ref="CONSOLE"/>
  </root>
</configuration>
```

> The `<mdc/>` provider captures `trace_id` and `span_id` automatically injected by the
> OTel Java agent. With `OTEL_LOGS_EXPORTER=otlp`, the agent sets the OTLP `TraceId` field
> natively — enabling log ↔ trace correlation in New Relic APM.

---

### 6. New Relic License Key — Kubernetes Secret

**Never hardcode the license key.** Create a secret first:

```bash
kubectl create secret generic newrelic-license \
  --from-literal=key=YOUR_LICENSE_KEY \
  --namespace your-namespace
```

Reference in `otel-collector-values.yaml`:
```yaml
extraEnvs:
  - name: NEW_RELIC_LICENSE_KEY
    valueFrom:
      secretKeyRef:
        name: newrelic-license
        key: key
```

---

## Deployment Commands

### First Time Setup

```bash
# 1. Create NR license key secret
kubectl create secret generic newrelic-license \
  --from-literal=key=YOUR_LICENSE_KEY \
  --namespace your-namespace

# 2. Install OTel Collector (shared cluster infra — run once per cluster)
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
helm install otel-collector open-telemetry/opentelemetry-collector \
  -f otel-collector-values.yaml \
  --namespace your-namespace \
  --create-namespace

# 3. Build and push your image (with agent baked in)
docker build -t your-registry/your-service:tag .
docker push your-registry/your-service:tag

# 4. Deploy your app
helm install your-app ./helm/your-chart --namespace your-namespace
```

### Verify OTel Env Vars
```bash
kubectl exec -n your-namespace deploy/your-deployment -- printenv | grep OTEL
```

Expected:
```
JAVA_TOOL_OPTIONS=-javaagent:/opt/otel/opentelemetry-javaagent.jar
OTEL_SERVICE_NAME=your-service-name
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector-...4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_LOGS_EXPORTER=otlp
OTEL_METRICS_EXPORTER=otlp
OTEL_SEMCONV_STABILITY_OPT_IN=http/dup
```

---

## Environment-Specific Settings

| Setting | Dev / Staging | Production |
|---|---|---|
| `OTEL_TRACES_SAMPLER_ARG` | `1.0` (100%) | `0.10` (10%) |
| `memory_limiter limit_mib` | `200` | `400+` |
| NR license key | Secret | Secret |
| Collector mode | Can use sidecar | DaemonSet |
| `debug` exporter | Add to pipelines | Remove |

---

## Multi-Namespace Setup

The same OTel Collector serves all namespaces. Each service in any namespace
just points `OTEL_EXPORTER_OTLP_ENDPOINT` to the collector's FQDN:

```
http://otel-collector-opentelemetry-collector.<collector-namespace>.svc.cluster.local:4318
```

Add `service.namespace` to `OTEL_RESOURCE_ATTRIBUTES` to distinguish services per namespace in New Relic:

```yaml
- name: OTEL_RESOURCE_ATTRIBUTES
  value: "team=payments,service.namespace=payments"
```

---

## What You Do NOT Need

| Item | Why Not Needed |
|---|---|
| OTel Operator | We bake agent into image directly |
| Manual RBAC yaml | Helm chart creates it via `clusterRole.create: true` |
| filelog receiver | Agent exports logs via OTLP with native trace correlation |
| transform processor | Agent sets OTLP TraceId natively — no string promotion needed |
| NR agent (APM agent) | OTel Java agent replaces it entirely |

---

## New Relic APM — Expected Services

Each unique `OTEL_SERVICE_NAME` appears as its own service under:
**APM & Services → Services - OpenTelemetry**

| APM Feature | Requires |
|---|---|
| Distributed Tracing | Traces via OTLP ✅ |
| Web Transactions / Apdex | `http.server.duration` metric (`http/dup`) ✅ |
| Logs in context | `OTEL_LOGS_EXPORTER=otlp` ✅ |
| JVM metrics | `OTEL_METRICS_EXPORTER=otlp` ✅ |
| K8s infra metrics | kubeletstats + hostmetrics in collector ✅ |
| Log ↔ Trace correlation | Agent sets OTLP TraceId natively ✅ |
