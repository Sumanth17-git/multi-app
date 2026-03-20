package com.enterprise.platform.carehub.filter;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;

import javax.servlet.*;
import javax.servlet.annotation.WebFilter;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.security.SecureRandom;

/**
 * Enterprise MDCFilter — W3C Trace Context (traceparent) propagation.
 *
 * Implements the W3C Trace Context specification:
 *   https://www.w3.org/TR/trace-context/
 *
 * traceparent header format:
 *   00-{traceId(32 hex)}-{spanId(16 hex)}-{flags(2 hex)}
 *
 * Behaviour:
 *   - If incoming request has a valid traceparent: extract traceId, use incoming
 *     spanId as parentSpanId, generate a new spanId for this service hop.
 *   - If no traceparent: generate a new traceId and spanId (trace origin).
 *   - Propagate traceparent in the response so callers can correlate.
 *   - Health check paths (/health) are passed through without MDC/logging.
 *
 * MDC keys set per request:
 *   traceId      — W3C 32-hex trace identifier (same across all hops)
 *   spanId       — W3C 16-hex span identifier (new for each service)
 *   parentSpanId — spanId of the caller (empty if trace origin)
 *   profile      — Kubernetes profile (core / reporting / mobile)
 *   service      — Service name (nexus / sentinel / carehub / scheduler)
 *   method       — HTTP method
 *   path         — Servlet path
 */
@WebFilter("/*")
public class MDCFilter implements Filter {

    private static final Logger log = LoggerFactory.getLogger(MDCFilter.class);

    private static final String SERVICE           = "carehub";
    private static final String TRACEPARENT       = "traceparent";
    private static final String TRACESTATE        = "tracestate";
    private static final String TRACE_FLAGS       = "01";   // sampled

    private static final SecureRandom RNG = new SecureRandom();

    @Override
    public void init(FilterConfig cfg) {}

    @Override
    public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
            throws IOException, ServletException {

        HttpServletRequest  req  = (HttpServletRequest)  request;
        HttpServletResponse resp = (HttpServletResponse) response;

        String path = req.getServletPath();

        // Health check — pass through silently, no MDC, no logging
        if ("/health".equals(path)) {
            chain.doFilter(request, response);
            return;
        }

        String profile = System.getenv("PROFILE");
        if (profile == null || profile.isEmpty()) profile = "unknown";

        // ── Parse or generate W3C traceparent ────────────────────────────────
        String traceId      = null;
        String parentSpanId = null;
        String spanId       = generateHex(8);   // 16 hex chars (8 bytes)

        String incomingTraceparent = req.getHeader(TRACEPARENT);
        if (incomingTraceparent != null && incomingTraceparent.startsWith("00-")) {
            String[] parts = incomingTraceparent.split("-");
            if (parts.length == 4 && parts[1].length() == 32 && parts[2].length() == 16) {
                traceId      = parts[1];
                parentSpanId = parts[2];
            }
        }
        if (traceId == null) {
            traceId = generateHex(16);  // 32 hex chars (16 bytes) — new trace origin
        }

        String outgoingTraceparent = "00-" + traceId + "-" + spanId + "-" + TRACE_FLAGS;

        // ── Populate MDC ──────────────────────────────────────────────────────
        MDC.put("traceId",      traceId);
        MDC.put("spanId",       spanId);
        MDC.put("parentSpanId", parentSpanId != null ? parentSpanId : "");
        MDC.put("profile",      profile);
        MDC.put("service",      SERVICE);
        MDC.put("method",       req.getMethod());
        MDC.put("path",         path);

        // ── Propagate trace context in response ───────────────────────────────
        resp.setHeader(TRACEPARENT, outgoingTraceparent);
        resp.setHeader("X-Profile",  profile);
        resp.setHeader("X-Service",  SERVICE);

        // Store outgoing traceparent in request attribute so servlets can use it
        req.setAttribute("traceparent", outgoingTraceparent);
        req.setAttribute("traceId",     traceId);
        req.setAttribute("spanId",      spanId);

        log.debug("trace-context: traceId={} spanId={} parentSpanId={} path={}",
                traceId, spanId, parentSpanId, path);

        try {
            chain.doFilter(request, response);
        } finally {
            MDC.clear();
        }
    }

    @Override
    public void destroy() {}

    // ── Helpers ───────────────────────────────────────────────────────────────

    /** Generate n random bytes as lowercase hex string (length = n*2) */
    private static String generateHex(int bytes) {
        byte[] buf = new byte[bytes];
        RNG.nextBytes(buf);
        StringBuilder sb = new StringBuilder(bytes * 2);
        for (byte b : buf) {
            sb.append(String.format("%02x", b));
        }
        return sb.toString();
    }
}
