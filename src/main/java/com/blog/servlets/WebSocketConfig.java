// lib/servlets/WebSocketConfig.java
package com.blog.servlets;

import jakarta.websocket.DeploymentException;
import jakarta.websocket.server.ServerContainer;
import jakarta.websocket.server.ServerEndpointConfig;

public class WebSocketConfig {

    public static void registerEndpoints(ServerContainer container) {
        try {
            container.addEndpoint(
                    ServerEndpointConfig.Builder
                            .create(NotificationWebSocketServlet.class, "/ws/notifications")
                            .build());
            System.out.println("✅ WebSocket endpoint registered: /ws/notifications");
        } catch (DeploymentException e) {
            System.err.println("❌ Failed to register WebSocket endpoint: " + e.getMessage());
            e.printStackTrace();
        }
    }
}