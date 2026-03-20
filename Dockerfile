# =============================================================================
# Multi-App Platform — Profile-per-Image Dockerfile
#
# Builds one image per profile. Profile is selected at BUILD time, not runtime.
#
# Build commands:
#   docker build --build-arg PROFILE=core      --target profile-core      -t platform:core .
#   docker build --build-arg PROFILE=reporting --target profile-reporting  -t platform:reporting .
#   docker build --build-arg PROFILE=mobile    --target profile-mobile     -t platform:mobile .
# =============================================================================

# =============================================================================
# Stage 1 — WAR Builder (shared across all profiles)
# =============================================================================
FROM maven:3.8.6-openjdk-11-slim AS builder

WORKDIR /build
COPY apps/ ./apps/

RUN mvn -f apps/nexus/pom.xml     clean package -q -DskipTests && \
    mvn -f apps/sentinel/pom.xml  clean package -q -DskipTests && \
    mvn -f apps/carehub/pom.xml   clean package -q -DskipTests && \
    mvn -f apps/scheduler/pom.xml clean package -q -DskipTests

# =============================================================================
# Stage 2 — Base Runtime (shared: Java 11 + NGINX 1.24 + Tomcat 9.0.69 + S6)
# =============================================================================
FROM debian:bullseye-slim AS base

ARG TOMCAT_VERSION=9.0.69
ARG S6_OVERLAY_VERSION=2.1.0.2
ARG TARGETARCH=amd64

ENV CATALINA_HOME=/opt/tomcat                                   \
    CATALINA_PID=/opt/tomcat/temp/tomcat.pid                    \
    CATALINA_OPTS="-Xms256m -Xmx1g -XX:+UseG1GC               \
                   -XX:+HeapDumpOnOutOfMemoryError              \
                   -XX:HeapDumpPath=/opt/tomcat/logs/"          \
    TZ=UTC

# Install system packages + NGINX 1.24
RUN apt-get update && apt-get install -y --no-install-recommends \
        openjdk-11-jdk-headless \
        curl                    \
        wget                    \
        gnupg2                  \
        ca-certificates         \
        tzdata                  \
    && JAVA_REAL=$(readlink -f /usr/bin/java | sed 's:/bin/java::') \
    && ln -sf "${JAVA_REAL}" /usr/local/java                        \
    && curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
        http://nginx.org/packages/debian bullseye nginx" \
        > /etc/apt/sources.list.d/nginx.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nginx=1.24.0-1~bullseye \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ENV JAVA_HOME=/usr/local/java
ENV PATH="${JAVA_HOME}/bin:${CATALINA_HOME}/bin:${PATH}"

# Install S6 Overlay v2.1.0.2
RUN case "${TARGETARCH}" in                                          \
        amd64)  S6_ARCH="amd64"   ;;                                \
        arm64)  S6_ARCH="aarch64" ;;                                \
        arm)    S6_ARCH="arm"     ;;                                 \
        *)      echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && wget -qO /tmp/s6.tar.gz \
        "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.gz" \
    && tar xzf /tmp/s6.tar.gz -C / \
    && rm /tmp/s6.tar.gz

# Install Tomcat 9.0.69
RUN wget -qO /tmp/tomcat.tar.gz \
        "https://archive.apache.org/dist/tomcat/tomcat-9/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz" \
    && mkdir -p "${CATALINA_HOME}" \
    && tar xzf /tmp/tomcat.tar.gz -C "${CATALINA_HOME}" --strip-components=1 \
    && rm /tmp/tomcat.tar.gz \
    && rm -rf \
        "${CATALINA_HOME}/webapps/ROOT"         \
        "${CATALINA_HOME}/webapps/examples"     \
        "${CATALINA_HOME}/webapps/docs"         \
        "${CATALINA_HOME}/webapps/manager"      \
        "${CATALINA_HOME}/webapps/host-manager"

# Shared appBase directories (all profiles declare all dirs — only active ones get WARs)
RUN mkdir -p \
    "${CATALINA_HOME}/webapps-nexus"     \
    "${CATALINA_HOME}/webapps-sentinel"  \
    "${CATALINA_HOME}/webapps-carehub"   \
    "${CATALINA_HOME}/webapps-scheduler"

# OpenTelemetry Java Agent — auto-instruments Tomcat, HttpClient, SLF4J MDC
ARG OTEL_AGENT_VERSION=2.3.0
RUN mkdir -p /opt/otel \
    && wget -qO /opt/otel/opentelemetry-javaagent.jar \
       "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar"

