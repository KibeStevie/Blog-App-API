package com.blog.servlets;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.PrintWriter;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.sql.CallableStatement;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.Types;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import com.blog.db.DBConnection;
import com.google.gson.Gson;
import com.google.gson.JsonObject;

import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

public class AuthServlet extends HttpServlet {
    private final Gson gson = new Gson();

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        resp.setContentType("application/json");
        PrintWriter out = resp.getWriter();
        String path = req.getPathInfo();

        try {
            if ("/register".equals(path)) {
                handleRegister(req, resp, out);
            } else if ("/login".equals(path)) {
                handleLogin(req, resp, out);
            } else if ("/notifications".equals(path)) {
                handleUpdateNotificationStatus(req, resp, out);
            } else if (path != null && path.startsWith("/unfollow/")) {
                handleUnfollow(req, resp, out, path);
            } else if ("/logout".equals(path)) {
                handleLogout(req, resp, out);
            } else if (path != null && path.startsWith("/follow/")) {
                handleFollow(req, resp, out, path);
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
            if ("/session".equals(path)) {
                handleGetSession(req, resp, out);
            } else if ("/settings".equals(path)) {
                handleGetSettings(req, resp, out);
            } else if ("/notifications".equals(path)) {
                handleGetNotifications(req, resp, out);
            } else if ("/followers".equals(path)) {
                handleFollowers(req, resp, out);
            } else if ("/following".equals(path)) {
                handleFollowing(req, resp, out);
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
        if ("/settings".equals(req.getPathInfo())) {
            try {
                handleUpdateSettings(req, resp, out);
            } catch (Exception ex) {
                resp.setStatus(500);
                out.print("{\"error\":\"" + escapeJson(ex.getMessage()) + "\"}");
            }
        } else {
            resp.setStatus(400);
            out.print("{\"error\":\"Unknown endpoint\"}");
        }
    }

    @Override
    protected void doDelete(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        resp.setContentType("application/json");
        PrintWriter out = resp.getWriter();
        String path = req.getPathInfo();

        try {
            if (path != null && path.startsWith("/notifications/")) {
                handleDeleteNotification(req, resp, out, path);
            } else {
                resp.setStatus(400);
                out.print("{\"error\":\"Unknown endpoint\"}");
            }
        } catch (Exception e) {
            resp.setStatus(500);
            out.print("{\"error\":\"" + escapeJson(e.getMessage()) + "\"}");
        }
    }

    // 🔹 REGISTER - Calls fn_register_user
    private void handleRegister(HttpServletRequest req, HttpServletResponse resp, PrintWriter out) throws Exception {
        JsonObject json = gson.fromJson(req.getReader(), JsonObject.class);
        String username = json.get("username").getAsString();
        String email = json.get("email").getAsString();
        String password = json.get("password").getAsString();
        String hash = hashPassword(password);

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_register_user(?, ?, ?)}")) {

            cs.setString(1, username);
            cs.setString(2, email);
            cs.setString(3, hash);

            try (ResultSet rs = cs.executeQuery()) {
                if (rs.next()) {
                    boolean success = rs.getBoolean("success");
                    if (success) {
                        int userId = rs.getInt("user_id");
                        String message = rs.getString("message");
                        out.print("{\"user_id\":" + userId + ", \"message\":\"" + escapeJson(message) + "\"}");
                    } else {
                        resp.setStatus(400);
                        out.print("{\"error\":\"" + escapeJson(rs.getString("error")) + "\"}");
                    }
                }
            }
        }
    }

    // 🔹 LOGIN - Calls fn_login_user
    private void handleLogin(HttpServletRequest req, HttpServletResponse resp, PrintWriter out) throws Exception {
        JsonObject json = gson.fromJson(req.getReader(), JsonObject.class);
        String email = json.get("email").getAsString();
        String password = json.get("password").getAsString();
        String hash = hashPassword(password);

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_login_user(?, ?)}")) {

            cs.setString(1, email);
            cs.setString(2, hash);

