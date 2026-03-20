package com.enterprise.platform.carehub.filter;

import org.slf4j.MDC;
import javax.servlet.*;
import javax.servlet.annotation.WebFilter;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.UUID;

@WebFilter("/*")
public class MDCFilter implements Filter {

    private static final String SERVICE = "carehub";

    @Override
    public void init(FilterConfig cfg) {}

    @Override
    public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
            throws IOException, ServletException {

        HttpServletRequest  req  = (HttpServletRequest)  request;
        HttpServletResponse resp = (HttpServletResponse) response;

        String requestId = UUID.randomUUID().toString().replace("-", "").substring(0, 12);
        String profile   = System.getenv("PROFILE");
        if (profile == null || profile.isEmpty()) profile = "unknown";

        MDC.put("requestId", requestId);
        MDC.put("profile",   profile);
        MDC.put("service",   SERVICE);
        MDC.put("method",    req.getMethod());
        MDC.put("path",      req.getServletPath());

        resp.setHeader("X-Request-Id", requestId);
        resp.setHeader("X-Profile",    profile);
        resp.setHeader("X-Service",    SERVICE);

        try {
            chain.doFilter(request, response);
        } finally {
            MDC.clear();
        }
    }

    @Override
    public void destroy() {}
}
