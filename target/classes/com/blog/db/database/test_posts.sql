-- ==========================================
-- BLOG API: POSTS MODULE TEST SCRIPT
-- ==========================================
-- Run this AFTER deploying the Posts Module SQL.
-- Assumes Auth module is already deployed with users(user_id 1, 2).
-- Use \i posts_test.sql in psql, or paste in pgAdmin Query Tool.

BEGIN;

\echo '🔧 SETUP: Creating test users & sessions (if not exists)'
INSERT INTO users (username, email, password_hash) VALUES
  ('alice_test', 'alice@test.com', 'hash_alice'),
  ('bob_test', 'bob@test.com', 'hash_bob')
ON CONFLICT (username) DO NOTHING;

-- Create active sessions for testing authenticated functions
-- In psql: \gset alice_session
-- In pgAdmin: Copy the UUID output manually
SELECT session_id FROM user_sessions WHERE user_id = 1 AND expires_at > CURRENT_TIMESTAMP LIMIT 1
UNION ALL
SELECT gen_random_uuid()::UUID
WHERE NOT EXISTS (SELECT 1 FROM user_sessions WHERE user_id = 1 AND expires_at > CURRENT_TIMESTAMP)
LIMIT 1;
-- 💡 Replace 'YOUR_ALICE_SESSION_UUID' in subsequent calls with the actual UUID above.

\echo ''
\echo '========================================='
\echo 'TEST 1: CREATE POST (fn_create_post)'
\echo '========================================='
SELECT * FROM fn_create_post(
  1, -- user_id (alice)
  'My First Blog Post',
  'This is the content of my first post.',
  'https://example.com/cover.jpg',
  TRUE,
  ARRAY['tech', 'postgresql', 'blog'],
  ARRAY['https://img1.com/a.jpg', 'https://img2.com/b.jpg']
);
-- ✅ Expected: success=t, post_id=1, message='Post created successfully'

\echo 'Verify: Tags & Images inserted'
SELECT tag_id, name FROM tags WHERE name IN ('tech', 'postgresql', 'blog');
SELECT image_url, position FROM post_images WHERE post_id = 1 ORDER BY position;

\echo ''
\echo '========================================='
\echo 'TEST 2: GET POST (fn_get_post)'
\echo '========================================='
SELECT * FROM fn_get_post(1, 1); -- post_id=1, requester=1
-- ✅ Expected: success=t, like_count=0, comment_count=0, bookmark_count=0
-- ✅ images/tags JSON arrays populated correctly

\echo ''
\echo '========================================='
\echo 'TEST 3: UPDATE POST & TRIGGER TEST (fn_update_post)'
\echo '========================================='
-- Capture original updated_at for comparison
SELECT updated_at AS original_updated_at FROM posts WHERE post_id = 1 \gset orig_

SELECT * FROM fn_update_post(
  'YOUR_ALICE_SESSION_UUID'::UUID, -- ⚠️ REPLACE WITH ACTUAL UUID
  1,
  'Updated Title',
  'Updated content with better SEO.',
  'https://example.com/new_cover.jpg',
  TRUE,
  ARRAY['tech', 'ai'], -- Replaces old tags
  ARRAY['https://img3.com/c.jpg'] -- Replaces old images
);
-- ✅ Expected: success=t, message='Post updated successfully'

\echo 'Verify: updated_at trigger fired'
SELECT updated_at > :'orig_updated_at' AS timestamp_updated FROM posts WHERE post_id = 1;
-- ✅ Expected: t

\echo 'Verify: Tags & Images replaced'
SELECT name FROM post_tags pt JOIN tags t ON pt.tag_id = t.tag_id WHERE pt.post_id = 1 ORDER BY name;
-- ✅ Expected: ai, tech
SELECT image_url FROM post_images WHERE post_id = 1 ORDER BY position;
-- ✅ Expected: https://img3.com/c.jpg

\echo ''
\echo '========================================='
\echo 'TEST 4: LIKE/BOOKMARK & NOTIFICATION TRIGGERS'
\echo '========================================='
-- Bob likes Alice's post
INSERT INTO user_sessions (user_id, expires_at) VALUES (2, CURRENT_TIMESTAMP + INTERVAL '1 day') RETURNING session_id \gset bob_session

SELECT * FROM fn_toggle_like(:'bob_session'::UUID, 1);
-- ✅ Expected: success=t, action='liked', message='Post liked'

\echo 'Verify: Like count increased'
SELECT like_count FROM v_post_details WHERE post_id = 1;
-- ✅ Expected: 1

\echo 'Verify: Notification trigger fired (trg_after_like_insert)'
SELECT user_id, type, message, is_read FROM notifications WHERE type = 'like' AND user_id = 1;
-- ✅ Expected: 1 row: type='like', message='Liked your post'

