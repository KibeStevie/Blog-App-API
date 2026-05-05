-- ==========================================
-- BLOG API: AUTHENTICATION MODULE (PostgreSQL)
-- ==========================================
-- Prerequisites: PostgreSQL 13+ (for gen_random_uuid())
-- Run this script to set up tables, triggers, views, and auth functions.
CREATE TABLE users (
  user_id SERIAL PRIMARY KEY,
  username VARCHAR(50) UNIQUE NOT NULL,
  email VARCHAR(100) UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  bio TEXT,
  profile_image TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE user_sessions (
  session_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id INT REFERENCES users(user_id) ON DELETE CASCADE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  expires_at TIMESTAMP
);

CREATE TABLE user_settings (
  user_id INT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
  theme VARCHAR(20) DEFAULT 'light',
  email_notifications BOOLEAN DEFAULT TRUE,
  push_notifications BOOLEAN DEFAULT TRUE,
  privacy_mode VARCHAR(20) DEFAULT 'public',
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE user_follows (
  follower_id INT REFERENCES users(user_id) ON DELETE CASCADE,
  following_id INT REFERENCES users(user_id) ON DELETE CASCADE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (follower_id, following_id),
  CHECK (follower_id != following_id) -- Prevent self-follow at DB level
);

CREATE TABLE notifications (
  notification_id SERIAL PRIMARY KEY,
  user_id INT REFERENCES users(user_id) ON DELETE CASCADE,
  actor_id INT REFERENCES users(user_id) ON DELETE CASCADE,
  type VARCHAR(50), -- 'follow', 'like', 'comment'
  reference_id INT,
  message TEXT,
  is_read BOOLEAN DEFAULT FALSE,
  pushed_via_ws BOOLEAN DEFAULT FALSE;
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ==========================================
-- 2. INDEXES (Performance Optimization)
-- ==========================================
CREATE INDEX idx_sessions_user_id ON user_sessions(user_id);
CREATE INDEX idx_sessions_expires ON user_sessions(expires_at);
CREATE INDEX idx_follows_follower ON user_follows(follower_id);
CREATE INDEX idx_follows_following ON user_follows(following_id);
CREATE INDEX idx_notifications_user_unread ON notifications(user_id, is_read) WHERE is_read = FALSE;
CREATE INDEX idx_notifications_unpushed ON notifications(user_id, pushed_via_ws) WHERE pushed_via_ws = FALSE;

-- ==========================================
-- 3. TRIGGERS (Automation)
-- ==========================================

-- 3.1 Auto-create user_settings on registration
CREATE OR REPLACE FUNCTION trg_fn_create_user_settings()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO user_settings (user_id) VALUES (NEW.user_id);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_after_user_insert
AFTER INSERT ON users
FOR EACH ROW
EXECUTE FUNCTION trg_fn_create_user_settings();

-- 3.2 Auto-update updated_at timestamp on settings change
CREATE OR REPLACE FUNCTION trg_fn_update_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_before_settings_update
BEFORE UPDATE ON user_settings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_update_timestamp();

-- 3.3 Auto-create notification when a user follows another
CREATE OR REPLACE FUNCTION trg_fn_notify_follow()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO notifications (user_id, type, reference_id, message)
  VALUES (NEW.following_id, 'follow', NEW.follower_id, 'Started following you');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_after_follow_insert
AFTER INSERT ON user_follows
FOR EACH ROW
EXECUTE FUNCTION trg_fn_notify_follow();

-- ==========================================
-- 4. VIEWS (Read Optimization)
-- ==========================================

-- 4.1 Quick lookup for authenticated user profiles
CREATE OR REPLACE VIEW v_user_auth_profile AS
SELECT 
  u.user_id, u.username, u.email, u.bio, u.profile_image, u.created_at,
  s.theme, s.email_notifications, s.push_notifications, s.privacy_mode, s.updated_at AS settings_updated_at,
  (SELECT COUNT(*) FROM user_follows WHERE following_id = u.user_id) AS followers_count,
  (SELECT COUNT(*) FROM user_follows WHERE follower_id = u.user_id) AS following_count
FROM users u
LEFT JOIN user_settings s ON u.user_id = s.user_id;

-- 4.2 Active sessions monitor (useful for admin/debug)
CREATE OR REPLACE VIEW v_active_sessions AS
SELECT 
  s.session_id, s.user_id, u.username, s.created_at, s.expires_at,
  CASE WHEN s.expires_at > CURRENT_TIMESTAMP THEN TRUE ELSE FALSE END AS is_active
FROM user_sessions s
JOIN users u ON s.user_id = u.user_id
WHERE s.expires_at > CURRENT_TIMESTAMP;

-- ==========================================
-- 5. FUNCTIONS (AuthServlet Business Logic)
-- ==========================================

-- 5.1 REGISTER USER
CREATE OR REPLACE FUNCTION fn_register_user(p_username VARCHAR, p_email VARCHAR, p_password_hash TEXT)
    RETURNS TABLE(success BOOLEAN, user_id INT, message TEXT, error TEXT) AS $$
    DECLARE v_new_user_id INT;
    BEGIN
        IF EXISTS (SELECT 1 FROM users u WHERE u.email = p_email OR u.username = p_username) THEN
            RETURN QUERY SELECT FALSE, NULL::INT, NULL::TEXT, 'Email or username already taken'::TEXT;
            RETURN;
        END IF;

        INSERT INTO users (username, email, password_hash)
        VALUES (p_username, p_email, p_password_hash)
        RETURNING users.user_id INTO v_new_user_id;

        RETURN QUERY SELECT TRUE, v_new_user_id, 'Registered successfully'::TEXT, NULL::TEXT;
        EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT FALSE, NULL::INT, NULL::TEXT, SQLERRM;
    END;
$$ LANGUAGE plpgsql;

-- 5.2 LOGIN USER

CREATE OR REPLACE FUNCTION fn_login_user(
  p_email VARCHAR,
  p_password_hash TEXT
)
RETURNS TABLE(success BOOLEAN, session_id UUID, user_id INT, message TEXT) AS $$

DECLARE
  v_user_id         INT;
  v_session_id      UUID;
BEGIN

  -- 1️⃣ Find user by credentials
  SELECT u.user_id INTO v_user_id 
  FROM users u
  WHERE u.email = p_email 
    AND u.password_hash = p_password_hash;

  -- 2️⃣ Handle invalid credentials
  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT FALSE, NULL::UUID, NULL::INT, 'Invalid credentials'::TEXT;
    RETURN;
  END IF;

  -- 3️⃣ Invalidate existing sessions for this user
  DELETE FROM user_sessions us 
  WHERE us.user_id = v_user_id;  -- ✅ Alias OK in DELETE

  -- 4️⃣ Create new session with 30-day expiry
  INSERT INTO user_sessions (user_id, expires_at)
  VALUES (v_user_id, CURRENT_TIMESTAMP + INTERVAL '30 days')
  RETURNING user_sessions.session_id INTO v_session_id;  -- ✅ No alias in INSERT RETURNING

  -- 5️⃣ Return standardized result
  RETURN QUERY SELECT 
    TRUE::BOOLEAN, 
    v_session_id,   
    v_user_id,      
    'Login successful'::TEXT;

END;
$$ LANGUAGE plpgsql;

-- 5.3 VALIDATE SESSION
CREATE OR REPLACE FUNCTION fn_validate_session(p_session_id UUID)
RETURNS TABLE(
  success BOOLEAN, user_id INT, username VARCHAR, email VARCHAR, bio TEXT,
  profile_image TEXT, theme VARCHAR, email_notifications BOOLEAN,
  push_notifications BOOLEAN, privacy_mode VARCHAR, error TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    TRUE, v.user_id, v.username, v.email, v.bio, v.profile_image,
    v.theme, v.email_notifications, v.push_notifications, v.privacy_mode, NULL::TEXT
  FROM v_user_auth_profile v
  JOIN user_sessions s ON s.user_id = v.user_id
  WHERE s.session_id = p_session_id AND s.expires_at > CURRENT_TIMESTAMP;

  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'Invalid or expired session'::TEXT;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 5.4 FOLLOW USER
CREATE OR REPLACE FUNCTION fn_follow_user(p_session_id UUID, p_following_id INT)
RETURNS TABLE(success BOOLEAN, message TEXT, error TEXT) AS $$
DECLARE
  v_follower_id INT;
BEGIN
  SELECT user_id INTO v_follower_id FROM user_sessions 
  WHERE session_id = p_session_id AND expires_at > CURRENT_TIMESTAMP;

  IF v_follower_id IS NULL THEN
    RETURN QUERY SELECT FALSE, NULL::TEXT, 'Unauthorized or expired session'::TEXT;
    RETURN;
  END IF;

  -- Triggers handle notifications & CHECK constraint handles self-follow
  BEGIN
    INSERT INTO user_follows (follower_id, following_id) 
    VALUES (v_follower_id, p_following_id);
    
    RETURN QUERY SELECT TRUE, 'Followed successfully', NULL::TEXT;
  EXCEPTION 
    WHEN check_violation THEN
      RETURN QUERY SELECT FALSE, NULL::TEXT, 'Cannot follow yourself'::TEXT;
    WHEN unique_violation THEN
      RETURN QUERY SELECT TRUE, 'Already following', NULL::TEXT;
  END;
END;
$$ LANGUAGE plpgsql;

-- 5.5 UNFOLLOW USER
CREATE OR REPLACE FUNCTION fn_unfollow_user(p_session_id UUID, p_following_id INT)
RETURNS TABLE(success BOOLEAN, message TEXT, error TEXT) AS $$
DECLARE
  v_follower_id INT;
BEGIN
  SELECT user_id INTO v_follower_id FROM user_sessions 
  WHERE session_id = p_session_id AND expires_at > CURRENT_TIMESTAMP;

  IF v_follower_id IS NULL THEN
    RETURN QUERY SELECT FALSE, NULL::TEXT, 'Unauthorized'::TEXT;
    RETURN;
  END IF;

  DELETE FROM user_follows WHERE follower_id = v_follower_id AND following_id = p_following_id;

  IF FOUND THEN
    RETURN QUERY SELECT TRUE, 'Unfollowed successfully', NULL::TEXT;
  ELSE
    RETURN QUERY SELECT FALSE, NULL::TEXT, 'Not following'::TEXT;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 5.6 GET FOLLOWERS
CREATE OR REPLACE FUNCTION fn_get_followers(
  p_session_id UUID  -- ✅ Changed from p_user_id INT to session UUID
)
RETURNS TABLE(
  user_id INT, 
  username VARCHAR, 
  profile_image TEXT, 
  created_at TIMESTAMP
) AS $$
DECLARE
  v_user_id INT;  -- ✅ Variable to store resolved user ID
BEGIN
  -- ✅ 1. Validate session and get user ID
  SELECT user_id INTO v_user_id
  FROM user_sessions
  WHERE session_id = p_session_id
    AND expires_at > CURRENT_TIMESTAMP;  -- ✅ Ensure session is not expired
  
  -- ✅ Raise error if session is invalid
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Unauthorized or expired session';
  END IF;
  
  -- ✅ 2. Return followers for the authenticated user
  RETURN QUERY
  SELECT 
    u.user_id, 
    u.username, 
    u.profile_image, 
    f.created_at
  FROM user_follows f
  JOIN users u ON f.follower_id = u.user_id
  WHERE f.following_id = v_user_id  -- ✅ Use resolved user ID
  ORDER BY f.created_at DESC;
END;
$$ LANGUAGE plpgsql;

-- 5.7 GET FOLLOWING
CREATE OR REPLACE FUNCTION fn_get_following(
  p_session_id UUID  -- ✅ Changed from p_user_id INT to session UUID
)
RETURNS TABLE(
  user_id INT, 
  username VARCHAR, 
  profile_image TEXT, 
  created_at TIMESTAMP
) AS $$
DECLARE
  v_user_id INT;  -- ✅ Variable to store resolved user ID
BEGIN
  -- ✅ 1. Validate session and get user ID
  SELECT user_id INTO v_user_id
  FROM user_sessions
  WHERE session_id = p_session_id
    AND expires_at > CURRENT_TIMESTAMP;  -- ✅ Ensure session is not expired
  
  -- ✅ Raise error if session is invalid
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Unauthorized or expired session';
  END IF;
  
  -- ✅ 2. Return following for the authenticated user
  RETURN QUERY
  SELECT 
    u.user_id, 
    u.username, 
    u.profile_image, 
    f.created_at
  FROM user_follows f
  JOIN users u ON f.following_id = u.user_id
  WHERE f.follower_id = v_user_id  -- ✅ Use resolved user ID
  ORDER BY f.created_at DESC;
END;
$$ LANGUAGE plpgsql;

-- 5.8 UPDATE SETTINGS
CREATE OR REPLACE FUNCTION fn_update_user_settings(
  p_session_id UUID,
  p_theme VARCHAR DEFAULT NULL,
  p_email_notifications BOOLEAN DEFAULT NULL,
  p_push_notifications BOOLEAN DEFAULT NULL,
  p_privacy_mode VARCHAR DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, message TEXT, error TEXT) AS $$
DECLARE
  v_user_id INT;
BEGIN
  SELECT user_id INTO v_user_id FROM user_sessions 
  WHERE session_id = p_session_id AND expires_at > CURRENT_TIMESTAMP;

  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT FALSE, NULL::TEXT, 'Unauthorized'::TEXT;
    RETURN;
  END IF;

  UPDATE user_settings
  SET 
    theme = COALESCE(p_theme, theme),
    email_notifications = COALESCE(p_email_notifications, email_notifications),
    push_notifications = COALESCE(p_push_notifications, push_notifications),
    privacy_mode = COALESCE(p_privacy_mode, privacy_mode)
    -- Trigger auto-updates updated_at
  WHERE user_id = v_user_id;

  RETURN QUERY SELECT TRUE, 'Settings updated successfully'::TEXT, NULL::TEXT;
END;
$$ LANGUAGE plpgsql;

-- ==========================================
-- 5.10 GET NOTIFICATIONS FOR USER
-- ==========================================
CREATE OR REPLACE FUNCTION fn_get_notifications(
  p_session_id UUID,
  p_page INT DEFAULT 1,
  p_limit INT DEFAULT 20,
  p_unread_only BOOLEAN DEFAULT FALSE
)
RETURNS TABLE(
  notification_id INT,
  user_id INT,              -- Recipient user_id
  type VARCHAR,
  reference_id INT,         -- Post ID
  message TEXT,
  is_read BOOLEAN,
  created_at TIMESTAMP,
  actor_username VARCHAR
) AS $$
DECLARE
  v_user_id INT;
BEGIN
  -- 1️⃣ Validate session
  SELECT user_sessions.user_id INTO v_user_id
  FROM user_sessions
  WHERE session_id = p_session_id AND expires_at > CURRENT_TIMESTAMP;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Unauthorized or expired session';
  END IF;

  RETURN QUERY
  SELECT
    n.notification_id,
    n.user_id,
    n.type,
    n.reference_id,          -- This is the post_id
    n.message,
    n.is_read,
    n.created_at,
    u.username AS actor_username
  FROM notifications n
  LEFT JOIN users u ON n.actor_id = u.user_id  -- Join on actor_id
  WHERE n.user_id = v_user_id
    AND (p_unread_only = FALSE OR n.is_read = FALSE)
  ORDER BY n.created_at DESC;

END;
$$ LANGUAGE plpgsql;

-- ==========================================
-- 5.11 UPDATE NOTIFICATION STATUS (READ/UNREAD)
-- ==========================================
CREATE OR REPLACE FUNCTION fn_update_notification_status(
  p_session_id UUID,
  p_notification_id INT,
  p_is_read BOOLEAN
)
RETURNS TABLE(success BOOLEAN, message TEXT, error TEXT) AS $$
DECLARE
  v_user_id INT;
BEGIN
  -- 1️⃣ Validate session
  SELECT user_id INTO v_user_id 
  FROM user_sessions 
  WHERE session_id = p_session_id AND expires_at > CURRENT_TIMESTAMP;

  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT FALSE, NULL::TEXT, 'Unauthorized or expired session'::TEXT;
    RETURN;
  END IF;

  -- 2️⃣ Update notification status (ensure user owns the notification)
  UPDATE notifications
  SET is_read = p_is_read
  WHERE notification_id = p_notification_id
    AND user_id = v_user_id;

  IF FOUND THEN
    RETURN QUERY SELECT TRUE, 'Notification status updated'::TEXT, NULL::TEXT;
  ELSE
    RETURN QUERY SELECT FALSE, NULL::TEXT, 'Notification not found or access denied'::TEXT;
  END IF;

END;
$$ LANGUAGE plpgsql;

-- ==========================================
-- 5.12 DELETE NOTIFICATION
-- ==========================================
CREATE OR REPLACE FUNCTION fn_delete_notification(
  p_session_id UUID,
  p_notification_id INT
)
RETURNS TABLE(success BOOLEAN, message TEXT, error TEXT) AS $$
DECLARE
  v_user_id INT;
BEGIN
  -- 1️⃣ Validate session
  SELECT user_id INTO v_user_id 
  FROM user_sessions 
  WHERE session_id = p_session_id AND expires_at > CURRENT_TIMESTAMP;

  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT FALSE, NULL::TEXT, 'Unauthorized or expired session'::TEXT;
    RETURN;
  END IF;

  -- 2️⃣ Delete notification (ensure user owns it)
  DELETE FROM notifications
  WHERE notification_id = p_notification_id
    AND user_id = v_user_id;

  IF FOUND THEN
    RETURN QUERY SELECT TRUE, 'Notification deleted'::TEXT, NULL::TEXT;
  ELSE
    RETURN QUERY SELECT FALSE, NULL::TEXT, 'Notification not found or access denied'::TEXT;
  END IF;

END;
$$ LANGUAGE plpgsql;

-- ==========================================
-- 5.13 MARK ALL NOTIFICATIONS AS READ (Bonus)
-- ==========================================
CREATE OR REPLACE FUNCTION fn_mark_all_notifications_read(
  p_session_id UUID
)
RETURNS TABLE(success BOOLEAN, message TEXT, error TEXT) AS $$
DECLARE
  v_user_id INT;
BEGIN
  -- 1️⃣ Validate session
  SELECT user_id INTO v_user_id 
  FROM user_sessions 
  WHERE session_id = p_session_id AND expires_at > CURRENT_TIMESTAMP;

  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT FALSE, NULL::TEXT, 'Unauthorized or expired session'::TEXT;
    RETURN;
  END IF;

  -- 2️⃣ Mark all unread notifications as read
  UPDATE notifications
  SET is_read = TRUE
  WHERE user_id = v_user_id
    AND is_read = FALSE;

  RETURN QUERY SELECT TRUE, 'All notifications marked as read'::TEXT, NULL::TEXT;

END;
$$ LANGUAGE plpgsql;

-- 5.9 LOGOUT USER
CREATE OR REPLACE FUNCTION fn_logout_user(p_session_id UUID)
RETURNS TABLE(success BOOLEAN, message TEXT) AS $$
BEGIN
  DELETE FROM user_sessions WHERE session_id = p_session_id;
  RETURN QUERY SELECT TRUE, 'Logged out successfully'::TEXT;
END;
$$ LANGUAGE plpgsql;