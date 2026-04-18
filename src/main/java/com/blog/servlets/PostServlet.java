package com.blog.servlets;

import java.io.IOException;
import java.io.PrintWriter;
import java.sql.CallableStatement;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Types;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import com.blog.db.DBConnection;
import com.google.gson.Gson;
import com.google.gson.JsonArray;
import com.google.gson.JsonObject;

import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

public class PostServlet extends HttpServlet {
    private final Gson gson = new Gson();

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        resp.setContentType("application/json");
        PrintWriter out = resp.getWriter();
        String path = req.getPathInfo();

        try {
            if (path == null || path.equals("/")) {
                handleCreatePost(req, resp, out);
            } else if (path.matches("/\\d+/like")) {
                handleToggleLike(req, resp, out, path);
            } else if (path.matches("/\\d+/bookmark")) {
                handleToggleBookmark(req, resp, out, path);
            } else if (path.matches("/\\d+/comments")) {
                handleCreateComment(req, resp, out, path);
            } else {
                resp.setStatus(400);
                out.print("{\"error\":\"Unknown endpoint\"}");
            }
        } catch (Exception e) {
            resp.setStatus(500);
            out.print("{\"error\":\"" + escapeJson(e.getMessage()) + "\"}");
        }
    }

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        resp.setContentType("application/json");
        PrintWriter out = resp.getWriter();
        String path = req.getPathInfo();

        try {
            if (path == null || path.equals("/")) {
                handleGetPublicFeed(req, out);
            } else if (path.matches("/\\d+")) {
                handleGetPost(req, resp, out, path);
            } else if (path.matches("/\\d+/comments")) {
                handleGetComments(req, out, path);
            } else if (path.matches("/users/\\d+")) {
                handleGetUserPosts(req, out, path);
            } else if (path.matches("/users/\\d+/bookmarks")) {
                handleGetBookmarks(req, resp, out);
            } else {
                resp.setStatus(400);
                out.print("{\"error\":\"Unknown endpoint\"}");
            }
        } catch (Exception e) {
            resp.setStatus(500);
            out.print("{\"error\":\"" + escapeJson(e.getMessage()) + "\"}");
        }
    }

    @Override
    protected void doPut(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        resp.setContentType("application/json");
        PrintWriter out = resp.getWriter();
        String path = req.getPathInfo();

        try {
            if (path != null && path.matches("/\\d+")) {
                handleUpdatePost(req, resp, out, path);
            } else {
                resp.setStatus(400);
                out.print("{\"error\":\"Unknown endpoint\"}");
            }
        } catch (Exception e) {
            resp.setStatus(500);
            out.print("{\"error\":\"" + escapeJson(e.getMessage()) + "\"}");
        }
    }

    @Override
    protected void doDelete(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        resp.setContentType("application/json");
        PrintWriter out = resp.getWriter();
        String path = req.getPathInfo();

        try {
            if (path != null && path.matches("/\\d+")) {
                handleDeletePost(req, resp, out, path);
            } else if (path != null && path.matches("/comments/\\d+")) {
                handleDeleteComment(req, resp, out, path);
            } else {
                resp.setStatus(400);
                out.print("{\"error\":\"Unknown endpoint\"}");
            }
        } catch (Exception e) {
            resp.setStatus(500);
            out.print("{\"error\":\"" + escapeJson(e.getMessage()) + "\"}");
        }
    }

    // 🔹 CREATE POST
    private void handleCreatePost(HttpServletRequest req, HttpServletResponse resp, PrintWriter out) throws Exception {
        String sessionIdStr = req.getHeader("X-Session-Id");
        if (sessionIdStr == null) {
            resp.setStatus(401);
            out.print("{\"error\":\"Unauthorized\"}");
            return;
        }

        UUID sessionId = UUID.fromString(sessionIdStr);
        JsonObject json = gson.fromJson(req.getReader(), JsonObject.class);

        // Extract optional arrays
        JsonArray tagNames = json.has("tags") ? json.getAsJsonArray("tags") : null;
        JsonArray imageUrls = json.has("images") ? json.getAsJsonArray("images") : null;

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_create_post(?, ?, ?, ?, ?, ?, ?)}")) {

            // Get user_id from session
            int userId;
            try (CallableStatement csSession = conn.prepareCall("{call fn_validate_session(?)}")) {
                csSession.setObject(1, sessionId, Types.OTHER);
                try (ResultSet rs = csSession.executeQuery()) {
                    if (!rs.next() || !rs.getBoolean("success")) {
                        resp.setStatus(401);
                        out.print("{\"error\":\"Invalid session\"}");
                        return;
                    }
                    userId = rs.getInt("user_id");
                }
            }

            cs.setInt(1, userId);
            cs.setString(2, json.get("title").getAsString());
            cs.setString(3, json.get("content").getAsString());
            cs.setString(4, json.has("cover_image") ? json.get("cover_image").getAsString() : null);
            cs.setBoolean(5, json.has("is_published") ? json.get("is_published").getAsBoolean() : true);

            // Convert JsonArray to String[] for PostgreSQL
            cs.setArray(6, conn.createArrayOf("text", jsonArrayToStringArray(tagNames)));
            cs.setArray(7, conn.createArrayOf("text", jsonArrayToStringArray(imageUrls)));

            try (ResultSet rs = cs.executeQuery()) {
                if (rs.next() && rs.getBoolean("success")) {
                    resp.setStatus(201);
                    out.print("{\"post_id\":" + rs.getInt("created_post_id") + ", \"message\":\"" +
                            escapeJson(rs.getString("message")) + "\"}");
                } else {
                    resp.setStatus(400);
                    out.print("{\"error\":\"" + escapeJson(rs.getString("error")) + "\"}");
                }
            }
        }
    }

    // 🔹 GET PUBLIC FEED
    private void handleGetPublicFeed(HttpServletRequest req, PrintWriter out)
            throws Exception {
        int page = parseIntParam(req, "page", 1);
        int limit = parseIntParam(req, "limit", 20);
        String tag = req.getParameter("tag");

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_get_public_feed(?, ?, ?)}")) {

            cs.setInt(1, page);
            cs.setInt(2, limit);
            cs.setString(3, tag);

            try (ResultSet rs = cs.executeQuery()) {
                List<Map<String, Object>> posts = new ArrayList<>();
                while (rs.next()) {
                    Map<String, Object> post = resultSetToMap(rs);
                    // Parse JSON fields
                    if (rs.getString("tags") != null) {
                        post.put("tags", gson.fromJson(rs.getString("tags"), JsonArray.class));
                    }
                    posts.add(post);
                }
                JsonObject res = new JsonObject();
                res.add("posts", gson.toJsonTree(posts));
                res.addProperty("page", page);
                res.addProperty("limit", limit);
                out.print(res);
            }
        }
    }

    // 🔹 GET POST BY ID
    private void handleGetPost(HttpServletRequest req, HttpServletResponse resp, PrintWriter out, String path)
            throws Exception {
        int postId = extractIdFromPath(path);
        String sessionIdStr = req.getHeader("X-Session-Id");
        Integer requesterId = null;

        // Try to get requester user_id from session (for is_liked/is_bookmarked flags)
        if (sessionIdStr != null) {
            try {
                UUID sessionId = UUID.fromString(sessionIdStr);
                try (Connection conn = DBConnection.getConnection();
                        CallableStatement cs = conn.prepareCall("{call fn_validate_session(?)}")) {
                    cs.setObject(1, sessionId, Types.OTHER);
                    try (ResultSet rs = cs.executeQuery()) {
                        if (rs.next() && rs.getBoolean("success")) {
                            requesterId = rs.getInt("user_id");
                        }
                    }
                }
            } catch (IllegalArgumentException e) {
                // Invalid session format, ignore and proceed as anonymous
            }
        }

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_get_post(?, ?)}")) {

            cs.setInt(1, postId);
            cs.setObject(2, requesterId, requesterId != null ? Types.INTEGER : Types.NULL);

            try (ResultSet rs = cs.executeQuery()) {
                if (rs.next() && rs.getBoolean("success")) {
                    Map<String, Object> post = new LinkedHashMap<>();
                    post.put("post_id", rs.getInt("post_id"));
                    post.put("user_id", rs.getInt("user_id"));
                    post.put("author_username", rs.getString("author_username"));
                    post.put("author_avatar", rs.getString("author_avatar"));
                    post.put("title", rs.getString("title"));
                    post.put("content", rs.getString("content"));
                    post.put("cover_image", rs.getString("cover_image"));
                    post.put("is_published", rs.getBoolean("is_published"));
                    post.put("created_at", rs.getTimestamp("created_at"));
                    post.put("updated_at", rs.getTimestamp("updated_at"));
                    post.put("like_count", rs.getLong("like_count"));
                    post.put("comment_count", rs.getLong("comment_count"));
                    post.put("bookmark_count", rs.getLong("bookmark_count"));

                    // Parse JSON arrays
                    if (rs.getString("images") != null) {
                        post.put("images", gson.fromJson(rs.getString("images"), JsonArray.class));
                    }
                    if (rs.getString("tags") != null) {
                        post.put("tags", gson.fromJson(rs.getString("tags"), JsonArray.class));
                    }

                    post.put("is_liked", rs.getBoolean("is_liked"));
                    post.put("is_bookmarked", rs.getBoolean("is_bookmarked"));

                    out.print(gson.toJson(post));
                } else {
                    resp.setStatus(404);
                    out.print("{\"error\":\"" + escapeJson(rs.getString("error")) + "\"}");
                }
            }
        }
    }

    // 🔹 UPDATE POST
    private void handleUpdatePost(HttpServletRequest req, HttpServletResponse resp, PrintWriter out, String path)
            throws Exception {
        String sessionIdStr = req.getHeader("X-Session-Id");
        if (sessionIdStr == null) {
            resp.setStatus(401);
            out.print("{\"error\":\"Unauthorized\"}");
            return;
        }

        UUID sessionId = UUID.fromString(sessionIdStr);
        int postId = extractIdFromPath(path);
        JsonObject json = gson.fromJson(req.getReader(), JsonObject.class);

        JsonArray tagNames = json.has("tags") ? json.getAsJsonArray("tags") : null;
        JsonArray imageUrls = json.has("images") ? json.getAsJsonArray("images") : null;

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_update_post(?, ?, ?, ?, ?, ?, ?, ?)}")) {

            cs.setObject(1, sessionId, Types.OTHER);
            cs.setInt(2, postId);
            cs.setString(3, json.has("title") ? json.get("title").getAsString() : null);
            cs.setString(4, json.has("content") ? json.get("content").getAsString() : null);
            cs.setString(5, json.has("cover_image") ? json.get("cover_image").getAsString() : null);
            cs.setObject(6, json.has("is_published") ? json.get("is_published").getAsBoolean() : null, Types.BOOLEAN);
            cs.setArray(7, conn.createArrayOf("text", jsonArrayToStringArray(tagNames)));
            cs.setArray(8, conn.createArrayOf("text", jsonArrayToStringArray(imageUrls)));

            try (ResultSet rs = cs.executeQuery()) {
                if (rs.next() && rs.getBoolean("success")) {
                    out.print("{\"message\":\"" + escapeJson(rs.getString("message")) + "\"}");
                } else {
                    resp.setStatus(400);
                    out.print("{\"error\":\"" + escapeJson(rs.getString("error")) + "\"}");
                }
            }
        }
    }

    // 🔹 DELETE POST
    private void handleDeletePost(HttpServletRequest req, HttpServletResponse resp, PrintWriter out, String path)
            throws Exception {
        String sessionIdStr = req.getHeader("X-Session-Id");
        if (sessionIdStr == null) {
            resp.setStatus(401);
            out.print("{\"error\":\"Unauthorized\"}");
            return;
        }

        UUID sessionId = UUID.fromString(sessionIdStr);
        int postId = extractIdFromPath(path);

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_delete_post(?, ?)}")) {

            cs.setObject(1, sessionId, Types.OTHER);
            cs.setInt(2, postId);

            try (ResultSet rs = cs.executeQuery()) {
                if (rs.next() && rs.getBoolean("success")) {
                    out.print("{\"message\":\"" + escapeJson(rs.getString("message")) + "\"}");
                } else {
                    resp.setStatus(400);
                    out.print("{\"error\":\"" + escapeJson(rs.getString("error")) + "\"}");
                }
            }
        }
    }

    // 🔹 TOGGLE LIKE
    private void handleToggleLike(HttpServletRequest req, HttpServletResponse resp, PrintWriter out, String path)
            throws Exception {
        String sessionIdStr = req.getHeader("X-Session-Id");
        if (sessionIdStr == null) {
            resp.setStatus(401);
            out.print("{\"error\":\"Unauthorized\"}");
            return;
        }

        UUID sessionId = UUID.fromString(sessionIdStr);
        int postId = extractIdFromPath(path);

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_toggle_like(?, ?)}")) {

            cs.setObject(1, sessionId, Types.OTHER);
            cs.setInt(2, postId);

            try (ResultSet rs = cs.executeQuery()) {
                if (rs.next() && rs.getBoolean("success")) {
                    JsonObject res = new JsonObject();
                    res.addProperty("action", rs.getString("action"));
                    res.addProperty("message", rs.getString("message"));
                    out.print(res);
                } else {
                    resp.setStatus(400);
                    out.print("{\"error\":\"" + escapeJson(rs.getString("error")) + "\"}");
                }
            }
        }
    }

    // 🔹 TOGGLE BOOKMARK
    private void handleToggleBookmark(HttpServletRequest req, HttpServletResponse resp, PrintWriter out, String path)
            throws Exception {
        String sessionIdStr = req.getHeader("X-Session-Id");
        if (sessionIdStr == null) {
            resp.setStatus(401);
            out.print("{\"error\":\"Unauthorized\"}");
            return;
        }

        UUID sessionId = UUID.fromString(sessionIdStr);
        int postId = extractIdFromPath(path);

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_toggle_bookmark(?, ?)}")) {

            cs.setObject(1, sessionId, Types.OTHER);
            cs.setInt(2, postId);

            try (ResultSet rs = cs.executeQuery()) {
                if (rs.next() && rs.getBoolean("success")) {
                    JsonObject res = new JsonObject();
                    res.addProperty("action", rs.getString("action"));
                    res.addProperty("message", rs.getString("message"));
                    out.print(res);
                } else {
                    resp.setStatus(400);
                    out.print("{\"error\":\"" + escapeJson(rs.getString("error")) + "\"}");
                }
            }
        }
    }

    // 🔹 CREATE COMMENT
    private void handleCreateComment(HttpServletRequest req, HttpServletResponse resp, PrintWriter out, String path)
            throws Exception {
        String sessionIdStr = req.getHeader("X-Session-Id");
        if (sessionIdStr == null) {
            resp.setStatus(401);
            out.print("{\"error\":\"Unauthorized\"}");
            return;
        }

        UUID sessionId = UUID.fromString(sessionIdStr);
        int postId = extractIdFromPath(path);
        JsonObject json = gson.fromJson(req.getReader(), JsonObject.class);
        String content = json.get("content").getAsString();

        // ✅ Extract optional parent_comment_id
        Integer parentCommentId = json.has("parent_comment_id") ? json.get("parent_comment_id").getAsInt() : null;

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_create_comment(?, ?, ?, ?)}")) {

            cs.setObject(1, sessionId, Types.OTHER);
            cs.setInt(2, postId);
            cs.setString(3, content);
            if (parentCommentId != null) {
                cs.setInt(4, parentCommentId);
            } else {
                cs.setNull(4, Types.INTEGER);
            }

            try (ResultSet rs = cs.executeQuery()) {
                if (rs.next() && rs.getBoolean("success")) {
                    resp.setStatus(201);
                    out.print("{\"comment_id\":" + rs.getInt("comment_id") + ", \"message\":\"" +
                            escapeJson(rs.getString("message")) + "\"}");
                } else {
                    resp.setStatus(400);
                    out.print("{\"error\":\"" + escapeJson(rs.getString("error")) + "\"}");
                }
            }
        }
    }

    // 🔹 GET COMMENTS
    private void handleGetComments(HttpServletRequest req, PrintWriter out, String path)
            throws Exception {
        int postId = extractIdFromPath(path);
        int page = parseIntParam(req, "page", 1);
        int limit = parseIntParam(req, "limit", 20);

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_get_comments(?, ?, ?)}")) {

            cs.setInt(1, postId);
            cs.setInt(2, page);
            cs.setInt(3, limit);

            try (ResultSet rs = cs.executeQuery()) {
                List<Map<String, Object>> comments = new ArrayList<>();
                while (rs.next()) {
                    Map<String, Object> comment = new LinkedHashMap<>();
                    comment.put("comment_id", rs.getInt("comment_id"));
                    comment.put("user_id", rs.getInt("user_id"));
                    comment.put("username", rs.getString("username"));
                    comment.put("profile_image", rs.getString("profile_image"));
                    comment.put("content", rs.getString("content"));
                    comment.put("created_at", rs.getTimestamp("created_at"));
                    // ✅ Handles NULL gracefully for top-level comments
                    comment.put("parent_comment_id", rs.getObject("parent_comment_id"));
                    comment.put("reply_count", rs.getLong("reply_count"));
                    comments.add(comment);
                }
                JsonObject res = new JsonObject();
                res.add("comments", gson.toJsonTree(comments));
                res.addProperty("page", page);
                res.addProperty("limit", limit);
                out.print(res);
            }
        }
    }

    // 🔹 DELETE COMMENT
    private void handleDeleteComment(HttpServletRequest req, HttpServletResponse resp, PrintWriter out, String path)
            throws Exception {
        String sessionIdStr = req.getHeader("X-Session-Id");
        if (sessionIdStr == null) {
            resp.setStatus(401);
            out.print("{\"error\":\"Unauthorized\"}");
            return;
        }

        UUID sessionId = UUID.fromString(sessionIdStr);
        // Extract comment_id from path: /comments/{id}
        int commentId = Integer.parseInt(path.substring(path.lastIndexOf('/') + 1));

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_delete_comment(?, ?)}")) {

            cs.setObject(1, sessionId, Types.OTHER);
            cs.setInt(2, commentId);

            try (ResultSet rs = cs.executeQuery()) {
                if (rs.next() && rs.getBoolean("success")) {
                    out.print("{\"message\":\"" + escapeJson(rs.getString("message")) + "\"}");
                } else {
                    resp.setStatus(400);
                    out.print("{\"error\":\"" + escapeJson(rs.getString("error")) + "\"}");
                }
            }
        }
    }

    // 🔹 GET USER'S POSTS
    private void handleGetUserPosts(HttpServletRequest req, PrintWriter out, String path)
            throws Exception {
        // Extract user_id from path: /users/{id}
        int userId = Integer.parseInt(path.substring(path.lastIndexOf('/') + 1));
        int page = parseIntParam(req, "page", 1);
        int limit = parseIntParam(req, "limit", 20);
        boolean includeUnpublished = "true".equalsIgnoreCase(req.getParameter("include_unpublished"));

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_get_user_posts(?, ?, ?, ?)}")) {

            cs.setInt(1, userId);
            cs.setInt(2, page);
            cs.setInt(3, limit);
            cs.setBoolean(4, includeUnpublished);

            try (ResultSet rs = cs.executeQuery()) {
                List<Map<String, Object>> posts = new ArrayList<>();
                while (rs.next()) {
                    Map<String, Object> post = new LinkedHashMap<>();
                    post.put("post_id", rs.getInt("post_id"));
                    post.put("title", rs.getString("title"));
                    post.put("cover_image", rs.getString("cover_image"));
                    post.put("is_published", rs.getBoolean("is_published"));
                    post.put("created_at", rs.getTimestamp("created_at"));
                    post.put("like_count", rs.getLong("like_count"));
                    post.put("comment_count", rs.getLong("comment_count"));
                    posts.add(post);
                }
                JsonObject res = new JsonObject();
                res.add("posts", gson.toJsonTree(posts));
                res.addProperty("page", page);
                res.addProperty("limit", limit);
                out.print(res);
            }
        }
    }

    // 🔹 GET USER'S BOOKMARKS
    private void handleGetBookmarks(HttpServletRequest req, HttpServletResponse resp, PrintWriter out)
            throws Exception {
        String sessionIdStr = req.getHeader("X-Session-Id");
        if (sessionIdStr == null) {
            resp.setStatus(401);
            out.print("{\"error\":\"Unauthorized\"}");
            return;
        }

        UUID sessionId = UUID.fromString(sessionIdStr);
        int page = parseIntParam(req, "page", 1);
        int limit = parseIntParam(req, "limit", 20);

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_get_bookmarked_posts(?, ?, ?)}")) {

            cs.setObject(1, sessionId, Types.OTHER);
            cs.setInt(2, page);
            cs.setInt(3, limit);

            try (ResultSet rs = cs.executeQuery()) {
                List<Map<String, Object>> posts = new ArrayList<>();
                while (rs.next()) {
                    Map<String, Object> post = new LinkedHashMap<>();
                    post.put("post_id", rs.getInt("post_id"));
                    post.put("title", rs.getString("title"));
                    post.put("cover_image", rs.getString("cover_image"));
                    post.put("created_at", rs.getTimestamp("created_at"));
                    post.put("like_count", rs.getLong("like_count"));
                    post.put("comment_count", rs.getLong("comment_count"));
                    posts.add(post);
                }
                JsonObject res = new JsonObject();
                res.add("bookmarks", gson.toJsonTree(posts));
                res.addProperty("page", page);
                res.addProperty("limit", limit);
                out.print(res);
            }
        }
    }

    // 🔹 UTILS
    private int extractIdFromPath(String path) {
        // Extract numeric ID from path like "/123" or "/123/like"
        String[] parts = path.split("/");
        for (String part : parts) {
            if (!part.isEmpty() && part.matches("\\d+")) {
                return Integer.parseInt(part);
            }
        }
        throw new IllegalArgumentException("Invalid path: " + path);
    }

    private int parseIntParam(HttpServletRequest req, String name, int defaultValue) {
        try {
            return Integer.parseInt(req.getParameter(name));
        } catch (NumberFormatException e) {
            return defaultValue;
        }
    }

    private String[] jsonArrayToStringArray(JsonArray jsonArray) {
        if (jsonArray == null)
            return null;
        String[] arr = new String[jsonArray.size()];
        for (int i = 0; i < jsonArray.size(); i++) {
            arr[i] = jsonArray.get(i).getAsString();
        }
        return arr;
    }

    private Map<String, Object> resultSetToMap(ResultSet rs) throws SQLException {
        Map<String, Object> map = new LinkedHashMap<>();
        ResultSetMetaData md = rs.getMetaData();
        for (int i = 1; i <= md.getColumnCount(); i++) {
            String label = md.getColumnLabel(i);
            Object value = rs.getObject(i);
            // Handle timestamps as ISO strings for JSON
            if (value instanceof java.sql.Timestamp) {
                map.put(label, value.toString());
            } else {
                map.put(label, value);
            }
        }
        return map;
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
