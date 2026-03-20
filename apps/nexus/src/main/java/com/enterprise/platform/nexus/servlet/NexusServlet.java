package com.enterprise.platform.nexus.servlet;

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
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.time.Instant;
import java.util.concurrent.CompletableFuture;

/**
 * NexusServlet — API Gateway. Orchestrates intra-profile and inter-profile chains.
 *
 * Endpoints:
 *
 *   GET /nexus/health
 *       → liveness probe
 *
 *   GET /nexus/info
 *       → service metadata
 *
 *   GET /nexus/route?target=carehub|scheduler
 *       → intra-profile chain: nexus → sentinel → carehub OR scheduler
 *       → called directly by clients AND by /full-chain on remote profiles
 *
 *   GET /nexus/cross-profile?to=reporting|mobile
 *       → inter-profile: calls another profile's /nexus/route via K8s Service DNS
 *
 *   GET /nexus/full-chain                           ← THE NEW ENDPOINT
 *       → end-to-end across ALL profiles in one call:
 *
 *         [Auth]   nexus → sentinel/validate          (intra, sync first)
 *                  ┌──────────────────────────────────────────────────┐
 *         [Parallel, all fired at the same time]                      │
 *                  │ intra: carehub/records           (localhost:7522) │
 *                  │ intra: scheduler/appointments    (localhost:7530) │
 *                  │ cross: reporting → nexus/route?target=scheduler  │
 *                  │ cross: mobile    → nexus/route?target=carehub    │
 *                  └──────────────────────────────────────────────────┘
 *         [Aggregate] waits for all, builds one JSON response
 */
@WebServlet(urlPatterns = { "/health", "/info", "/route", "/cross-profile", "/full-chain" })
public class NexusServlet extends HttpServlet {

    // Intra-profile base URLs (same container, localhost)
    private static final String SENTINEL_BASE  = "http://localhost:7507/sentinel";
    private static final String CAREHUB_BASE   = "http://localhost:7522/carehub";
    private static final String SCHEDULER_BASE = "http://localhost:7530/scheduler";

    private static final String SERVICE = "nexus";
    private static final String VERSION = "1.0.0";

    private static final Logger log = LoggerFactory.getLogger(NexusServlet.class);

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

    // Shared client — thread-safe, reuse across all requests
    private HttpClient httpClient;

