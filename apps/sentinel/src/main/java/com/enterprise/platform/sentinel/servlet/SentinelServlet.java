package com.enterprise.platform.sentinel.servlet;

import javax.servlet.ServletException;
import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.io.PrintWriter;
import java.time.Instant;

/**
 * SentinelServlet — Identity and Auth service.
 *
 * Called by nexus during the intra-profile chain before accessing any data WAR.
 *
 * Endpoints:
 *   GET /sentinel/health    → liveness probe
 *   GET /sentinel/info      → service metadata
 *   GET /sentinel/validate  → token validation (called internally by nexus)
 *
 * In a real implementation, /validate would:
 *   - Parse the Authorization header
 *   - Verify JWT signature
 *   - Check token expiry + revocation
 *   - Return claims (userId, roles, etc.)
 *
 * Here it returns a simulated valid auth response so the WAR chain can be tested.
 */
@WebServlet(urlPatterns = { "/health", "/info", "/validate" })
public class SentinelServlet extends HttpServlet {

    private static final String SERVICE = "sentinel";
    private static final String VERSION = "1.0.0";

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp)
            throws ServletException, IOException {

        resp.setContentType("application/json;charset=UTF-8");
        resp.setHeader("X-Service", SERVICE);

        String path    = req.getServletPath();
        String profile = env("PROFILE", "unknown");

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
                    + "\"description\":\"Identity and Auth — token validation gateway\","
                    + "\"version\":\"" + VERSION + "\","
                    + "\"profile\":\"" + profile + "\","
                    + "\"contextPath\":\"" + req.getContextPath() + "\","
                    + "\"port\":" + req.getServerPort() + ","
                    + "\"ts\":\"" + Instant.now() + "\""
                    + "}");
                break;

            // ----------------------------------------------------------------
            // Called by nexus before every downstream WAR call
            // In production: validate JWT from Authorization header
            // ----------------------------------------------------------------
            case "/validate":
                String authHeader = req.getHeader("Authorization");
                resp.setStatus(200);
                write(resp, "{"
                    + "\"valid\":true,"
                    + "\"service\":\"" + SERVICE + "\","
                    + "\"profile\":\"" + profile + "\","
                    + "\"user\":\"system-user\","
                    + "\"roles\":[\"READ\",\"WRITE\"],"
                    + "\"tokenReceived\":" + (authHeader != null) + ","
                    + "\"ts\":\"" + Instant.now() + "\""
                    + "}");
                break;

            default:
                resp.setStatus(404);
                write(resp, "{\"error\":\"endpoint not found\",\"path\":\"" + path + "\"}");
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
