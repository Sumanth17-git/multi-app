package com.enterprise.platform.nexus.filter;

import org.slf4j.MDC;
import javax.servlet.*;
import javax.servlet.annotation.WebFilter;
import javax.servlet.http.HttpServletRequest;
import java.io.IOException;

/**
 * MDCFilter — populates SLF4J MDC with request context for structured logging.
 *
 * Sets per-request MDC keys:
 *   profile  — Kubernetes profile (core / reporting / mobile) from env
 *   service  — WAR service name (nexus / sentinel / carehub / scheduler)
 *   method   — HTTP method (GET, POST, ...)
 *   path     — Servlet path (/route, /validate, /records, ...)
 *
 * W3C traceparent / traceId / spanId are handled automatically by the
 * OpenTelemetry Java agent (auto-attach). This filter does NOT manage
 * trace context — OTel injects those into MDC via its Logback bridge.
 *
 * Health check path (/health) is passed through silently with no MDC
 * or logging overhead.
 */
@WebFilter("/*")
public class MDCFilter implements Filter {

    private static final String SERVICE = "nexus";

    @Override
    public void init(FilterConfig cfg) {}

    @Override
    public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
            throws IOException, ServletException {

        HttpServletRequest req = (HttpServletRequest) request;
        String path = req.getServletPath();

        // Health check — pass through silently, no MDC overhead
        if ("/health".equals(path)) {
            chain.doFilter(request, response);
            return;
        }

        String profile = System.getenv("PROFILE");
        if (profile == null || profile.isEmpty()) profile = "unknown";

        MDC.put("profile", profile);
        MDC.put("service", SERVICE);
        MDC.put("method",  req.getMethod());
        MDC.put("path",    path);

        try {
            chain.doFilter(request, response);
        } finally {
            MDC.clear();
        }
    }

    @Override
    public void destroy() {}
}