            try (ResultSet rs = cs.executeQuery()) {
                if (rs.next()) {
                    boolean success = rs.getBoolean("success");
                    if (success) {
                        JsonObject dataObj = new JsonObject();
                        dataObj.addProperty("session_id", rs.getObject("session_id", UUID.class).toString());
                        dataObj.addProperty("user_id", rs.getInt("user_id"));
                        JsonObject response = new JsonObject();
                        response.addProperty("success", true);
                        response.addProperty("message", rs.getString("message"));
                        response.add("data", dataObj);
                        out.print(gson.toJson(response));
                    } else {
                        resp.setStatus(401);
                        JsonObject response = new JsonObject();
                        response.addProperty("success", false);
                        response.addProperty("message", rs.getString("message"));
                        out.print(gson.toJson(response));
                    }
                }
            }
        }
    }

    // 🔹 VALIDATE SESSION - Calls fn_validate_session
    private void handleGetSession(HttpServletRequest req, HttpServletResponse resp, PrintWriter out) throws Exception {
        String sessionIdStr = req.getHeader("X-Session-Id");
        if (sessionIdStr == null || sessionIdStr.isEmpty()) {
            out.print("{\"error\":\"Session ID missing\"}");
            return;
        }

        UUID sessionId;
        try {
            sessionId = UUID.fromString(sessionIdStr);
        } catch (IllegalArgumentException e) {
            out.print("{\"error\":\"Invalid session ID format\"}");
            return;
        }

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_validate_session(?)}")) {

            cs.setObject(1, sessionId, Types.OTHER);

            try (ResultSet rs = cs.executeQuery()) {
                if (rs.next() && rs.getBoolean("success")) {
                    JsonObject dataObj = new JsonObject();
                    dataObj.addProperty("user_id", rs.getInt("user_id"));
                    dataObj.addProperty("username", rs.getString("username"));
                    dataObj.addProperty("email", rs.getString("email"));
                    dataObj.addProperty("bio", rs.getString("bio"));
                    dataObj.addProperty("profile_image", rs.getString("profile_image"));
                    dataObj.addProperty("theme", rs.getString("theme"));
                    dataObj.addProperty("email_notifications", rs.getBoolean("email_notifications"));
                    dataObj.addProperty("push_notifications", rs.getBoolean("push_notifications"));
                    dataObj.addProperty("privacy_mode", rs.getString("privacy_mode"));

                    JsonObject response = new JsonObject();
                    response.addProperty("success", true);
                    response.add("data", dataObj);
                    out.print(gson.toJson(response));
                } else {
                    resp.setStatus(401);
                    JsonObject response = new JsonObject();
                    response.addProperty("success", false);
                    response.addProperty("message", rs.getString("error"));
                    out.print(gson.toJson(response));
                }
            }
        }
    }

    // 🔹 FOLLOW - Calls fn_follow_user
    private void handleFollow(HttpServletRequest req, HttpServletResponse resp, PrintWriter out, String path)
            throws Exception {
        String sessionIdStr = req.getHeader("X-Session-Id");
        if (sessionIdStr == null) {
            resp.setStatus(401);
            out.print("{\"error\":\"Unauthorized\"}");
            return;
        }

        int followingId;
        try {
            followingId = Integer.parseInt(path.substring(path.lastIndexOf('/') + 1));
        } catch (NumberFormatException e) {
            resp.setStatus(400);
            out.print("{\"error\":\"Invalid user ID\"}");
            return;
        }

        UUID sessionId;
        try {
            sessionId = UUID.fromString(sessionIdStr);
        } catch (IllegalArgumentException e) {
            out.print("{\"error\":\"Invalid session ID format\"}");
            return;
        }

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_follow_user(?, ?)}")) {

            cs.setObject(1, sessionId, Types.OTHER);
            cs.setInt(2, followingId);

            try (ResultSet rs = cs.executeQuery()) {
                if (rs.next()) {
                    boolean success = rs.getBoolean("success");
                    if (success) {
                        out.print("{\"message\":\"" + escapeJson(rs.getString("message")) + "\"}");
                    } else {
                        resp.setStatus(400);
                        out.print("{\"error\":\"" + escapeJson(rs.getString("error")) + "\"}");
                    }
                }
            }
        }
    }

    // 🔹 UNFOLLOW - Calls fn_unfollow_user
    private void handleUnfollow(HttpServletRequest req, HttpServletResponse resp, PrintWriter out, String path)
            throws Exception {
        String sessionIdStr = req.getHeader("X-Session-Id");
        if (sessionIdStr == null) {
            resp.setStatus(401);
            out.print("{\"error\":\"Unauthorized\"}");
            return;
        }

        int followingId;
        try {
            followingId = Integer.parseInt(path.substring(path.lastIndexOf('/') + 1));
        } catch (NumberFormatException e) {
            resp.setStatus(400);
            out.print("{\"error\":\"Invalid user ID\"}");
            return;
        }

        UUID sessionId;
        try {
            sessionId = UUID.fromString(sessionIdStr);
        } catch (IllegalArgumentException e) {
            out.print("{\"error\":\"Invalid session ID format\"}");
            return;
        }

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_unfollow_user(?, ?)}")) {

            cs.setObject(1, sessionId, Types.OTHER);
            cs.setInt(2, followingId);

            try (ResultSet rs = cs.executeQuery()) {
                if (rs.next()) {
                    boolean success = rs.getBoolean("success");
                    if (success) {
                        out.print("{\"message\":\"" + escapeJson(rs.getString("message")) + "\"}");
                    } else {
                        resp.setStatus(400);
                        out.print("{\"error\":\"" + escapeJson(rs.getString("error")) + "\"}");
                    }
                }
            }
        }
    }

    // 🔹 GET FOLLOWERS - Calls fn_get_followers
    private void handleFollowers(HttpServletRequest req, HttpServletResponse resp, PrintWriter out) throws Exception {
        String sessionIdStr = req.getHeader("X-Session-Id");
        if (sessionIdStr == null) {
            resp.setStatus(401);
            out.print("{\"error\":\"Unauthorized\"}");
            return;
        }

        UUID sessionId = UUID.fromString(sessionIdStr);

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_get_followers(?)}")) {

            cs.setObject(1, sessionId, Types.OTHER);

            try (ResultSet rs = cs.executeQuery()) {
                List<Map<String, Object>> list = new ArrayList<>();
                int count = 0;
                while (rs.next()) {
                    Map<String, Object> row = new LinkedHashMap<>();
                    row.put("user_id", rs.getInt("user_id"));
                    row.put("username", rs.getString("username"));
                    row.put("profile_image", rs.getString("profile_image"));
                    row.put("followed_at", rs.getTimestamp("created_at"));
                    list.add(row);
                    count++;
                }
                JsonObject res = new JsonObject();
                res.add("followers", gson.toJsonTree(list));
                res.addProperty("count", count);
                out.print(res);
            }
        }
    }

    // 🔹 GET FOLLOWING - Calls fn_get_following
    private void handleFollowing(HttpServletRequest req, HttpServletResponse resp, PrintWriter out) throws Exception {
        String sessionIdStr = req.getHeader("X-Session-Id");
        if (sessionIdStr == null) {
            resp.setStatus(401);
            out.print("{\"error\":\"Unauthorized\"}");
            return;
        }

        UUID sessionId = UUID.fromString(sessionIdStr);

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_get_following(?)}")) {

            cs.setObject(1, sessionId, Types.OTHER);

            try (ResultSet rs = cs.executeQuery()) {
                List<Map<String, Object>> list = new ArrayList<>();
                int count = 0;
                while (rs.next()) {
                    Map<String, Object> row = new LinkedHashMap<>();
                    row.put("user_id", rs.getInt("user_id"));
                    row.put("username", rs.getString("username"));
                    row.put("profile_image", rs.getString("profile_image"));
                    row.put("followed_at", rs.getTimestamp("created_at"));
                    list.add(row);
                    count++;
                }
                JsonObject res = new JsonObject();
                res.add("following", gson.toJsonTree(list));
                res.addProperty("count", count);
                out.print(res);
            }
        }
    }

    // 🔹 UPDATE SETTINGS - Calls fn_update_user_settings
    private void handleUpdateSettings(HttpServletRequest req, HttpServletResponse resp, PrintWriter out)
            throws Exception {
        String sessionIdStr = req.getHeader("X-Session-Id");
        if (sessionIdStr == null) {
            resp.setStatus(401);
            out.print("{\"error\":\"Unauthorized\"}");
            return;
        }

        UUID sessionId;
        try {
            sessionId = UUID.fromString(sessionIdStr);
        } catch (IllegalArgumentException e) {
            out.print("{\"error\":\"Invalid session ID format\"}");
            return;
        }

        JsonObject json = gson.fromJson(req.getReader(), JsonObject.class);

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_update_user_settings(?, ?, ?, ?, ?)}")) {

            cs.setObject(1, sessionId, Types.OTHER);
            cs.setString(2, json.has("theme") ? json.get("theme").getAsString() : null);
            cs.setObject(3, json.has("email_notifications") ? json.get("email_notifications").getAsBoolean() : null);
            cs.setObject(4, json.has("push_notifications") ? json.get("push_notifications").getAsBoolean() : null);
            cs.setString(5, json.has("privacy_mode") ? json.get("privacy_mode").getAsString() : null);

            try (ResultSet rs = cs.executeQuery()) {
                if (rs.next()) {
                    boolean success = rs.getBoolean("success");
                    if (success) {
                        out.print("{\"message\":\"" + escapeJson(rs.getString("message")) + "\"}");
                    } else {
                        resp.setStatus(400);
                        out.print("{\"error\":\"" + escapeJson(rs.getString("error")) + "\"}");
                    }
                }
            }
        }
    }

    // 🔹 LOGOUT - Calls fn_logout_user
    private void handleLogout(HttpServletRequest req, HttpServletResponse resp, PrintWriter out) throws Exception {
        String sessionIdStr = req.getHeader("X-Session-Id");
        if (sessionIdStr == null) {
            resp.setStatus(401);
            out.print("{\"error\":\"Unauthorized\"}");
            return;
        }

        UUID sessionId;
        try {
            sessionId = UUID.fromString(sessionIdStr);
        } catch (IllegalArgumentException e) {
            out.print("{\"error\":\"Invalid session ID format\"}");
            return;
        }

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_logout_user(?)}")) {

            cs.setObject(1, sessionId, Types.OTHER);

            try (ResultSet rs = cs.executeQuery()) {
                if (rs.next()) {
                    out.print("{\"message\":\"" + escapeJson(rs.getString("message")) + "\"}");
                }
            }
        }
    }

    // 🔹 GET SETTINGS (via session) - Calls fn_validate_session and filters
    private void handleGetSettings(HttpServletRequest req, HttpServletResponse resp, PrintWriter out) throws Exception {
        String sessionIdStr = req.getHeader("X-Session-Id");
        if (sessionIdStr == null) {
            resp.setStatus(401);
            out.print("{\"error\":\"Unauthorized\"}");
            return;
        }

        UUID sessionId;
        try {
            sessionId = UUID.fromString(sessionIdStr);
        } catch (IllegalArgumentException e) {
            out.print("{\"error\":\"Invalid session ID format\"}");
            return;
        }

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_validate_session(?)}")) {

            cs.setObject(1, sessionId, Types.OTHER);

            try (ResultSet rs = cs.executeQuery()) {
                if (rs.next() && rs.getBoolean("success")) {
                    Map<String, Object> settings = new LinkedHashMap<>();
                    settings.put("theme", rs.getString("theme"));
                    settings.put("email_notifications", rs.getBoolean("email_notifications"));
                    settings.put("push_notifications", rs.getBoolean("push_notifications"));
                    settings.put("privacy_mode", rs.getString("privacy_mode"));
                    out.print(gson.toJson(settings));
                } else {
                    resp.setStatus(401);
                    out.print("{\"error\":\"" + escapeJson(rs.getString("error")) + "\"}");
                }
            }
        }
    }

    private void handleGetNotifications(HttpServletRequest req, HttpServletResponse resp, PrintWriter out)
            throws Exception {

        String sessionId = req.getHeader("X-Session-Id");
        if (sessionId == null || sessionId.isEmpty()) {
            resp.setStatus(401);
            out.print("{\"error\":\"Missing session ID\"}");
            return;
        }

        int page = parseIntParam(req, "page", 1);
        int limit = parseIntParam(req, "limit", 20);
        boolean unreadOnly = Boolean.parseBoolean(req.getParameter("unread_only"));

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_get_notifications(?, ?, ?, ?)}")) {

            cs.setObject(1, UUID.fromString(sessionId), Types.OTHER);
            cs.setInt(2, page);
            cs.setInt(3, limit);
            cs.setBoolean(4, unreadOnly);

            try (ResultSet rs = cs.executeQuery()) {
                List<Map<String, Object>> notifications = new ArrayList<>();
                long totalCount = 0;

                while (rs.next()) {
                    Map<String, Object> notif = new LinkedHashMap<>();
                    notif.put("notification_id", rs.getInt("notification_id"));
                    notif.put("type", rs.getString("type"));
                    notif.put("message", rs.getString("message"));
                    notif.put("is_read", rs.getBoolean("is_read"));
                    notif.put("created_at", rs.getTimestamp("created_at"));
                    notif.put("reference_id", rs.getInt("reference_id"));
                    notif.put("actor_username", rs.getString("actor_username"));
                    notifications.add(notif);
                }

                JsonObject res = new JsonObject();
                res.add("notifications", gson.toJsonTree(notifications));
                res.addProperty("total", totalCount);
                res.addProperty("page", page);
                res.addProperty("limit", limit);
                out.print(res);
            }
        }
    }

    private void handleUpdateNotificationStatus(HttpServletRequest req, HttpServletResponse resp, PrintWriter out)
            throws Exception {

        String sessionId = req.getHeader("X-Session-Id");
        if (sessionId == null || sessionId.isEmpty()) {
            resp.setStatus(401);
            out.print("{\"error\":\"Missing session ID\"}");
            return;
        }

        // Parse JSON Body
        StringBuilder sb = new StringBuilder();
        BufferedReader reader = req.getReader();
        String line;
        while ((line = reader.readLine()) != null) {
            sb.append(line);
        }

        if (sb.length() == 0) {
            resp.setStatus(400);
            out.print("{\"error\":\"Request body is empty\"}");
            return;
        }

        JsonObject jsonBody = gson.fromJson(sb.toString(), JsonObject.class);

        if (!jsonBody.has("notification_id") || !jsonBody.has("is_read")) {
            resp.setStatus(400);
            out.print("{\"error\":\"Missing notification_id or is_read\"}");
            return;
        }

        int notificationId = jsonBody.get("notification_id").getAsInt();
        boolean isRead = jsonBody.get("is_read").getAsBoolean();

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_update_notification_status(?, ?, ?)}")) {

            cs.setObject(1, UUID.fromString(sessionId), Types.OTHER);
            cs.setInt(2, notificationId);
            cs.setBoolean(3, isRead);

            try (ResultSet rs = cs.executeQuery()) {
                if (rs.next()) {
                    boolean success = rs.getBoolean("success");
                    String message = rs.getString("message");
                    String error = rs.getString("error");

                    JsonObject res = new JsonObject();
                    res.addProperty("success", success);

                    if (success) {
                        res.addProperty("message", message);
                        out.print(res);
                    } else {
                        resp.setStatus(400); // Or 403 if unauthorized
                        res.addProperty("error", error);
                        out.print(res);
                    }
                }
            }
        }
    }

    private void handleDeleteNotification(HttpServletRequest req, HttpServletResponse resp, PrintWriter out,
            String path)
            throws Exception {

        String sessionId = req.getHeader("X-Session-Id");
        if (sessionId == null || sessionId.isEmpty()) {
            resp.setStatus(401);
            out.print("{\"error\":\"Missing session ID\"}");
            return;
        }

        // Extract ID from path: /notifications/5 -> 5
        String[] parts = path.split("/");
        if (parts.length < 3) {
            resp.setStatus(400);
            out.print("{\"error\":\"Invalid path. Use /notifications/{id}\"}");
            return;
        }

        int notificationId;
        try {
            notificationId = Integer.parseInt(parts[2]);
        } catch (NumberFormatException e) {
            resp.setStatus(400);
            out.print("{\"error\":\"Invalid notification ID\"}");
            return;
        }

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_delete_notification(?, ?)}")) {

            cs.setObject(1, UUID.fromString(sessionId), Types.OTHER);
            cs.setInt(2, notificationId);

            try (ResultSet rs = cs.executeQuery()) {
                if (rs.next()) {
                    boolean success = rs.getBoolean("success");
                    String message = rs.getString("message");
                    String error = rs.getString("error");

                    JsonObject res = new JsonObject();
                    res.addProperty("success", success);

                    if (success) {
                        res.addProperty("message", message);
                        out.print(res);
                    } else {
                        resp.setStatus(400); // Or 404 if not found
                        res.addProperty("error", error);
                        out.print(res);
                    }
                }
            }
        }
    }

    private int parseIntParam(HttpServletRequest req, String name, int defaultValue) {
        try {
            return Integer.parseInt(req.getParameter(name));
        } catch (NumberFormatException e) {
            return defaultValue;
        }
    }

    // 🔹 UTILS
    private String hashPassword(String password) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] hash = md.digest(password.getBytes());
            StringBuilder sb = new StringBuilder();
            for (byte b : hash)
                sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (NoSuchAlgorithmException e) {
            throw new RuntimeException("Password hashing failed", e);
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