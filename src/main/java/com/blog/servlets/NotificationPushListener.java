package com.blog.servlets;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

import com.blog.db.DBConnection;
import com.google.gson.JsonObject;

public class NotificationPushListener {

    private final ScheduledExecutorService scheduler = Executors.newScheduledThreadPool(1);
    private static final int POLL_INTERVAL_SECONDS = 10;
    private static final int BATCH_LIMIT = 10;

    public void start() {
        System.out.println("🔔 NotificationPushListener started (polling every " + POLL_INTERVAL_SECONDS + "s)");
        scheduler.scheduleAtFixedRate(this::checkAndPushNotifications, 0, POLL_INTERVAL_SECONDS, TimeUnit.SECONDS);
    }

    private void checkAndPushNotifications() {
        try (Connection conn = DBConnection.getConnection();
                PreparedStatement stmt = conn.prepareStatement(
                        "SELECT " +
                                "  n.notification_id, " +
                                "  n.user_id, " +
                                "  n.actor_id, " +
                                "  u.username AS actor_username, " + // ✅ NEW: Fetch actor's username
                                "  n.type, " +
                                "  n.reference_id, " +
                                "  n.message, " +
                                "  n.is_read " +
                                "FROM notifications n " +
                                "LEFT JOIN users u ON n.actor_id = u.user_id " + // ✅ LEFT JOIN to handle deleted users
                                "WHERE n.pushed_via_ws = FALSE " +
                                "  AND n.is_read = FALSE " +
                                "ORDER BY n.created_at DESC " +
                                "LIMIT ?");) {

            stmt.setInt(1, BATCH_LIMIT);
            ResultSet rs = stmt.executeQuery();

            int pushedCount = 0;

            while (rs.next()) {
                int notificationId = rs.getInt("notification_id");
                int userId = rs.getInt("user_id"); // ✅ Recipient
                int actorId = rs.getInt("actor_id"); // ✅ Who performed action
                String actorUsername = rs.getString("actor_username");
                String type = rs.getString("type"); // ✅ 'like', 'comment', etc.
                Integer referenceId = rs.getObject("reference_id", Integer.class); // ✅ Post/comment ID
                String message = rs.getString("message");

                // ✅ Skip if already read (double-check)
                if (rs.getBoolean("is_read")) {
                    markAsPushed(conn, notificationId);
                    continue;
                }

                // ✅ Build notification payload for Flutter app
                JsonObject payload = new JsonObject();
                payload.addProperty("type", "notification");
                payload.addProperty("title", "New " + formatNotificationType(type));
                payload.addProperty("body", message != null ? message : "You have a new notification");
                payload.addProperty("actorId", actorId); // ✅ Who did the action
                payload.addProperty("actorUsername", actorUsername);
                payload.addProperty("referenceId", referenceId); // ✅ Post/comment ID
                payload.addProperty("notificationType", type);
                payload.addProperty("notificationId", notificationId);

                // ✅ Push via WebSocket to specific user
                NotificationWebSocketServlet.sendNotificationToUser(
                        String.valueOf(userId), payload);

                // ✅ Mark as pushed to avoid duplicate pushes
                markAsPushed(conn, notificationId);

                pushedCount++;
                System.out.println("📤 Pushed notification #" + notificationId + " to user " + userId);
            }

            if (pushedCount > 0) {
                System.out.println("✅ Batch complete: pushed " + pushedCount + " notifications");
            }

        } catch (SQLException e) {
            System.err.println("❌ Error checking notifications: " + e.getMessage());
            e.printStackTrace();
            // Don't throw - let scheduler continue polling
        }
    }

    // ✅ Helper: Mark notification as pushed
    private void markAsPushed(Connection conn, int notificationId) throws SQLException {
        try (PreparedStatement update = conn.prepareStatement(
                "UPDATE notifications SET pushed_via_ws = TRUE WHERE notification_id = ?")) {
            update.setInt(1, notificationId);
            update.executeUpdate();
        }
    }

    // ✅ Helper: Format notification type for display title
    private String formatNotificationType(String type) {
        if (type == null)
            return "notification";
        return switch (type.toLowerCase()) {
            case "follow" -> "follower";
            case "like" -> "like";
            case "comment" -> "comment";
            case "comment_reply" -> "reply";
            case "bookmark" -> "bookmark";
            case "award" -> "award";
            default -> "notification";
        };
    }

    public void stop() {
        System.out.println("🔔 NotificationPushListener stopping...");
        scheduler.shutdown();
        try {
            if (!scheduler.awaitTermination(5, TimeUnit.SECONDS)) {
                scheduler.shutdownNow();
            }
        } catch (InterruptedException e) {
            scheduler.shutdownNow();
            Thread.currentThread().interrupt();
        }
        System.out.println("✅ NotificationPushListener stopped");
    }
}