    @Override
    public void init() throws ServletException {
        httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(5))
                .build();
    }

    // =========================================================================
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
                case "/health":       handleHealth(resp, profile);              break;
                case "/info":         handleInfo(req, resp, profile);           break;
                case "/route":        handleRoute(req, resp, profile);          break;
                case "/cross-profile":handleCrossProfile(req, resp, profile);   break;
                case "/full-chain":   handleFullChain(resp, profile);           break;
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

    // =========================================================================
    // /health
    // =========================================================================
    private void handleHealth(HttpServletResponse resp, String profile) throws IOException {
        resp.setStatus(200);
        write(resp, "{"
            + "\"status\":\"UP\","
            + "\"service\":\"" + SERVICE + "\","
            + "\"profile\":\"" + profile + "\","
            + "\"ts\":\"" + Instant.now() + "\""
            + "}");
    }

    // =========================================================================
    // /info
    // =========================================================================
    private void handleInfo(HttpServletRequest req, HttpServletResponse resp, String profile)
            throws IOException {
        resp.setStatus(200);
        write(resp, "{"
            + "\"service\":\"" + SERVICE + "\","
            + "\"description\":\"API Gateway — intra and inter profile orchestration\","
            + "\"version\":\"" + VERSION + "\","
            + "\"profile\":\"" + profile + "\","
            + "\"contextPath\":\"" + req.getContextPath() + "\","
            + "\"port\":" + req.getServerPort() + ","
            + "\"endpoints\":[\"/health\",\"/info\",\"/route\",\"/cross-profile\",\"/full-chain\"],"
            + "\"ts\":\"" + Instant.now() + "\""
            + "}");
    }

    // =========================================================================
    // /route?target=carehub|scheduler
    // Intra-profile chain: nexus → sentinel → target WAR
    // =========================================================================
    private void handleRoute(HttpServletRequest req, HttpServletResponse resp, String profile)
            throws IOException {

        String target = req.getParameter("target");
        if (target == null || target.isEmpty()) {
            resp.setStatus(400);
            write(resp, "{\"error\":\"missing param: target (carehub|scheduler)\"}");
            return;
        }

        long start = System.currentTimeMillis();

        // Step 1 — auth
        String authResult = callSync(SENTINEL_BASE + "/validate");

        // Step 2 — data
        String dataResult;
        switch (target) {
            case "carehub":
                dataResult = callSync(CAREHUB_BASE + "/records");
                break;
            case "scheduler":
                dataResult = callSync(SCHEDULER_BASE + "/appointments");
                break;
            default:
                resp.setStatus(400);
                write(resp, "{\"error\":\"unknown target: " + target + "\"}");
                return;
        }

        resp.setStatus(200);
        write(resp, "{"
            + "\"gateway\":\"nexus\","
            + "\"profile\":\"" + profile + "\","
            + "\"chain\":[\"nexus\",\"sentinel\",\"" + target + "\"],"
            + "\"elapsedMs\":" + (System.currentTimeMillis() - start) + ","
            + "\"auth\":" + authResult + ","
            + "\"data\":" + dataResult
            + "}");
    }

    // =========================================================================
    // /cross-profile?to=reporting|mobile
    // Inter-profile: calls another profile's pod via K8s Service DNS
    // =========================================================================
    private void handleCrossProfile(HttpServletRequest req, HttpServletResponse resp, String profile)
            throws IOException {

        String to = req.getParameter("to");
        if (to == null || to.isEmpty()) {
            resp.setStatus(400);
            write(resp, "{\"error\":\"missing param: to (reporting|mobile)\"}");
            return;
        }

        String serviceUrl = env(to.toUpperCase() + "_SERVICE_URL", null);
        if (serviceUrl == null) {
            resp.setStatus(503);
            write(resp, "{\"error\":\"" + to.toUpperCase() + "_SERVICE_URL not configured\"}");
            return;
        }

        String remoteTarget = "reporting".equals(to) ? "scheduler" : "carehub";
        String remoteUrl    = serviceUrl + "/nexus/route?target=" + remoteTarget;

        long start  = System.currentTimeMillis();
        String body = callSync(remoteUrl);

        resp.setStatus(200);
        write(resp, "{"
            + "\"from\":\"" + profile + "\","
            + "\"to\":\"" + to + "\","
            + "\"remoteUrl\":\"" + remoteUrl + "\","
            + "\"elapsedMs\":" + (System.currentTimeMillis() - start) + ","
            + "\"response\":" + body
            + "}");
    }

    // =========================================================================
    // /full-chain  — ONE endpoint, end-to-end across ALL three profiles
    //
    // Execution plan:
    //   1. Sync:     sentinel/validate          (auth must come first)
    //   2. Async x4 (all fired simultaneously):
    //        A. localhost:7522/carehub/records       (intra — core/mobile)
    //        B. localhost:7530/scheduler/appointments (intra — core/reporting)
    //        C. REPORTING_SERVICE_URL/nexus/route?target=scheduler  (cross-profile)
    //        D. MOBILE_SERVICE_URL/nexus/route?target=carehub       (cross-profile)
    //   3. allOf.join() — wait for all 4 to finish (or timeout individually)
    //   4. Aggregate into one JSON response
    // =========================================================================
    private void handleFullChain(HttpServletResponse resp, String profile) throws IOException {

        long start = System.currentTimeMillis();

        // ── Step 1: Auth (sync — everything else depends on this) ────────────
        String authResult = callSync(SENTINEL_BASE + "/validate");

        // ── Step 2: Fire all data calls in parallel ──────────────────────────
        // Intra-profile (localhost — fast)
        CompletableFuture<String> carehubFuture   = callAsync(CAREHUB_BASE   + "/records");
        CompletableFuture<String> schedulerFuture = callAsync(SCHEDULER_BASE + "/appointments");

        // Cross-profile (K8s Service DNS — network hop)
        String reportingServiceUrl = env("REPORTING_SERVICE_URL", null);
        String mobileServiceUrl    = env("MOBILE_SERVICE_URL",    null);

        CompletableFuture<String> reportingFuture = (reportingServiceUrl != null)
            ? callAsync(reportingServiceUrl + "/nexus/route?target=scheduler")
            : done("{\"skipped\":true,\"reason\":\"REPORTING_SERVICE_URL not set\"}");

        CompletableFuture<String> mobileFuture = (mobileServiceUrl != null)
            ? callAsync(mobileServiceUrl + "/nexus/route?target=carehub")
            : done("{\"skipped\":true,\"reason\":\"MOBILE_SERVICE_URL not set\"}");

        // ── Step 3: Wait for all parallel calls to complete ──────────────────
        CompletableFuture.allOf(carehubFuture, schedulerFuture, reportingFuture, mobileFuture)
                         .join();

        String carehubResult   = carehubFuture.join();
        String schedulerResult = schedulerFuture.join();
        String reportingResult = reportingFuture.join();
        String mobileResult    = mobileFuture.join();

        long elapsed = System.currentTimeMillis() - start;

        // ── Step 4: Aggregate ─────────────────────────────────────────────────
        resp.setStatus(200);
        write(resp, "{"
            + "\"endpoint\":\"/nexus/full-chain\","
            + "\"calledFrom\":\"" + profile + "\","
            + "\"elapsedMs\":" + elapsed + ","
            + "\"ts\":\"" + Instant.now() + "\","

            // ── core profile section (intra-profile data) ──
            + "\"core\":{"
            +   "\"profile\":\"core\","
            +   "\"type\":\"intra-profile\","
            +   "\"transport\":\"localhost\","
            +   "\"chain\":[\"nexus\",\"sentinel\",\"carehub\",\"scheduler\"],"
            +   "\"auth\":"      + authResult      + ","
            +   "\"carehub\":"   + carehubResult   + ","
            +   "\"scheduler\":" + schedulerResult
            + "},"

            // ── reporting profile section (cross-profile) ──
            + "\"reporting\":{"
            +   "\"profile\":\"reporting\","
            +   "\"type\":\"cross-profile\","
            +   "\"transport\":\"k8s-service-dns\","
            +   "\"chain\":[\"nexus\",\"sentinel\",\"scheduler\"],"
            +   "\"response\":" + reportingResult
            + "},"

            // ── mobile profile section (cross-profile) ──
            + "\"mobile\":{"
            +   "\"profile\":\"mobile\","
            +   "\"type\":\"cross-profile\","
            +   "\"transport\":\"k8s-service-dns\","
            +   "\"chain\":[\"nexus\",\"sentinel\",\"carehub\"],"
            +   "\"response\":" + mobileResult
            + "}"
            + "}");
    }

    // =========================================================================
    // HTTP helpers
    // =========================================================================

    /** Synchronous HTTP GET — blocks until response or error */
    private String callSync(String url) {
        try {
            HttpRequest req = HttpRequest.newBuilder()
                    .uri(URI.create(url))
                    .timeout(Duration.ofSeconds(10))
                    .header("Accept", "application/json")
                    .GET()
                    .build();
            HttpResponse<String> res =
                    httpClient.send(req, HttpResponse.BodyHandlers.ofString());
            return (res.statusCode() < 300) ? res.body()
                : "{\"error\":\"upstream " + res.statusCode() + "\",\"url\":\"" + url + "\"}";
        } catch (Exception e) {
            return "{\"error\":\"" + e.getClass().getSimpleName()
                    + ": " + e.getMessage() + "\",\"url\":\"" + url + "\"}";
        }
    }

    /**
     * Asynchronous HTTP GET — returns a CompletableFuture immediately.
     * Used for parallel calls in /full-chain.
     */
    private CompletableFuture<String> callAsync(String url) {
        HttpRequest req = HttpRequest.newBuilder()
                .uri(URI.create(url))
                .timeout(Duration.ofSeconds(10))
                .header("Accept", "application/json")
                .GET()
                .build();
        return httpClient
                .sendAsync(req, HttpResponse.BodyHandlers.ofString())
                .thenApply(res -> (res.statusCode() < 300) ? res.body()
                        : "{\"error\":\"upstream " + res.statusCode()
                          + "\",\"url\":\"" + url + "\"}")
                .exceptionally(e ->
                        "{\"error\":\"" + e.getClass().getSimpleName()
                        + ": " + e.getMessage() + "\",\"url\":\"" + url + "\"}");
    }

    /** Already-completed future — used when a URL env var is not set */
    private CompletableFuture<String> done(String json) {
        return CompletableFuture.completedFuture(json);
    }

    private String env(String key, String def) {
        String v = System.getenv(key);
        return (v != null && !v.isEmpty()) ? v : def;
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
