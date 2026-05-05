-- ==========================================
-- BLOG API: AUTH FUNCTIONS TEST SCRIPT
-- ==========================================
-- Run this AFTER deploying tables, triggers, views, and functions.
-- Each test section includes expected output comments.

BEGIN;

-- 🔹 TEST SETUP: Clean slate (optional - comment out for production)
-- DELETE FROM notifications;
-- DELETE FROM user_follows;
-- DELETE FROM user_sessions;
-- DELETE FROM user_settings;
-- DELETE FROM users;

-- ==========================================
-- TEST 1: fn_register_user
-- ==========================================
\echo '=== TEST 1: Register User ==='

-- ✅ Test 1a: Valid registration
\echo 'Test 1a: Register new user "alice"'
SELECT * FROM fn_register_user('alice', 'alice@blog.com', 'hash_abc123');
-- Expected: success=t, user_id=1, message='Registered successfully', error=null

-- ✅ Verify trigger created user_settings
\echo 'Verify: user_settings auto-created for alice'
SELECT user_id, theme, email_notifications FROM user_settings WHERE user_id = 1;
-- Expected: 1 row with defaults (theme='light', email_notifications=true)

-- ❌ Test 1b: Duplicate email
\echo 'Test 1b: Register with duplicate email'
SELECT * FROM fn_register_user('bob', 'alice@blog.com', 'hash_xyz789');
-- Expected: success=f, error='Email or username already taken'

-- ❌ Test 1c: Duplicate username
\echo 'Test 1c: Register with duplicate username'
SELECT * FROM fn_register_user('alice', 'bob@blog.com', 'hash_def456');
-- Expected: success=f, error='Email or username already taken'

-- ✅ Test 1d: Register second valid user
\echo 'Test 1d: Register second user "bob"'
SELECT * FROM fn_register_user('bob', 'bob@blog.com', 'hash_bob123');
-- Expected: success=t, user_id=2, message='Registered successfully'

-- ==========================================
-- TEST 2: fn_login_user
-- ==========================================
\echo ''
\echo '=== TEST 2: Login User ==='

-- ✅ Test 2a: Valid login
\echo 'Test 2a: Login with valid credentials (alice)'
SELECT * FROM fn_login_user('alice@blog.com', 'hash_abc123');
-- Expected: success=t, session_id=<uuid>, user_id=1, message='Login successful'
-- 💡 Copy the session_id for later tests:
-- \set alice_session 'copy-uuid-here'

-- ❌ Test 2b: Invalid password
\echo 'Test 2b: Login with wrong password'
SELECT * FROM fn_login_user('alice@blog.com', 'wrong_hash');
-- Expected: success=f, error='Invalid credentials'

-- ❌ Test 2c: Non-existent email
\echo 'Test 2c: Login with non-existent email'
SELECT * FROM fn_login_user('nobody@blog.com', 'any_hash');
-- Expected: success=f, error='Invalid credentials'

-- ✅ Test 2d: Login bob and save session
\echo 'Test 2d: Login bob'
SELECT * FROM fn_login_user('bob@blog.com', 'hash_bob123');
-- Expected: success=t, session_id=<uuid>, user_id=2
-- \set bob_session 'copy-uuid-here'

-- ==========================================
-- TEST 3: fn_validate_session
-- ==========================================
\echo ''
\echo '=== TEST 3: Validate Session ==='

