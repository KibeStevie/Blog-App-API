-- ==========================================
-- BLOG API: POSTS MODULE (PostgreSQL)
-- ==========================================
-- Prerequisites: PostgreSQL 13+ (for gen_random_uuid())
-- Run this AFTER the Auth module script.
-- Posts table
CREATE TABLE posts (
  post_id SERIAL PRIMARY KEY,
  user_id INT REFERENCES users(user_id) ON DELETE CASCADE NOT NULL,
  title TEXT NOT NULL,
  content TEXT NOT NULL,
  cover_image TEXT,
  is_published BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Post images (multiple images per post)
CREATE TABLE post_images (
  image_id SERIAL PRIMARY KEY,
  post_id INT REFERENCES posts(post_id) ON DELETE CASCADE NOT NULL,
  image_url TEXT NOT NULL,
  position INT DEFAULT 0,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Tags (reusable across posts)
CREATE TABLE tags (
  tag_id SERIAL PRIMARY KEY,
  name VARCHAR(50) UNIQUE NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Post-Tags junction table
CREATE TABLE post_tags (
  post_id INT REFERENCES posts(post_id) ON DELETE CASCADE,
  tag_id INT REFERENCES tags(tag_id) ON DELETE CASCADE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (post_id, tag_id)
);

-- Post likes
CREATE TABLE post_likes (
  user_id INT REFERENCES users(user_id) ON DELETE CASCADE,
  post_id INT REFERENCES posts(post_id) ON DELETE CASCADE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id, post_id)
);

-- Bookmarks (save posts for later)
CREATE TABLE bookmarks (
  user_id INT REFERENCES users(user_id) ON DELETE CASCADE,
  post_id INT REFERENCES posts(post_id) ON DELETE CASCADE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id, post_id)
);

-- Comments
CREATE TABLE comments (
  comment_id SERIAL PRIMARY KEY,
  post_id INT REFERENCES posts(post_id) ON DELETE CASCADE NOT NULL,
  user_id INT REFERENCES users(user_id) ON DELETE CASCADE NOT NULL,
  parent_comment_id INT REFERENCES comments(comment_id) ON DELETE CASCADE;
  content TEXT NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ==========================================
-- 2. INDEXES (Performance Optimization)
-- ==========================================
CREATE INDEX idx_posts_user_id ON posts(user_id);
CREATE INDEX idx_posts_published ON posts(is_published) WHERE is_published = TRUE;
CREATE INDEX idx_posts_created ON posts(created_at DESC);
CREATE INDEX idx_post_images_post_id ON post_images(post_id);
CREATE INDEX idx_tags_name ON tags(name);
CREATE INDEX idx_post_tags_post_id ON post_tags(post_id);
CREATE INDEX idx_post_tags_tag_id ON post_tags(tag_id);
CREATE INDEX idx_post_likes_post_id ON post_likes(post_id);
CREATE INDEX idx_bookmarks_user_id ON bookmarks(user_id);
CREATE INDEX idx_comments_post_id ON comments(post_id);
CREATE INDEX idx_comments_parent ON comments(parent_comment_id);
CREATE INDEX idx_comments_user_id ON comments(user_id);
CREATE INDEX idx_comments_created ON comments(created_at DESC);

-- ==========================================
-- 3. TRIGGERS (Automation)
-- ==========================================

-- 3.1 Auto-update updated_at on posts
CREATE OR REPLACE FUNCTION trg_fn_update_post_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_posts_updated
BEFORE UPDATE ON posts
FOR EACH ROW
EXECUTE FUNCTION trg_fn_update_post_timestamp();

-- 3.2 Auto-create notification when post is liked
CREATE OR REPLACE FUNCTION trg_fn_notify_like()
RETURNS TRIGGER AS $$
DECLARE
  v_post_owner INT;
BEGIN
  SELECT user_id INTO v_post_owner FROM posts WHERE post_id = NEW.post_id;
  
  -- Don't notify if user likes their own post
  IF v_post_owner IS NOT NULL AND v_post_owner != NEW.user_id THEN
    INSERT INTO notifications (user_id, type, reference_id, message)
    VALUES (
      v_post_owner,
      'like',
      NEW.post_id,
      'Liked your post'
    );
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_after_like_insert
AFTER INSERT ON post_likes
FOR EACH ROW
EXECUTE FUNCTION trg_fn_notify_like();

-- 3.3 Auto-create notification when post is commented
CREATE OR REPLACE FUNCTION trg_fn_notify_comment()
RETURNS TRIGGER AS $$
DECLARE
  v_post_owner INT;
  v_parent_author INT;
BEGIN
  SELECT user_id INTO v_post_owner FROM posts WHERE post_id = NEW.post_id;
  
  IF NEW.parent_comment_id IS NOT NULL THEN
    -- It's a reply: notify the author of the parent comment
    SELECT user_id INTO v_parent_author FROM comments WHERE comment_id = NEW.parent_comment_id;
    
    IF v_parent_author IS NOT NULL AND v_parent_author != NEW.user_id THEN
      INSERT INTO notifications (user_id, type, reference_id, message)
      VALUES (v_parent_author, 'comment_reply', NEW.comment_id, 'Replied to your comment');
    END IF;
  ELSE
    -- Top-level comment: notify post owner
    IF v_post_owner IS NOT NULL AND v_post_owner != NEW.user_id THEN
      INSERT INTO notifications (user_id, type, reference_id, message)
      VALUES (v_post_owner, 'comment', NEW.comment_id, 'Commented on your post');
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_after_comment_insert
AFTER INSERT ON comments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_notify_comment();

-- 3.4 Auto-create notification when post is bookmarked
CREATE OR REPLACE FUNCTION trg_fn_notify_bookmark()
RETURNS TRIGGER AS $$
DECLARE
  v_post_owner INT;
BEGIN
  SELECT user_id INTO v_post_owner FROM posts WHERE post_id = NEW.post_id;
  
  IF v_post_owner IS NOT NULL AND v_post_owner != NEW.user_id THEN
    INSERT INTO notifications (user_id, type, reference_id, message)
    VALUES (
      v_post_owner,
      'bookmark',
      NEW.post_id,
      'Bookmarked your post'
    );
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_after_bookmark_insert
AFTER INSERT ON bookmarks
FOR EACH ROW
EXECUTE FUNCTION trg_fn_notify_bookmark();

-- 3.5 Auto-delete notifications when post is deleted
CREATE OR REPLACE FUNCTION trg_fn_cleanup_post_notifications()
RETURNS TRIGGER AS $$
BEGIN
  DELETE FROM notifications WHERE reference_id = OLD.post_id AND type IN ('like', 'comment', 'bookmark');
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_after_post_delete
AFTER DELETE ON posts
FOR EACH ROW
EXECUTE FUNCTION trg_fn_cleanup_post_notifications();

-- ==========================================
-- 4. VIEWS (Read Optimization)
-- ==========================================

-- 4.1 Post details with counts (likes, comments, bookmarks)
CREATE OR REPLACE VIEW v_post_details AS
SELECT 
  p.post_id,
  p.user_id,
  u.username AS author_username,
  u.profile_image AS author_avatar,
  p.title,
  p.content,
  p.cover_image,
  p.is_published,
  p.created_at,
  p.updated_at,
  COALESCE(l.like_count, 0) AS like_count,
  COALESCE(c.comment_count, 0) AS comment_count,
  COALESCE(b.bookmark_count, 0) AS bookmark_count,
  COALESCE(img.images, '[]'::JSON) AS images,
  COALESCE(t.tags, '[]'::JSON) AS tags
FROM posts p
JOIN users u ON p.user_id = u.user_id
LEFT JOIN (
  SELECT post_id, COUNT(*) AS like_count FROM post_likes GROUP BY post_id
) l ON p.post_id = l.post_id
LEFT JOIN (
  SELECT post_id, COUNT(*) AS comment_count FROM comments GROUP BY post_id
) c ON p.post_id = c.post_id
LEFT JOIN (
  SELECT post_id, COUNT(*) AS bookmark_count FROM bookmarks GROUP BY post_id
) b ON p.post_id = b.post_id
LEFT JOIN (
  SELECT 
    post_id, 
    JSON_AGG(JSON_BUILD_OBJECT('image_id', image_id, 'image_url', image_url, 'position', position) ORDER BY position) AS images
  FROM post_images 
  GROUP BY post_id
) img ON p.post_id = img.post_id
LEFT JOIN (
  SELECT 
    pt.post_id,
    JSON_AGG(JSON_BUILD_OBJECT('tag_id', t.tag_id, 'name', t.name) ORDER BY t.name) AS tags
  FROM post_tags pt
  JOIN tags t ON pt.tag_id = t.tag_id
  GROUP BY pt.post_id
) t ON p.post_id = t.post_id;

-- 4.2 User's personalized feed (followed users + own posts)
CREATE OR REPLACE VIEW v_user_post_feed AS
SELECT 
  p.post_id,
  p.user_id,
  u.username AS author_username,
  u.profile_image AS author_avatar,
  p.title,
  p.content,
  p.cover_image,
  p.is_published,
  p.created_at,
  COALESCE(l.like_count, 0) AS like_count,
  COALESCE(c.comment_count, 0) AS comment_count
FROM posts p
JOIN users u ON p.user_id = u.user_id
LEFT JOIN (
  SELECT post_id, COUNT(*) AS like_count FROM post_likes GROUP BY post_id
) l ON p.post_id = l.post_id
LEFT JOIN (
  SELECT post_id, COUNT(*) AS comment_count FROM comments GROUP BY post_id
) c ON p.post_id = c.post_id
WHERE p.is_published = TRUE
  AND (
    p.user_id IN (SELECT following_id FROM user_follows WHERE follower_id = CURRENT_SETTING('app.current_user_id', TRUE)::INT)
    OR p.user_id = CURRENT_SETTING('app.current_user_id', TRUE)::INT
  );

-- 4.3 Tag cloud (popular tags)
CREATE OR REPLACE VIEW v_tag_cloud AS
SELECT 
  t.tag_id,
  t.name,
  COUNT(pt.post_id) AS post_count
FROM tags t
LEFT JOIN post_tags pt ON t.tag_id = pt.tag_id
LEFT JOIN posts p ON pt.post_id = p.post_id AND p.is_published = TRUE
GROUP BY t.tag_id, t.name
ORDER BY post_count DESC;

-- ==========================================
-- 5. FUNCTIONS (Posts Business Logic)
-- ==========================================

-- 5.1 CREATE POST (with optional tags and images)
CREATE OR REPLACE FUNCTION fn_create_post(
  p_user_id INT,
  p_title TEXT,
  p_content TEXT,
  p_cover_image TEXT DEFAULT NULL,
  p_is_published BOOLEAN DEFAULT TRUE,
  p_tag_names TEXT[] DEFAULT NULL,
  p_image_urls TEXT[] DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, created_post_id INT, message TEXT, error TEXT) AS $$
DECLARE
  v_post_id INT;
  v_tag_id INT;
  v_tag_name TEXT;
  v_image_url TEXT;
BEGIN
  -- Insert post
  INSERT INTO posts (user_id, title, content, cover_image, is_published)
  VALUES (p_user_id, p_title, p_content, p_cover_image, p_is_published)
  RETURNING post_id INTO v_post_id;

  -- Insert tags if provided
  IF p_tag_names IS NOT NULL AND array_length(p_tag_names, 1) > 0 THEN
    FOREACH v_tag_name IN ARRAY p_tag_names
    LOOP
      INSERT INTO tags (name) VALUES (v_tag_name)
      ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name
      RETURNING tag_id INTO v_tag_id;
      
      INSERT INTO post_tags (post_id, tag_id) VALUES (v_post_id, v_tag_id)
      ON CONFLICT (post_id, tag_id) DO NOTHING;
    END LOOP;
  END IF;

  -- Insert images if provided
  IF p_image_urls IS NOT NULL AND array_length(p_image_urls, 1) > 0 THEN
    FOR i IN 1..array_length(p_image_urls, 1)
    LOOP
      v_image_url := p_image_urls[i];
      INSERT INTO post_images (post_id, image_url, position)
      VALUES (v_post_id, v_image_url, i - 1);
    END LOOP;
  END IF;

  RETURN QUERY SELECT TRUE, v_post_id, 'Post created successfully'::TEXT, NULL::TEXT;
EXCEPTION WHEN OTHERS THEN
  RETURN QUERY SELECT FALSE, NULL::INT, NULL::TEXT, SQLERRM;
END;
$$ LANGUAGE plpgsql;

-- 5.2 GET POST BY ID (with full details)
CREATE OR REPLACE FUNCTION fn_get_post(p_post_id INT, p_requester_user_id INT DEFAULT NULL)
RETURNS TABLE(
  success BOOLEAN,
  post_id INT, user_id INT, author_username VARCHAR, author_avatar TEXT,
  title TEXT, content TEXT, cover_image TEXT, is_published BOOLEAN,
  created_at TIMESTAMP, updated_at TIMESTAMP,
  like_count BIGINT, comment_count BIGINT, bookmark_count BIGINT,
  images JSON, tags JSON,
  is_liked BOOLEAN, is_bookmarked BOOLEAN,
  error TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    TRUE,
    v.post_id, v.user_id, v.author_username, v.author_avatar,
    v.title, v.content, v.cover_image, v.is_published,
    v.created_at, v.updated_at,
    v.like_count, v.comment_count, v.bookmark_count,
    v.images, v.tags,
    EXISTS (SELECT 1 FROM post_likes pl WHERE pl.user_id = p_requester_user_id AND pl.post_id = v.post_id) AS is_liked,
    EXISTS (SELECT 1 FROM bookmarks b WHERE b.user_id = p_requester_user_id AND b.post_id = v.post_id) AS is_bookmarked,
    NULL::TEXT
  FROM v_post_details v
  WHERE v.post_id = p_post_id;

  IF NOT FOUND THEN
    RETURN QUERY SELECT
      FALSE,
      NULL::INT, NULL::INT, NULL::VARCHAR, NULL::TEXT,
      NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::BOOLEAN,
      NULL::TIMESTAMP, NULL::TIMESTAMP,
      NULL::BIGINT, NULL::BIGINT, NULL::BIGINT,
      NULL::JSON, NULL::JSON,
      NULL::BOOLEAN, NULL::BOOLEAN,
      'Post not found'::TEXT;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 5.3 UPDATE POST (partial update, only owner can update)
CREATE OR REPLACE FUNCTION fn_update_post(
  p_session_id UUID,
  p_post_id INT,
  p_title TEXT DEFAULT NULL,
  p_content TEXT DEFAULT NULL,
  p_cover_image TEXT DEFAULT NULL,
  p_is_published BOOLEAN DEFAULT NULL,
  p_tag_names TEXT[] DEFAULT NULL,  -- Replace all tags with this array
  p_image_urls TEXT[] DEFAULT NULL  -- Replace all images with this array
)
RETURNS TABLE(success BOOLEAN, message TEXT, error TEXT) AS $$
DECLARE
  v_user_id INT;
  v_post_owner INT;
  v_tag_id INT;
  v_tag_name TEXT;
BEGIN
  -- Validate session and get user_id
  SELECT user_id INTO v_user_id FROM user_sessions 
  WHERE session_id = p_session_id AND expires_at > CURRENT_TIMESTAMP;

  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT FALSE, NULL::TEXT, 'Unauthorized'::TEXT;
    RETURN;
  END IF;

  -- Verify post ownership
  SELECT user_id INTO v_post_owner FROM posts WHERE post_id = p_post_id;
  
  IF v_post_owner IS NULL THEN
    RETURN QUERY SELECT FALSE, NULL::TEXT, 'Post not found'::TEXT;
    RETURN;
  END IF;
  
  IF v_post_owner != v_user_id THEN
    RETURN QUERY SELECT FALSE, NULL::TEXT, 'Not authorized to edit this post'::TEXT;
    RETURN;
  END IF;

  -- Update post fields (only non-NULL values)
  UPDATE posts
  SET 
    title = COALESCE(p_title, title),
    content = COALESCE(p_content, content),
    cover_image = COALESCE(p_cover_image, cover_image),
    is_published = COALESCE(p_is_published, is_published)
    -- updated_at handled by trigger
  WHERE post_id = p_post_id;

  -- Replace tags if provided
  IF p_tag_names IS NOT NULL THEN
    DELETE FROM post_tags WHERE post_id = p_post_id;
    
    FOREACH v_tag_name IN ARRAY p_tag_names
    LOOP
      INSERT INTO tags (name) VALUES (v_tag_name)
      ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name
      RETURNING tag_id INTO v_tag_id;
      
      INSERT INTO post_tags (post_id, tag_id) VALUES (p_post_id, v_tag_id)
      ON CONFLICT (post_id, tag_id) DO NOTHING;
    END LOOP;
  END IF;

  -- Replace images if provided
  IF p_image_urls IS NOT NULL THEN
    DELETE FROM post_images WHERE post_id = p_post_id;
    
    FOR i IN 1..array_length(p_image_urls, 1)
    LOOP
      INSERT INTO post_images (post_id, image_url, position)
      VALUES (p_post_id, p_image_urls[i], i - 1);
    END LOOP;
  END IF;

  RETURN QUERY SELECT TRUE, 'Post updated successfully'::TEXT, NULL::TEXT;
EXCEPTION WHEN OTHERS THEN
  RETURN QUERY SELECT FALSE, NULL::TEXT, SQLERRM;
END;
$$ LANGUAGE plpgsql;

-- 5.4 DELETE POST (only owner can delete)
CREATE OR REPLACE FUNCTION fn_delete_post(p_session_id UUID, p_post_id INT)
RETURNS TABLE(success BOOLEAN, message TEXT, error TEXT) AS $$
DECLARE
  v_user_id INT;
  v_post_owner INT;
BEGIN
  SELECT user_id INTO v_user_id FROM user_sessions 
  WHERE session_id = p_session_id AND expires_at > CURRENT_TIMESTAMP;

  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT FALSE, NULL::TEXT, 'Unauthorized'::TEXT;
    RETURN;
  END IF;

  SELECT user_id INTO v_post_owner FROM posts WHERE post_id = p_post_id;
  
  IF v_post_owner IS NULL THEN
    RETURN QUERY SELECT FALSE, NULL::TEXT, 'Post not found'::TEXT;
    RETURN;
  END IF;
  
  IF v_post_owner != v_user_id THEN
    RETURN QUERY SELECT FALSE, NULL::TEXT, 'Not authorized to delete this post'::TEXT;
    RETURN;
  END IF;

  -- Trigger trg_after_post_delete will cleanup notifications
  DELETE FROM posts WHERE post_id = p_post_id;

  RETURN QUERY SELECT TRUE, 'Post deleted successfully'::TEXT, NULL::TEXT;
END;
$$ LANGUAGE plpgsql;

-- 5.5 GET USER'S POSTS (with pagination)
CREATE OR REPLACE FUNCTION fn_get_user_posts(
  p_user_id INT,
  p_page INT DEFAULT 1,
  p_limit INT DEFAULT 20,
  p_include_unpublished BOOLEAN DEFAULT FALSE
)
RETURNS TABLE(
  post_id INT, title TEXT, cover_image TEXT, is_published BOOLEAN,
  created_at TIMESTAMP, like_count BIGINT, comment_count BIGINT
) AS $$
DECLARE
  v_offset INT;
BEGIN
  v_offset := (p_page - 1) * p_limit;

  RETURN QUERY
  SELECT 
    p.post_id, p.title, p.cover_image, p.is_published, p.created_at,
    COALESCE(l.like_count, 0), COALESCE(c.comment_count, 0)
  FROM posts p
  -- ✅ Fully qualified subqueries eliminate PL/pgSQL variable ambiguity
  LEFT JOIN (
    SELECT pl.post_id, COUNT(*) AS like_count 
    FROM post_likes pl 
    GROUP BY pl.post_id
  ) l ON p.post_id = l.post_id
  LEFT JOIN (
    SELECT cm.post_id, COUNT(*) AS comment_count 
    FROM comments cm 
    GROUP BY cm.post_id
  ) c ON p.post_id = c.post_id
  WHERE p.user_id = p_user_id
    AND (p_include_unpublished = TRUE OR p.is_published = TRUE)
  ORDER BY p.created_at DESC
  LIMIT p_limit OFFSET v_offset;
END;
$$ LANGUAGE plpgsql;

-- 5.6 GET PUBLIC FEED (published posts, paginated)
CREATE OR REPLACE FUNCTION fn_get_public_feed(
  p_page INT DEFAULT 1,
  p_limit INT DEFAULT 20,
  p_tag_name VARCHAR DEFAULT NULL
)
RETURNS TABLE(
  post_id INT, user_id INT, author_username VARCHAR, author_avatar TEXT,
  title TEXT, content TEXT, cover_image TEXT,
  created_at TIMESTAMP, like_count BIGINT, comment_count BIGINT,
  tags JSON
) AS $$
DECLARE
  v_offset INT;
BEGIN
  v_offset := (p_page - 1) * p_limit;

  RETURN QUERY
  SELECT 
    p.post_id, p.user_id, u.username, u.profile_image,
    p.title, p.content, p.cover_image,
    p.created_at,
    COALESCE(l.like_count, 0), 
    COALESCE(c.comment_count, 0),
    COALESCE(t.tags, '[]'::JSON)
  FROM posts p
  JOIN users u ON p.user_id = u.user_id
  LEFT JOIN (
    SELECT pl.post_id, COUNT(*) AS like_count 
    FROM post_likes pl 
    GROUP BY pl.post_id
  ) l ON p.post_id = l.post_id
  LEFT JOIN (
    SELECT cm.post_id, COUNT(*) AS comment_count 
    FROM comments cm 
    GROUP BY cm.post_id
  ) c ON p.post_id = c.post_id
  LEFT JOIN (
    SELECT pt.post_id, JSON_AGG(JSON_BUILD_OBJECT('tag_id', tg.tag_id, 'name', tg.name) ORDER BY tg.name) AS tags
    FROM post_tags pt
    JOIN tags tg ON pt.tag_id = tg.tag_id
    GROUP BY pt.post_id
  ) t ON p.post_id = t.post_id
  WHERE p.is_published = TRUE
    AND (p_tag_name IS NULL OR EXISTS (
      SELECT 1 
      FROM post_tags pt_f 
      JOIN tags tg_f ON pt_f.tag_id = tg_f.tag_id
      WHERE pt_f.post_id = p.post_id AND tg_f.name = p_tag_name
    ))
  ORDER BY p.created_at DESC
  LIMIT p_limit OFFSET v_offset;
END;
$$ LANGUAGE plpgsql;

-- 5.7 LIKE/UNLIKE POST
CREATE OR REPLACE FUNCTION fn_toggle_like(p_session_id UUID, p_post_id INT)
RETURNS TABLE(success BOOLEAN, action TEXT, message TEXT, error TEXT) AS $$
DECLARE
  v_user_id INT;
  v_exists BOOLEAN;
  v_post_valid BOOLEAN;
BEGIN
  -- 1. Validate session
  SELECT user_id INTO v_user_id FROM user_sessions 
  WHERE session_id = p_session_id AND expires_at > CURRENT_TIMESTAMP;

  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT FALSE, NULL::TEXT, NULL::TEXT, 'Unauthorized'::TEXT;
    RETURN;
  END IF;

  -- 2. ✅ FIX: Verify post exists and is published
  SELECT EXISTS (
    SELECT 1 FROM posts WHERE post_id = p_post_id AND is_published = TRUE
  ) INTO v_post_valid;

  IF NOT v_post_valid THEN
    RETURN QUERY SELECT FALSE, NULL::TEXT, NULL::TEXT, 'Post not found or not published'::TEXT;
    RETURN;
  END IF;

  -- 3. Check if like already exists
  SELECT EXISTS (
    SELECT 1 FROM post_likes WHERE user_id = v_user_id AND post_id = p_post_id
  ) INTO v_exists;

  IF v_exists THEN
    -- Unlike
    DELETE FROM post_likes WHERE user_id = v_user_id AND post_id = p_post_id;
    RETURN QUERY SELECT TRUE, 'unliked'::TEXT, 'Post unliked'::TEXT, NULL::TEXT;
  ELSE
    -- Like (trigger will create notification)
    INSERT INTO post_likes (user_id, post_id) VALUES (v_user_id, p_post_id);
    RETURN QUERY SELECT TRUE, 'liked'::TEXT, 'Post liked'::TEXT, NULL::TEXT;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 5.8 BOOKMARK/UNBOOKMARK POST
CREATE OR REPLACE FUNCTION fn_toggle_bookmark(p_session_id UUID, p_post_id INT)
RETURNS TABLE(success BOOLEAN, action TEXT, message TEXT, error TEXT) AS $$
DECLARE
  v_user_id INT;
  v_exists BOOLEAN;
BEGIN
  -- 1. Validate session
  SELECT user_id INTO v_user_id FROM user_sessions 
  WHERE session_id = p_session_id AND expires_at > CURRENT_TIMESTAMP;

  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT FALSE, NULL::TEXT, NULL::TEXT, 'Unauthorized'::TEXT;
    RETURN;
  END IF;

  -- 🔹 2. VERIFY POST EXISTS (Prevents FK violation)
  IF NOT EXISTS (SELECT 1 FROM posts WHERE post_id = p_post_id) THEN
    RETURN QUERY SELECT FALSE, NULL::TEXT, NULL::TEXT, 'Post not found'::TEXT;
    RETURN;
  END IF;

  -- 3. Check if bookmark already exists
  SELECT EXISTS (
    SELECT 1 FROM bookmarks WHERE user_id = v_user_id AND post_id = p_post_id
  ) INTO v_exists;

  IF v_exists THEN
    DELETE FROM bookmarks WHERE user_id = v_user_id AND post_id = p_post_id;
    RETURN QUERY SELECT TRUE, 'unbookmarked'::TEXT, 'Post unbookmarked'::TEXT, NULL::TEXT;
  ELSE
    INSERT INTO bookmarks (user_id, post_id) VALUES (v_user_id, p_post_id);
    RETURN QUERY SELECT TRUE, 'bookmarked'::TEXT, 'Post bookmarked'::TEXT, NULL::TEXT;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 5.9 CREATE COMMENT
CREATE OR REPLACE FUNCTION fn_create_comment(
  p_session_id UUID,
  p_post_id INT,
  p_content TEXT,
  p_parent_comment_id INT DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, comment_id INT, message TEXT, error TEXT) AS $$
#variable_conflict use_column
DECLARE
  v_user_id INT;
  v_comment_id INT;
BEGIN
  SELECT user_id INTO v_user_id FROM user_sessions 
  WHERE session_id = p_session_id AND expires_at > CURRENT_TIMESTAMP;

  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT FALSE, NULL::INT, NULL::TEXT, 'Unauthorized'::TEXT;
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM posts WHERE post_id = p_post_id AND is_published = TRUE) THEN
    RETURN QUERY SELECT FALSE, NULL::INT, NULL::TEXT, 'Post not found'::TEXT;
    RETURN;
  END IF;

  -- If replying, verify parent comment exists and belongs to the same post
  IF p_parent_comment_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM comments c
      WHERE c.comment_id = p_parent_comment_id AND c.post_id = p_post_id
    ) THEN
      RETURN QUERY SELECT FALSE, NULL::INT, NULL::TEXT, 'Parent comment not found in this post'::TEXT;
      RETURN;
    END IF;
  END IF;

  INSERT INTO comments (post_id, user_id, content, parent_comment_id)
  VALUES (p_post_id, v_user_id, p_content, p_parent_comment_id)
  RETURNING comment_id INTO v_comment_id;

  RETURN QUERY SELECT TRUE, v_comment_id, 'Comment posted'::TEXT, NULL::TEXT;
EXCEPTION WHEN OTHERS THEN
  RETURN QUERY SELECT FALSE, NULL::INT, NULL::TEXT, SQLERRM;
END;
$$ LANGUAGE plpgsql;

-- 5.10 GET COMMENTS FOR POST (with pagination)
CREATE OR REPLACE FUNCTION fn_get_comments(
  p_post_id INT,
  p_page INT DEFAULT 1,
  p_limit INT DEFAULT 20
)
RETURNS TABLE(
  comment_id INT, user_id INT, username VARCHAR, profile_image TEXT,
  content TEXT, created_at TIMESTAMP, parent_comment_id INT, reply_count BIGINT
) AS $$
#variable_conflict use_column
DECLARE
  v_offset INT;
BEGIN
  v_offset := (p_page - 1) * p_limit;

  RETURN QUERY
  SELECT 
    c.comment_id, c.user_id, u.username, u.profile_image,
    c.content, c.created_at, c.parent_comment_id,
    -- ✅ Aliased subquery eliminates ambiguity
    (SELECT COUNT(*) FROM comments c2 WHERE c2.parent_comment_id = c.comment_id) AS reply_count
  FROM comments c
  JOIN users u ON c.user_id = u.user_id
  WHERE c.post_id = p_post_id
  ORDER BY c.created_at ASC
  LIMIT p_limit OFFSET v_offset;
END;
$$ LANGUAGE plpgsql;

-- 5.11 DELETE COMMENT (only comment owner or post owner can delete)
CREATE OR REPLACE FUNCTION fn_delete_comment(p_session_id UUID, p_comment_id INT)
RETURNS TABLE(success BOOLEAN, message TEXT, error TEXT) AS $$
DECLARE
  v_user_id INT;
  v_comment_user INT;
  v_post_owner INT;
BEGIN
  SELECT user_id INTO v_user_id FROM user_sessions 
  WHERE session_id = p_session_id AND expires_at > CURRENT_TIMESTAMP;

  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT FALSE, NULL::TEXT, 'Unauthorized'::TEXT;
    RETURN;
  END IF;

  SELECT c.user_id, p.user_id INTO v_comment_user, v_post_owner
  FROM comments c
  JOIN posts p ON c.post_id = p.post_id
  WHERE c.comment_id = p_comment_id;

  IF v_comment_user IS NULL THEN
    RETURN QUERY SELECT FALSE, NULL::TEXT, 'Comment not found'::TEXT;
    RETURN;
  END IF;

  IF v_comment_user != v_user_id AND v_post_owner != v_user_id THEN
    RETURN QUERY SELECT FALSE, NULL::TEXT, 'Not authorized to delete this comment'::TEXT;
    RETURN;
  END IF;

  DELETE FROM comments WHERE comment_id = p_comment_id;

  RETURN QUERY SELECT TRUE, 'Comment deleted'::TEXT, NULL::TEXT;
END;
$$ LANGUAGE plpgsql;

-- 5.12 GET TAGS (with optional search)
CREATE OR REPLACE FUNCTION fn_get_tags(p_search VARCHAR DEFAULT NULL)
RETURNS TABLE(tag_id INT, name VARCHAR, post_count BIGINT) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    t.tag_id, t.name, COUNT(pt.post_id) AS post_count
  FROM tags t
  LEFT JOIN post_tags pt ON t.tag_id = pt.tag_id
  LEFT JOIN posts p ON pt.post_id = p.post_id AND p.is_published = TRUE
  WHERE p_search IS NULL OR t.name ILIKE '%' || p_search || '%'
  GROUP BY t.tag_id, t.name
  ORDER BY post_count DESC, t.name ASC;
END;
$$ LANGUAGE plpgsql;

-- 5.13 GET USER'S BOOKMARKED POSTS
CREATE OR REPLACE FUNCTION fn_get_bookmarked_posts(
  p_session_id UUID,
  p_page INT DEFAULT 1,
  p_limit INT DEFAULT 20
)
RETURNS TABLE(
  post_id INT, title TEXT, cover_image TEXT,
  created_at TIMESTAMP, like_count BIGINT, comment_count BIGINT
) AS $$
DECLARE
  v_user_id INT;
  v_offset INT;
BEGIN
  SELECT user_id INTO v_user_id FROM user_sessions 
  WHERE session_id = p_session_id AND expires_at > CURRENT_TIMESTAMP;

  IF v_user_id IS NULL THEN
    RETURN;
  END IF;

  v_offset := (p_page - 1) * p_limit;

  RETURN QUERY
  SELECT 
    p.post_id, p.title, p.cover_image, p.created_at,
    COALESCE(l.like_count, 0), COALESCE(c.comment_count, 0)
  FROM bookmarks b
  JOIN posts p ON b.post_id = p.post_id
  -- ✅ Fully qualified subqueries eliminate PL/pgSQL variable ambiguity
  LEFT JOIN (
    SELECT pl.post_id, COUNT(*) AS like_count 
    FROM post_likes pl 
    GROUP BY pl.post_id
  ) l ON p.post_id = l.post_id
  LEFT JOIN (
    SELECT cm.post_id, COUNT(*) AS comment_count 
    FROM comments cm 
    GROUP BY cm.post_id
  ) c ON p.post_id = c.post_id
  WHERE b.user_id = v_user_id AND p.is_published = TRUE
  ORDER BY b.created_at DESC
  LIMIT p_limit OFFSET v_offset;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_get_posts_by_tag(
  p_tag_name VARCHAR,
  p_page INT DEFAULT 1,
  p_limit INT DEFAULT 20
)
RETURNS TABLE(
  post_id INT, user_id INT, author_username VARCHAR, author_avatar TEXT,
  title TEXT, content TEXT, cover_image TEXT,
  created_at TIMESTAMP, like_count BIGINT, comment_count BIGINT,
  tags JSON
) AS $$
DECLARE
  v_offset INT;
BEGIN
  v_offset := (p_page - 1) * p_limit;

  RETURN QUERY
  SELECT 
    p.post_id, p.user_id, u.username, u.profile_image,
    p.title, p.content, p.cover_image,
    p.created_at,
    COALESCE(l.like_count, 0), 
    COALESCE(c.comment_count, 0),
    COALESCE(t.tags, '[]'::JSON)
  FROM posts p
  JOIN users u ON p.user_id = u.user_id
  -- Filter posts by the specific tag
  JOIN post_tags pt ON p.post_id = pt.post_id
  JOIN tags tg ON pt.tag_id = tg.tag_id AND tg.name = p_tag_name
  -- Pre-aggregated subqueries (no outer GROUP BY needed)
  LEFT JOIN (
    SELECT pl.post_id, COUNT(*) AS like_count 
    FROM post_likes pl 
    GROUP BY pl.post_id
  ) l ON p.post_id = l.post_id
  LEFT JOIN (
    SELECT cm.post_id, COUNT(*) AS comment_count 
    FROM comments cm 
    GROUP BY cm.post_id
  ) c ON p.post_id = c.post_id
  LEFT JOIN (
    SELECT pt_agg.post_id, JSON_AGG(JSON_BUILD_OBJECT('tag_id', t_agg.tag_id, 'name', t_agg.name) ORDER BY t_agg.name) AS tags
    FROM post_tags pt_agg
    JOIN tags t_agg ON pt_agg.tag_id = t_agg.tag_id
    GROUP BY pt_agg.post_id
  ) t ON p.post_id = t.post_id
  WHERE p.is_published = TRUE
  -- ✅ GROUP BY REMOVED: Subqueries already aggregate, so no duplication occurs
  ORDER BY p.created_at DESC
  LIMIT p_limit OFFSET v_offset;
END;
$$ LANGUAGE plpgsql;