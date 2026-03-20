package com.enterprise.platform.carehub.servlet;

import io.prometheus.client.CollectorRegistry;
import io.prometheus.client.exporter.common.TextFormat;
import io.prometheus.client.hotspot.DefaultExports;
import javax.servlet.ServletException;
import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.io.Writer;

@WebServlet("/metrics")
public class MetricsServlet extends HttpServlet {

    @Override
    public void init() throws ServletException {
        DefaultExports.initialize();
    }

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp)
            throws IOException {
        resp.setStatus(200);
        resp.setContentType(TextFormat.CONTENT_TYPE_004);
        try (Writer writer = resp.getWriter()) {
            TextFormat.write004(writer,
                CollectorRegistry.defaultRegistry.metricFamilySamples());
        }
    }
}