-- ✅ Test 3a: Valid session (use alice's session_id from Test 2a)
\echo 'Test 3a: Validate alice''s session'
-- Replace 'REPLACE_WITH_ALICE_SESSION_UUID' with actual UUID from Test 2a
SELECT * FROM fn_validate_session('REPLACE_WITH_ALICE_SESSION_UUID'::UUID);
-- Expected: success=t, user_id=1, username='alice', theme='light', ...

-- ❌ Test 3b: Invalid UUID format
\echo 'Test 3b: Invalid UUID format'
SELECT * FROM fn_validate_session('not-a-uuid'::UUID);
-- Expected: SQL error (caught by Java layer) or success=f

-- ❌ Test 3c: Expired/non-existent session
\echo 'Test 3c: Non-existent session'
SELECT * FROM fn_validate_session('00000000-0000-0000-0000-000000000000'::UUID);
-- Expected: success=f, error='Invalid or expired session'

-- ==========================================
-- TEST 4: fn_follow_user + Triggers
-- ==========================================
\echo ''
\echo '=== TEST 4: Follow User + Triggers ==='

-- ✅ Test 4a: Bob follows Alice (bob's session)
\echo 'Test 4a: Bob follows Alice'
-- Replace with bob's actual session UUID
SELECT * FROM fn_follow_user('REPLACE_WITH_BOB_SESSION_UUID'::UUID, 1);
-- Expected: success=t, message='Followed successfully'

-- ✅ Verify trigger: notification created for Alice
\echo 'Verify: Notification created for Alice (user_id=1)'
SELECT user_id, type, message, is_read FROM notifications WHERE user_id = 1;
-- Expected: 1 row: type='follow', message='Started following you', is_read=false

-- ❌ Test 4b: Bob tries to follow Alice again (duplicate)
\echo 'Test 4b: Bob follows Alice again (duplicate)'
SELECT * FROM fn_follow_user('REPLACE_WITH_BOB_SESSION_UUID'::UUID, 1);
-- Expected: success=t, message='Already following' (unique_violation caught)

-- ❌ Test 4c: Self-follow (Alice tries to follow herself)
\echo 'Test 4c: Alice tries to follow herself (self-follow)'
-- Replace with alice's actual session UUID
SELECT * FROM fn_follow_user('REPLACE_WITH_ALICE_SESSION_UUID'::UUID, 1);
-- Expected: success=f, error='Cannot follow yourself' (check_violation caught)

-- ❌ Test 4d: Expired session
\echo 'Test 4d: Follow with expired session'
SELECT * FROM fn_follow_user('00000000-0000-0000-0000-000000000000'::UUID, 2);
-- Expected: success=f, error='Unauthorized or expired session'

-- ==========================================
-- TEST 5: fn_get_followers / fn_get_following
-- ==========================================
\echo ''
\echo '=== TEST 5: Get Followers / Following ==='

-- ✅ Test 5a: Get Alice's followers (should include Bob)
\echo 'Test 5a: Get followers of Alice (user_id=1)'
SELECT * FROM fn_get_followers(1);
-- Expected: 1 row: user_id=2, username='bob', profile_image=null

-- ✅ Test 5b: Get Bob's following (should include Alice)
\echo 'Test 5b: Get who Bob follows (user_id=2)'
SELECT * FROM fn_get_following(2);
-- Expected: 1 row: user_id=1, username='alice', profile_image=null

-- ✅ Test 5c: Empty result (Alice follows no one yet)
\echo 'Test 5c: Get who Alice follows (should be empty)'
SELECT * FROM fn_get_following(1);
-- Expected: 0 rows

-- ==========================================
-- TEST 6: fn_update_user_settings
-- ==========================================
\echo ''
\echo '=== TEST 6: Update User Settings ==='

-- ✅ Test 6a: Update Alice's theme and notifications
\echo 'Test 6a: Update Alice''s settings (theme=dark, email_notifications=false)'
SELECT * FROM fn_update_user_settings(
  'REPLACE_WITH_ALICE_SESSION_UUID'::UUID,
  'dark',
  FALSE,
  NULL,  -- keep push_notifications default
  NULL   -- keep privacy_mode default
);
-- Expected: success=t, message='Settings updated successfully'

-- ✅ Verify update
\echo 'Verify: Alice''s settings updated'
SELECT theme, email_notifications, push_notifications, privacy_mode 
FROM user_settings WHERE user_id = 1;
-- Expected: theme='dark', email_notifications=false, others unchanged

-- ✅ Test 6b: Partial update (only privacy_mode)
\echo 'Test 6b: Partial update - only privacy_mode'
SELECT * FROM fn_update_user_settings(
  'REPLACE_WITH_ALICE_SESSION_UUID'::UUID,
  NULL, NULL, NULL, 'private'
);
-- Expected: success=t

-- ✅ Verify only privacy_mode changed
\echo 'Verify: Only privacy_mode changed'
SELECT theme, email_notifications, privacy_mode FROM user_settings WHERE user_id = 1;
-- Expected: theme='dark' (unchanged), email_notifications=false (unchanged), privacy_mode='private'

-- ❌ Test 6c: Unauthorized session
\echo 'Test 6c: Update settings with invalid session'
SELECT * FROM fn_update_user_settings(
  '00000000-0000-0000-0000-000000000000'::UUID,
  'light', TRUE, TRUE, 'public'
);
-- Expected: success=f, error='Unauthorized'

-- ==========================================
-- TEST 7: fn_unfollow_user
-- ==========================================
\echo ''
\echo '=== TEST 7: Unfollow User ==='

-- ✅ Test 7a: Bob unfollows Alice
\echo 'Test 7a: Bob unfollows Alice'
SELECT * FROM fn_unfollow_user('REPLACE_WITH_BOB_SESSION_UUID'::UUID, 1);
-- Expected: success=t, message='Unfollowed successfully'

-- ✅ Verify follow record deleted
\echo 'Verify: Follow record deleted'
SELECT COUNT(*) FROM user_follows WHERE follower_id = 2 AND following_id = 1;
-- Expected: 0

-- ✅ Verify notification NOT deleted (notifications are historical)
\echo 'Verify: Notification still exists (historical)'
SELECT COUNT(*) FROM notifications WHERE user_id = 1 AND type = 'follow';
-- Expected: 1 (notifications persist after unfollow)

-- ❌ Test 7b: Unfollow when not following
\echo 'Test 7b: Bob tries to unfollow Alice again (not following)'
SELECT * FROM fn_unfollow_user('REPLACE_WITH_BOB_SESSION_UUID'::UUID, 1);
-- Expected: success=f, error='Not following'

-- ==========================================
-- TEST 8: fn_logout_user
-- ==========================================
\echo ''
\echo '=== TEST 8: Logout User ==='

-- ✅ Test 8a: Logout Alice
\echo 'Test 8a: Logout Alice'
SELECT * FROM fn_logout_user('REPLACE_WITH_ALICE_SESSION_UUID'::UUID);
-- Expected: success=t, message='Logged out successfully'

-- ✅ Verify session deleted
\echo 'Verify: Alice''s session deleted'
SELECT COUNT(*) FROM user_sessions WHERE user_id = 1;
-- Expected: 0 (or only expired sessions if any remain)

-- ✅ Test 8b: Validate session after logout (should fail)
\echo 'Test 8b: Validate session after logout'
SELECT * FROM fn_validate_session('REPLACE_WITH_ALICE_SESSION_UUID'::UUID);
-- Expected: success=f, error='Invalid or expired session'

-- ✅ Test 8c: Logout is idempotent (logout again = still success)
\echo 'Test 8c: Logout again (idempotent)'
SELECT * FROM fn_logout_user('REPLACE_WITH_ALICE_SESSION_UUID'::UUID);
-- Expected: success=t, message='Logged out successfully'

-- ==========================================
-- TEST 9: View v_user_auth_profile
-- ==========================================
\echo ''
\echo '=== TEST 9: View v_user_auth_profile ==='

-- ✅ Test 9a: Query view directly
\echo 'Test 9a: Query auth profile view for Bob'
SELECT user_id, username, followers_count, following_count, theme 
FROM v_user_auth_profile WHERE user_id = 2;
-- Expected: 1 row with Bob's data + counts (followers_count=0, following_count=0 after unfollow)

-- ==========================================
-- TEST 10: Edge Cases & Data Integrity
-- ==========================================
\echo ''
\echo '=== TEST 10: Edge Cases ==='

-- ✅ Test 10a: Register with NULL bio/profile_image (should work)
\echo 'Test 10a: Register user with optional fields NULL'
SELECT * FROM fn_register_user('charlie', 'charlie@blog.com', 'hash_charlie');
-- Expected: success=t, user_id=3

-- ✅ Test 10b: Verify bio/profile_image are NULL in DB
\echo 'Verify: Optional fields are NULL'
SELECT bio, profile_image FROM users WHERE username = 'charlie';
-- Expected: both NULL

-- ✅ Test 10c: Login and get profile (NULL fields handled)
\echo 'Test 10c: Login Charlie and validate session'
-- First login to get session
SELECT session_id FROM fn_login_user('charlie@blog.com', 'hash_charlie') WHERE success;
-- Then validate (replace with actual session_id)
-- SELECT * FROM fn_validate_session('charlie_session_uuid'::UUID);
-- Expected: success=t, bio=null, profile_image=null

-- ==========================================
-- FINAL STATUS CHECK
-- ==========================================
\echo ''
\echo '=== FINAL DATA SNAPSHOT ==='
\echo 'Users:'
SELECT user_id, username, email FROM users ORDER BY user_id;

\echo 'Sessions (active):'
SELECT session_id, user_id, expires_at > CURRENT_TIMESTAMP as is_active 
FROM user_sessions ORDER BY created_at DESC;

\echo 'Follows:'
SELECT follower_id, following_id, created_at FROM user_follows;

\echo 'Settings:'
SELECT user_id, theme, email_notifications FROM user_settings ORDER BY user_id;

\echo 'Notifications:'
SELECT notification_id, user_id, type, message, is_read FROM notifications;


-- 1. Get notifications (page 1, limit 10, all)
SELECT * FROM fn_get_notifications('your-session-uuid-here', 1, 10, FALSE);

-- 2. Get only unread notifications
SELECT * FROM fn_get_notifications('your-session-uuid-here', 1, 10, TRUE);

-- 3. Mark notification #5 as read
SELECT * FROM fn_update_notification_status('your-session-uuid-here', 5, TRUE);

-- 4. Mark notification #5 as unread
SELECT * FROM fn_update_notification_status('your-session-uuid-here', 5, FALSE);

-- 5. Delete notification #5
SELECT * FROM fn_delete_notification('your-session-uuid-here', 5);

-- 6. Mark all as read
SELECT * FROM fn_mark_all_notifications_read('your-session-uuid-here');

COMMIT;

\echo ''
\echo '✅ All tests completed. Review outputs above for expected results.'
\echo '💡 To re-run tests, rollback with ROLLBACK; instead of COMMIT; at the top.'