# Shared NGINX main config
COPY docker/nginx/nginx.conf /etc/nginx/nginx.conf

# S6 service definitions (nginx + tomcat — same for all profiles)
COPY docker/s6/services.d/ /etc/services.d/

RUN sed -i 's/\r//' \
        /etc/services.d/nginx/run    \
        /etc/services.d/nginx/finish \
        /etc/services.d/tomcat/run   \
        /etc/services.d/tomcat/finish \
    && chmod +x \
        /etc/services.d/nginx/run    \
        /etc/services.d/nginx/finish \
        /etc/services.d/tomcat/run   \
        /etc/services.d/tomcat/finish \
    && ln -sf /dev/stdout "${CATALINA_HOME}/logs/catalina.out" \
    && ln -sf /dev/stderr "${CATALINA_HOME}/logs/catalina.err" \
    && rm -f /etc/nginx/conf.d/default.conf \
    && mkdir -p "${CATALINA_HOME}/temp"

# =============================================================================
# Stage 3a — core profile
#   WARs: nexus + sentinel + carehub + scheduler (all 4)
#   Ports: 7500, 7507, 7522, 7530
# =============================================================================
FROM base AS profile-core

ENV PROFILE=core

COPY --from=builder /build/apps/nexus/target/nexus.war         ${CATALINA_HOME}/webapps-nexus/ROOT.war
COPY --from=builder /build/apps/sentinel/target/sentinel.war   ${CATALINA_HOME}/webapps-sentinel/ROOT.war
COPY --from=builder /build/apps/carehub/target/carehub.war     ${CATALINA_HOME}/webapps-carehub/ROOT.war
COPY --from=builder /build/apps/scheduler/target/scheduler.war ${CATALINA_HOME}/webapps-scheduler/ROOT.war

COPY docker/tomcat/server-core.xml                ${CATALINA_HOME}/conf/server.xml
COPY docker/nginx/profiles/core.conf              /etc/nginx/conf.d/platform.conf

LABEL org.opencontainers.image.title="platform-core"           \
      org.opencontainers.image.description="core: nexus + sentinel + carehub + scheduler"

EXPOSE 80
ENTRYPOINT ["/init"]

# =============================================================================
# Stage 3b — reporting profile
#   WARs: nexus + sentinel + scheduler (3)
#   Ports: 7500, 7507, 7530
# =============================================================================
FROM base AS profile-reporting

ENV PROFILE=reporting

COPY --from=builder /build/apps/nexus/target/nexus.war         ${CATALINA_HOME}/webapps-nexus/ROOT.war
COPY --from=builder /build/apps/sentinel/target/sentinel.war   ${CATALINA_HOME}/webapps-sentinel/ROOT.war
COPY --from=builder /build/apps/scheduler/target/scheduler.war ${CATALINA_HOME}/webapps-scheduler/ROOT.war

COPY docker/tomcat/server-reporting.xml           ${CATALINA_HOME}/conf/server.xml
COPY docker/nginx/profiles/reporting.conf         /etc/nginx/conf.d/platform.conf

LABEL org.opencontainers.image.title="platform-reporting"      \
      org.opencontainers.image.description="reporting: nexus + sentinel + scheduler"

EXPOSE 80
ENTRYPOINT ["/init"]

# =============================================================================
# Stage 3c — mobile profile
#   WARs: nexus + sentinel + carehub (3)
#   Ports: 7500, 7507, 7522
# =============================================================================
FROM base AS profile-mobile

ENV PROFILE=mobile

COPY --from=builder /build/apps/nexus/target/nexus.war         ${CATALINA_HOME}/webapps-nexus/ROOT.war
COPY --from=builder /build/apps/sentinel/target/sentinel.war   ${CATALINA_HOME}/webapps-sentinel/ROOT.war
COPY --from=builder /build/apps/carehub/target/carehub.war     ${CATALINA_HOME}/webapps-carehub/ROOT.war

COPY docker/tomcat/server-mobile.xml              ${CATALINA_HOME}/conf/server.xml
COPY docker/nginx/profiles/mobile.conf            /etc/nginx/conf.d/platform.conf

LABEL org.opencontainers.image.title="platform-mobile"         \
      org.opencontainers.image.description="mobile: nexus + sentinel + carehub"

EXPOSE 80
ENTRYPOINT ["/init"]
