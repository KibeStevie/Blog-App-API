package com.blog.servlets;

import java.io.IOException;

import jakarta.servlet.Filter;
import jakarta.servlet.FilterChain;
import jakarta.servlet.FilterConfig;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletRequest;
import jakarta.servlet.ServletResponse;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

public class CorsFilter implements Filter {

    // 🔧 Configure these for your environment
    private static final String ALLOWED_ORIGINS = "*";
    private static final String ALLOWED_METHODS = "GET,POST,PUT,DELETE,OPTIONS";
    private static final String ALLOWED_HEADERS = "Content-Type,Authorization,X-Session-Id,X-Requested-With,Accept,Origin";
    private static final String EXPOSED_HEADERS = "Content-Range,X-Content-Range";
    private static final boolean ALLOW_CREDENTIALS = true;
    private static final long MAX_AGE_SECONDS = 3600; // Preflight cache: 1 hour

    @Override
    public void init(FilterConfig filterConfig) {
    }

    @Override
    public void doFilter(ServletRequest req, ServletResponse res, FilterChain chain)
            throws IOException, ServletException {

        HttpServletRequest request = (HttpServletRequest) req;
        HttpServletResponse response = (HttpServletResponse) res;

        String origin = request.getHeader("Origin");

        // ✅ Validate origin against allowed list
        if (origin != null && isOriginAllowed(origin)) {
            response.setHeader("Access-Control-Allow-Origin", origin);
        }

        // ✅ Standard CORS headers
        response.setHeader("Access-Control-Allow-Methods", ALLOWED_METHODS);
        response.setHeader("Access-Control-Allow-Headers", ALLOWED_HEADERS);
        response.setHeader("Access-Control-Expose-Headers", EXPOSED_HEADERS);

        if (ALLOW_CREDENTIALS) {
            response.setHeader("Access-Control-Allow-Credentials", "true");
        }

        response.setHeader("Access-Control-Max-Age", String.valueOf(MAX_AGE_SECONDS));

        // ✅ Handle preflight OPTIONS request
        if ("OPTIONS".equalsIgnoreCase(request.getMethod())) {
            response.setStatus(HttpServletResponse.SC_OK);
            return; // Stop here - no need to call chain
        }

        // ✅ Continue to actual servlet
        chain.doFilter(req, res);
    }

    @Override
    public void destroy() {
    }

    // 🔒 Helper: Validate origin against configured list
    private boolean isOriginAllowed(String origin) {
        if (origin == null)
            return false;
        String[] allowed = ALLOWED_ORIGINS.split(",");
        for (String allowedOrigin : allowed) {
            if (origin.trim().equalsIgnoreCase(allowedOrigin.trim())) {
                return true;
            }
        }
        return false;
    }
}