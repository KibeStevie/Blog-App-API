-- ==========================================
-- BLOG API: COMMENTS & REPLIES TEST SCRIPT
-- ==========================================
-- Prerequisites: Auth & Posts modules deployed.
-- Assumes users(user_id 1='alice', 2='bob') exist.
-- Run in psql, pgAdmin, or DBeaver.

BEGIN;

\echo '🔧 SETUP: Create sessions & test post'
-- Create active sessions for testing
INSERT INTO user_sessions (user_id, expires_at) VALUES 
  (1, CURRENT_TIMESTAMP + INTERVAL '1 day') RETURNING session_id \gset alice_session
INSERT INTO user_sessions (user_id, expires_at) VALUES 
  (2, CURRENT_TIMESTAMP + INTERVAL '1 day') RETURNING session_id \gset bob_session

-- Create a test post (user_id=1)
SELECT * FROM fn_create_post(1, 'Test Post for Comments', 'Content here.', NULL, TRUE, NULL, NULL);
-- Assume post_id = 1 for this test run

\echo ''
\echo '========================================='
\echo 'TEST 1: CREATE TOP-LEVEL COMMENTS'
\echo '========================================='
-- Alice comments on post 1
SELECT * FROM fn_create_comment(:'alice_session'::UUID, 1, 'Great article!');
-- Expected: success=t, comment_id=1

-- Bob comments on post 1
SELECT * FROM fn_create_comment(:'bob_session'::UUID, 1, 'I completely agree with this.');
-- Expected: success=t, comment_id=2

\echo ''
\echo '========================================='
\echo 'TEST 2: CREATE REPLIES (NESTED COMMENTS)'
\echo '========================================='
-- Bob replies to Alice's comment (comment_id=1)
SELECT * FROM fn_create_comment(:'bob_session'::UUID, 1, 'Thanks Alice! Learned a lot.', 1);
-- Expected: success=t, comment_id=3

-- Alice replies to Bob's comment (comment_id=2)
SELECT * FROM fn_create_comment(:'alice_session'::UUID, 1, 'Glad it helped, Bob!', 2);
-- Expected: success=t, comment_id=4

-- Deep reply (reply to a reply)
SELECT * FROM fn_create_comment(:'bob_session'::UUID, 1, 'Will try this tomorrow!', 3);
-- Expected: success=t, comment_id=5

\echo ''
\echo '========================================='
\echo 'TEST 3: EDGE CASES & VALIDATION'
\echo '========================================='
-- ❌ Reply to non-existent comment
SELECT * FROM fn_create_comment(:'alice_session'::UUID, 1, 'Reply to nothing', 999);
-- Expected: success=f, error='Parent comment not found in this post'

-- ❌ Reply to comment from a different post
SELECT * FROM fn_create_post(1, 'Another Post', 'Different content', NULL, TRUE, NULL, NULL);
SELECT * FROM fn_create_comment(:'bob_session'::UUID, 2, 'Top comment on post 2');
SELECT * FROM fn_create_comment(:'bob_session'::UUID, 2, 'Cross-post reply attempt', 1);
-- Expected: success=f, error='Parent comment not found in this post'

\echo ''
\echo '========================================='
\echo 'TEST 4: FETCH COMMENTS & VERIFY STRUCTURE'
\echo '========================================='
SELECT 
  comment_id, 
  user_id, 
  content, 
  parent_comment_id, 
  reply_count,
  created_at
FROM fn_get_comments(1, 1, 10);
-- ✅ Expected Output:
-- 1 | 1 | Great article!          | NULL | 1
-- 2 | 2 | I completely agree...   | NULL | 1
-- 3 | 2 | Thanks Alice!           | 1    | 1
-- 4 | 1 | Glad it helped, Bob!    | 2    | 0
-- 5 | 2 | Will try this tomorrow! | 3    | 0

\echo ''
\echo '========================================='
\echo 'TEST 5: VERIFY NOTIFICATIONS TRIGGER'
\echo '========================================='
SELECT 
  n.notification_id,
  n.user_id AS notified_user,
  n.type,
  n.message,
  n.is_read
FROM notifications n
WHERE n.reference_id IN (1,2,3,4,5) 
  AND n.type IN ('comment', 'comment_reply')
ORDER BY n.created_at DESC;
-- ✅ Expected:
-- Top-level comments (1,2) -> type='comment', notified_user=1 (post owner)
-- Replies (3,4,5) -> type='comment_reply', notified_user=parent comment author

\echo ''
\echo '========================================='
\echo 'TEST 6: PAGINATION TEST'
\echo '========================================='
-- Get first 3 comments
SELECT comment_id, content, parent_comment_id FROM fn_get_comments(1, 1, 3);
-- Expected: 3 rows (1,2,3)

-- Get next 3 (offset 3)
SELECT comment_id, content, parent_comment_id FROM fn_get_comments(1, 2, 3);
-- Expected: 2 rows (4,5)

\echo ''
\echo '========================================='
\echo 'TEST 7: CASCADE DELETE ON PARENT COMMENT'
\echo '========================================='
-- Delete Alice's top-level comment (comment_id=1)
-- Alice owns it, so deletion succeeds
SELECT * FROM fn_delete_comment(:'alice_session'::UUID, 1);
-- Expected: success=t, message='Comment deleted'

-- Verify cascade: reply (comment_id=3) and deep reply (5) are gone
SELECT COUNT(*) AS replies_remaining FROM comments WHERE parent_comment_id = 1;
-- Expected: 0

SELECT COUNT(*) AS total_comments FROM comments WHERE post_id = 1;
-- Expected: 2 (comments 2 and 4 remain)

\echo ''
\echo '========================================='
\echo '✅ ALL TESTS COMPLETED'
\echo '========================================='
\echo '💡 To keep changes:  COMMIT;'
\echo '💡 To discard:       ROLLBACK;'
\echo '========================================='

-- COMMIT;
-- ROLLBACK; -- Uncomment one based on your testing needs