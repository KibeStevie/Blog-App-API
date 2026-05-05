// lib/websocket/NotificationWebSocketServlet.java
package com.blog.servlets; // ✅ Updated package path

// ✅ ADD THESE MISSING IMPORTS
import jakarta.websocket.OnClose;
import jakarta.websocket.OnError;
import jakarta.websocket.OnMessage;
import jakarta.websocket.OnOpen;
import jakarta.websocket.Session;
import jakarta.websocket.server.ServerEndpoint;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.io.IOException;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

@ServerEndpoint("/ws/notifications")
public class NotificationWebSocketServlet {

    // ✅ Store connected sessions by user ID
    private static final Map<String, Session> userSessions = new ConcurrentHashMap<>();

    @OnOpen
    public void onOpen(Session session) {
        System.out.println("🔌 WebSocket connected: " + session.getId());
    }

    @OnMessage
    public void onMessage(String message, Session session) {
        try {
            // ✅ Parse registration message: {"type":"register","userId":"123"}
            JsonObject json = JsonParser.parseString(message).getAsJsonObject();

            if ("register".equals(json.get("type").getAsString())) {
                String userId = json.get("userId").getAsString();
                userSessions.put(userId, session);
                System.out.println("✅ Registered user " + userId + " for notifications");

                // ✅ Send ack back to client
                JsonObject ack = new JsonObject();
                ack.addProperty("type", "ack");
                ack.addProperty("message", "Registered");
                ack.addProperty("userId", userId); 
                session.getBasicRemote().sendText(ack.toString());
            }
        } catch (Exception e) {
            System.err.println("❌ Error parsing WebSocket message: " + e.getMessage());
        }
    }

    @OnClose
    public void onClose(Session session) {
        // ✅ Remove session from map
        userSessions.values().removeIf(s -> s.equals(session));
        System.out.println("🔌 WebSocket disconnected: " + session.getId());
    }

    @OnError
    public void onError(Session session, Throwable error) {
        System.err.println("❌ WebSocket error: " + error.getMessage());
        error.printStackTrace();
    }

    // ✅ Public method to send notification to specific user
    public static void sendNotificationToUser(String userId, JsonObject notification) {
        Session session = userSessions.get(userId);
        if (session != null && session.isOpen()) {
            try {
                session.getBasicRemote().sendText(notification.toString());
                System.out.println("📤 Sent notification to user " + userId);
            } catch (IOException e) {
                System.err.println("❌ Failed to send notification: " + e.getMessage());
                userSessions.remove(userId);
            }
        } else {
            System.out.println("⚠️ User " + userId + " not connected via WebSocket");
        }
    }

    // ✅ Broadcast to all connected users (for admin alerts, etc.)
    public static void broadcastNotification(JsonObject notification) {
        for (Session session : userSessions.values()) {
            if (session.isOpen()) {
                try {
                    session.getBasicRemote().sendText(notification.toString());
                } catch (IOException e) {
                    System.err.println("❌ Failed to broadcast: " + e.getMessage());
                }
            }
        }
    }

    // ✅ Helper: Get count of connected users (for monitoring)
    public static int getConnectedUserCount() {
        return userSessions.size();
    }

    // ✅ Helper: Check if user is connected
    public static boolean isUserConnected(String userId) {
        Session session = userSessions.get(userId);
        return session != null && session.isOpen();
    }
}