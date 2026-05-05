// lib/servlets/AppContextListener.java
package com.blog.servlets;

import jakarta.servlet.ServletContextEvent;
import jakarta.servlet.ServletContextListener;
import jakarta.servlet.annotation.WebListener;
import jakarta.websocket.server.ServerContainer;

@WebListener // ✅ Ensure this annotation is present
public class AppContextListener implements ServletContextListener {

    private NotificationPushListener notificationListener;

    @Override
    public void contextInitialized(ServletContextEvent sce) {
        System.out.println("🚀 Application starting...");

        try {
            // ✅ Start notification push listener (polls DB → pushes via WebSocket)
            notificationListener = new NotificationPushListener();
            notificationListener.start();

            // ✅ Register WebSocket endpoints programmatically
            ServerContainer container = (ServerContainer) sce.getServletContext()
                    .getAttribute(ServerContainer.class.getName());

            if (container != null) {
                WebSocketConfig.registerEndpoints(container);
            } else {
                System.err.println("❌ ServerContainer not found - WebSocket support may be missing");
            }

        } catch (Exception e) {
            System.err.println("❌ Error during initialization: " + e.getMessage());
            e.printStackTrace();
        }
    }

    @Override
    public void contextDestroyed(ServletContextEvent sce) {
        System.out.println("🛑 Application shutting down...");

        if (notificationListener != null) {
            notificationListener.stop();
        }
    }
}