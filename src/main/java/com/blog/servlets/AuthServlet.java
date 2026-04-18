package com.blog.servlets;

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
            } else if (path != null && path.startsWith("/followers/")) {
                handleFollowers(resp, out, path);
            } else if (path != null && path.startsWith("/following/")) {
                handleFollowing(resp, out, path);
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
                        UUID sessionId = (UUID) rs.getObject("session_id");
                        int userId = rs.getInt("user_id");
                        out.print("{\"session_id\":\"" + sessionId + "\", \"user_id\":" + userId + "}");
                    } else {
                        resp.setStatus(401);
                        out.print("{\"error\":\"" + escapeJson(rs.getString("error")) + "\"}");
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
                    Map<String, Object> profile = new LinkedHashMap<>();
                    profile.put("user_id", rs.getObject("user_id"));
                    profile.put("username", rs.getString("username"));
                    profile.put("email", rs.getString("email"));
                    profile.put("bio", rs.getString("bio"));
                    profile.put("profile_image", rs.getString("profile_image"));
                    profile.put("theme", rs.getString("theme"));
                    profile.put("email_notifications", rs.getBoolean("email_notifications"));
                    profile.put("push_notifications", rs.getBoolean("push_notifications"));
                    profile.put("privacy_mode", rs.getString("privacy_mode"));
                    out.print(gson.toJson(profile));
                } else {
                    resp.setStatus(401);
                    out.print("{\"error\":\"" + escapeJson(rs.getString("error")) + "\"}");
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
    private void handleFollowers(HttpServletResponse resp, PrintWriter out, String path) throws Exception {
        int userId;
        try {
            userId = Integer.parseInt(path.substring(path.lastIndexOf('/') + 1));
        } catch (NumberFormatException e) {
            resp.setStatus(400);
            out.print("{\"error\":\"Invalid user ID\"}");
            return;
        }

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_get_followers(?)}")) {

            cs.setInt(1, userId);

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
    private void handleFollowing(HttpServletResponse resp, PrintWriter out, String path) throws Exception {
        int userId;
        try {
            userId = Integer.parseInt(path.substring(path.lastIndexOf('/') + 1));
        } catch (NumberFormatException e) {
            resp.setStatus(400);
            out.print("{\"error\":\"Invalid user ID\"}");
            return;
        }

        try (Connection conn = DBConnection.getConnection();
                CallableStatement cs = conn.prepareCall("{call fn_get_following(?)}")) {

            cs.setInt(1, userId);

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