-- Bookmark
SELECT * FROM fn_toggle_bookmark(:'bob_session'::UUID, 1);
-- ✅ Expected: success=t, action='bookmarked', message='Post bookmarked'

\echo 'Verify: Bookmark trigger fired & count'
SELECT bookmark_count FROM v_post_details WHERE post_id = 1;
-- ✅ Expected: 1

-- Toggle off (Unlike)
SELECT * FROM fn_toggle_like(:'bob_session'::UUID, 1);
-- ✅ Expected: action='unliked'

\echo ''
\echo '========================================='
\echo 'TEST 5: COMMENTS & TRIGGERS'
\echo '========================================='
SELECT * FROM fn_create_comment(:'bob_session'::UUID, 1, 'Great post, Alice! Learned a lot.');
-- ✅ Expected: success=t, comment_id=1, message='Comment posted'

\echo 'Verify: Comment trigger fired (trg_after_comment_insert)'
SELECT user_id, type, message FROM notifications WHERE type = 'comment' AND user_id = 1;
-- ✅ Expected: 1 row

-- Get comments
SELECT * FROM fn_get_comments(1, 1, 10);
-- ✅ Expected: 1 row with bob's comment

\echo 'Verify: Comment count'
SELECT comment_count FROM v_post_details WHERE post_id = 1;
-- ✅ Expected: 1

-- Delete comment (Bob deleting his own)
SELECT * FROM fn_delete_comment(:'bob_session'::UUID, 1);
-- ✅ Expected: success=t

\echo ''
\echo '========================================='
\echo 'TEST 6: FEEDS & PAGINATION'
\echo '========================================='
-- Create 2 more posts for pagination testing
SELECT * FROM fn_create_post(1, 'Post 2', 'Content 2', NULL, TRUE, ARRAY['dev'], NULL);
SELECT * FROM fn_create_post(1, 'Post 3', 'Content 3', NULL, TRUE, ARRAY['blog'], NULL);

-- Public feed
SELECT * FROM fn_get_public_feed(1, 2); -- page 1, limit 2
-- ✅ Expected: 2 posts (Post 3, Post 2 or 1)

-- Feed with tag filter
SELECT * FROM fn_get_public_feed(1, 5, 'dev');
-- ✅ Expected: Only posts tagged 'dev'

-- User's posts
SELECT * FROM fn_get_user_posts(1, 1, 10, FALSE);
-- ✅ Expected: All 3 posts (published only)

\echo ''
\echo '========================================='
\echo 'TEST 7: DELETE POST & CLEANUP TRIGGER'
\echo '========================================='
-- Like Post 2 to generate notification
SELECT * FROM fn_toggle_like(:'bob_session'::UUID, 2);

SELECT * FROM fn_delete_post(:'bob_session'::UUID, 2);
-- ❌ Expected: success=f, error='Not authorized to delete this post' (Bob ≠ Alice)

SELECT * FROM fn_delete_post(:'YOUR_ALICE_SESSION_UUID'::UUID, 2);
-- ✅ Expected: success=t, message='Post deleted successfully'

\echo 'Verify: Cascade deletes (images, tags, likes gone)'
SELECT COUNT(*) AS remaining_images FROM post_images WHERE post_id = 2; -- 0
SELECT COUNT(*) AS remaining_likes FROM post_likes WHERE post_id = 2; -- 0

\echo 'Verify: Cleanup trigger fired (trg_after_post_delete)'
SELECT COUNT(*) AS remaining_like_notifications FROM notifications 
WHERE type = 'like' AND reference_id = 2;
-- ✅ Expected: 0 (notification removed when post deleted)

\echo ''
\echo '========================================='
\echo 'TEST 8: TAGS & BOOKMARKS'
\echo '========================================='
-- Get tags
SELECT * FROM fn_get_tags('tech');
-- ✅ Expected: tech tag with post_count=1 (Post 1)

-- Get Alice's bookmarks
SELECT * FROM fn_get_bookmarked_posts(:'YOUR_ALICE_SESSION_UUID'::UUID, 1, 10);
-- ✅ Expected: Post 1 (if bookmarked), or empty

\echo ''
\echo '========================================='
\echo 'TEST 9: VIEWS'
\echo '========================================='
\echo 'v_post_details for Post 1:'
SELECT post_id, title, like_count, comment_count, tags FROM v_post_details WHERE post_id = 1;

\echo 'v_tag_cloud (popular tags):'
SELECT * FROM v_tag_cloud LIMIT 5;

\echo ''
\echo '========================================='
\echo '✅ ALL TESTS COMPLETED'
\echo '========================================='
\echo '💡 To keep test data: COMMIT;'
\echo '💡 To discard test data: ROLLBACK;'
\echo '========================================='

-- COMMIT; 
-- ROLLBACK; -- Uncomment one based on your testing needs