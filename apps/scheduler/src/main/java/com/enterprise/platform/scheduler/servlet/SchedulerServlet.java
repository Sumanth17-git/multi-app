package com.enterprise.platform.scheduler.servlet;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import io.prometheus.client.Counter;
import io.prometheus.client.Histogram;
import javax.servlet.ServletException;
import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.io.PrintWriter;
import java.time.Instant;

/**
 * SchedulerServlet — Appointment Scheduler service.
 *
 * Called by nexus after sentinel validates the request.
 * Available in: core profile, reporting profile.
 * NOT available in: mobile profile.
 *
 * Endpoints:
 *   GET /scheduler/health        → liveness probe
 *   GET /scheduler/info          → service metadata
 *   GET /scheduler/appointments  → returns appointments (called internally by nexus after sentinel auth)
 *
 * Call chain:
 *   nexus → sentinel/validate → scheduler/appointments
 */
@WebServlet(urlPatterns = { "/health", "/info", "/appointments" })
public class SchedulerServlet extends HttpServlet {

    private static final String SERVICE = "scheduler";
    private static final String VERSION = "1.0.0";

    private static final Logger log = LoggerFactory.getLogger(SchedulerServlet.class);

    private static final Counter REQUEST_COUNT = Counter.build()
        .name("http_requests_total")
        .help("Total HTTP requests handled")
        .labelNames("service", "profile", "method", "path", "status")
        .register();

    private static final Histogram REQUEST_DURATION = Histogram.build()
        .name("http_request_duration_seconds")
        .help("HTTP request duration in seconds")
        .labelNames("service", "profile", "method", "path")
        .buckets(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5)
        .register();

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp)
            throws ServletException, IOException {

        resp.setContentType("application/json;charset=UTF-8");
        resp.setHeader("X-Service", SERVICE);

        String path    = req.getServletPath();
        String profile = env("PROFILE", "unknown");

        log.info("incoming request");
        long startNs = System.nanoTime();
        try {
            switch (path) {

                // ----------------------------------------------------------------
                case "/health":
                    resp.setStatus(200);
                    write(resp, "{"
                        + "\"status\":\"UP\","
                        + "\"service\":\"" + SERVICE + "\","
                        + "\"profile\":\"" + profile + "\","
                        + "\"ts\":\"" + Instant.now() + "\""
                        + "}");
                    break;

                // ----------------------------------------------------------------
                case "/info":
                    resp.setStatus(200);
                    write(resp, "{"
                        + "\"service\":\"" + SERVICE + "\","
                        + "\"description\":\"Appointment Scheduler — booking and availability\","
                        + "\"version\":\"" + VERSION + "\","
                        + "\"profile\":\"" + profile + "\","
                        + "\"contextPath\":\"" + req.getContextPath() + "\","
                        + "\"port\":" + req.getServerPort() + ","
                        + "\"ts\":\"" + Instant.now() + "\""
                        + "}");
                    break;

                // ----------------------------------------------------------------
                // Data endpoint — called by nexus after sentinel validates auth
                // In production: query MySQL for actual appointments
                // ----------------------------------------------------------------
                case "/appointments":
                    String userId = req.getParameter("userId");
                    resp.setStatus(200);
                    write(resp, "{"
                        + "\"service\":\"" + SERVICE + "\","
                        + "\"profile\":\"" + profile + "\","
                        + "\"userId\":\"" + (userId != null ? userId : "all") + "\","
                        + "\"appointments\":["
                        +   "{\"id\":1,\"patient\":\"John Doe\","
                        +    "\"date\":\"2026-03-25\",\"type\":\"GP\",\"status\":\"confirmed\"},"
                        +   "{\"id\":2,\"patient\":\"Jane Smith\","
                        +    "\"date\":\"2026-03-26\",\"type\":\"Specialist\",\"status\":\"pending\"}"
                        + "],"
                        + "\"ts\":\"" + Instant.now() + "\""
                        + "}");
                    break;

                default:
                    resp.setStatus(404);
                    write(resp, "{\"error\":\"endpoint not found\",\"path\":\"" + path + "\"}");
            }
        } finally {
            double elapsed = (System.nanoTime() - startNs) / 1e9;
            REQUEST_COUNT.labels(SERVICE, profile, req.getMethod(), req.getServletPath(),
                String.valueOf(resp.getStatus())).inc();
            REQUEST_DURATION.labels(SERVICE, profile, req.getMethod(), req.getServletPath())
                .observe(elapsed);
            log.info("handled path={} status={} elapsed_ms={}", req.getServletPath(),
                resp.getStatus(), Math.round(elapsed * 1000));
        }
    }

    private String env(String key, String defaultVal) {
        String val = System.getenv(key);
        return (val != null && !val.isEmpty()) ? val : defaultVal;
    }

    private void write(HttpServletResponse resp, String json) throws IOException {
        PrintWriter out = resp.getWriter();
        out.print(json);
        out.flush();
    }

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp)
            throws ServletException, IOException {
        resp.setStatus(405);
        resp.setContentType("application/json;charset=UTF-8");
        resp.getWriter().print("{\"error\":\"method not allowed\"}");
    }
}
