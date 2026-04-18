package com.blog.servlets;

import java.io.IOException;
import java.io.PrintWriter;
import java.sql.CallableStatement;
import java.sql.Connection;
import java.sql.ResultSet;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.blog.db.DBConnection;
import com.google.gson.Gson;
import com.google.gson.JsonArray;
import com.google.gson.JsonObject;

import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

public class TagsServlet extends HttpServlet {
    private final Gson gson = new Gson();

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        resp.setContentType("application/json");
        PrintWriter out = resp.getWriter();
        String pathInfo = req.getPathInfo(); // e.g., null, "/", "/posts"

        try {
            // 🔹 Route based on sub-path
            if (pathInfo == null || pathInfo.equals("/") || pathInfo.isEmpty()) {
                handleGetTags(req, out);
            } else if ("/posts".equals(pathInfo)) {
                handleGetPostsByTag(req, resp, out);
            } else {
                resp.setStatus(400);
                out.print("{\"error\":\"Unknown endpoint. Use /api/tags or /api/tags/posts\"}");
            }
        } catch (Exception e) {
            resp.setStatus(500);
            out.print("{\"error\":\"" + escapeJson(e.getMessage()) + "\"}");
        }
    }

    // 🔹 GET TAGS LIST (with optional search)
    private void handleGetTags(HttpServletRequest req, PrintWriter out) throws Exception {
        String search = req.getParameter("search");
        // Convert empty string to null for DB
        if (search != null && search.trim().isEmpty()) {
            search = null;
        }

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_get_tags(?)}")) {

            cs.setString(1, search);

            try (ResultSet rs = cs.executeQuery()) {
                List<Map<String, Object>> tags = new ArrayList<>();
                while (rs.next()) {
                    Map<String, Object> tag = new LinkedHashMap<>();
                    tag.put("tag_id", rs.getInt("tag_id"));
                    tag.put("name", rs.getString("name"));
                    tag.put("post_count", rs.getLong("post_count"));
                    tags.add(tag);
                }

                JsonObject response = new JsonObject();
                response.addProperty("search", search);
                response.addProperty("count", tags.size());
                response.add("tags", gson.toJsonTree(tags));
                out.print(response.toString());
            }
        }
    }

    // 🔹 GET POSTS BY TAG NAME
    private void handleGetPostsByTag(HttpServletRequest req, HttpServletResponse resp, PrintWriter out)
            throws Exception {
        String tagName = req.getParameter("search");
        int page = parseIntParam(req, "page", 1);
        int limit = parseIntParam(req, "limit", 20);

        // Validate tag name
        if (tagName == null || tagName.trim().isEmpty()) {
            resp.setStatus(400);
            out.print("{\"error\":\"Tag name 'search' parameter is required for /api/tags/posts\"}");
            return;
        }

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_get_posts_by_tag(?, ?, ?)}")) {

            cs.setString(1, tagName.trim());
            cs.setInt(2, page);
            cs.setInt(3, limit);

            try (ResultSet rs = cs.executeQuery()) {
                List<Map<String, Object>> posts = new ArrayList<>();

                while (rs.next()) {
                    Map<String, Object> post = new LinkedHashMap<>();
                    post.put("post_id", rs.getInt("post_id"));
                    post.put("user_id", rs.getInt("user_id"));
                    post.put("author_username", rs.getString("author_username"));
                    post.put("author_avatar", rs.getString("author_avatar"));
                    post.put("title", rs.getString("title"));
                    post.put("content", rs.getString("content"));
                    post.put("cover_image", rs.getString("cover_image"));
                    post.put("created_at", rs.getTimestamp("created_at"));
                    post.put("like_count", rs.getLong("like_count"));
                    post.put("comment_count", rs.getLong("comment_count"));

                    // Parse JSON tags array from DB
                    String tagsJson = rs.getString("tags");
                    if (tagsJson != null && !tagsJson.isEmpty()) {
                        post.put("tags", gson.fromJson(tagsJson, JsonArray.class));
                    } else {
                        post.put("tags", new JsonArray());
                    }

                    posts.add(post);
                }

                JsonObject response = new JsonObject();
                response.addProperty("search", tagName);
                response.addProperty("count", posts.size());
                response.addProperty("page", page);
                response.addProperty("limit", limit);
                response.add("posts", gson.toJsonTree(posts));
                out.print(response.toString());
            }
        }
    }

    // 🔹 UTILS
    private int parseIntParam(HttpServletRequest req, String name, int defaultValue) {
        try {
            String val = req.getParameter(name);
            return val != null ? Integer.parseInt(val) : defaultValue;
        } catch (NumberFormatException e) {
            return defaultValue;
        }
    }

    private String escapeJson(String input) {
        if (input == null)
            return "";
        return input.replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\n", "\\n")
                .replace("\r", "\\r")
                .replace("\t", "\\t");
    }
}