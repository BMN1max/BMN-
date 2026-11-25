-- BMN Board B1 tests (LOCAL THROWAWAY DATABASE ONLY). Runs after the Batch 3 fixtures (users 1..6 = alice bob carol dave erin mallory).
-- Every check records PASS/FAIL into t.results.

-- Start from a clean relationship state (Batch 3 tests leave blocks, follows, settings behind).
DO $$ BEGIN
  PERFORM t.su();
  DELETE FROM public.user_blocks; DELETE FROM public.follows; DELETE FROM public.user_settings;
  DELETE FROM public.bmn_user_moderation; DELETE FROM public.bmn_admins;
END $$;

-- ===== 1. structure and security surface =====
DO $$
DECLARE tb text;
BEGIN
  PERFORM t.su();
  FOREACH tb IN ARRAY ARRAY['board_posts','board_likes','board_reposts','board_bookmarks','board_post_tags','board_post_mentions','board_views','board_notifications','board_post_edits'] LOOP
    PERFORM t.ok('B1 RLS enabled on ' || tb, (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || tb)::regclass));
  END LOOP;
  PERFORM t.ok('B1 video posts table has no board columns', NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='posts' AND column_name ILIKE '%board%'));
  PERFORM t.ok('B1 content_reports reuses the existing moderation queue (new column)', EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='content_reports' AND column_name='board_post_id'));
  PERFORM t.ok('B1 no board table duplicates profiles', NOT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname='public' AND tablename ILIKE 'board%profile%'));
  PERFORM t.ok('B1 author FK points at the existing profiles table',
    EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.board_posts'::regclass AND contype='f' AND confrelid='public.profiles'::regclass));
END $$;

-- ===== 2. clients cannot write tables directly =====
DO $$
DECLARE a uuid := t.u(1);
BEGIN
  PERFORM t.as_user(a);
  PERFORM t.throws('B1 direct INSERT into board_posts is refused', format($q$INSERT INTO public.board_posts(author_id, body) VALUES (%L,'sneaky')$q$, a), 'permission denied');
  PERFORM t.throws('B1 direct INSERT into board_likes is refused', format($q$INSERT INTO public.board_likes(post_id,user_id) VALUES (gen_random_uuid(),%L)$q$, a), 'permission denied');
  PERFORM t.throws('B1 direct INSERT into board_notifications is refused', format($q$INSERT INTO public.board_notifications(user_id,actor_id,type) VALUES (%L,%L,'like')$q$, a, a), 'permission denied');
  PERFORM t.throws('B1 board_views is not readable', 'select * from public.board_views', 'permission denied');
  PERFORM t.throws('B1 internal helper board_notify is not callable', format($q$SELECT public.board_notify(%L,%L,'like',NULL)$q$, a, t.u(2)), 'permission denied');
  PERFORM t.su();
  PERFORM set_config('request.jwt.claim.sub', '', false); PERFORM set_config('request.jwt.claim.role', 'anon', false); EXECUTE 'SET ROLE anon';
  PERFORM t.throws('B1 anonymous cannot post', $q$SELECT public.board_create_post('hello')$q$, 'permission denied');
  PERFORM t.throws('B1 anonymous cannot like', $q$SELECT public.board_set_like(gen_random_uuid(), true)$q$, 'permission denied');
  PERFORM t.works('B1 anonymous can read the latest feed (empty at first)', $q$SELECT * FROM public.board_feed('latest')$q$);
  PERFORM t.su();
END $$;

-- ===== 3. posting and server-side validation =====
DO $$
DECLARE a uuid := t.u(1); b uuid := t.u(2); id1 uuid; v text;
BEGIN
  PERFORM t.as_user(a);
  id1 := public.board_create_post('  Hello BMN Board #BMN #bmn #Lagos2026 #123 @bob @nobody @alice  ');
  PERFORM t.set('p1', id1::text);
  PERFORM t.ok('B1 alice posts text', id1 IS NOT NULL);
  PERFORM t.ok('B1 body is trimmed', (SELECT body FROM public.board_posts WHERE id = id1) = 'Hello BMN Board #BMN #bmn #Lagos2026 #123 @bob @nobody @alice');
  PERFORM t.ok('B1 counters start at zero', (SELECT like_count + repost_count + reply_count + quote_count + view_count FROM public.board_posts WHERE id = id1) = 0);
  PERFORM t.ok('B1 hashtags extracted (lowercase, deduped, digits-only ignored)', (SELECT array_agg(tag ORDER BY tag) FROM public.board_post_tags WHERE post_id = id1) = ARRAY['bmn','lagos2026']);
  PERFORM t.su();
  PERFORM t.ok('B1 mention resolved to bob only (not self, not unknown)', (SELECT array_agg(user_id) FROM public.board_post_mentions WHERE post_id = id1) = ARRAY[b]);
  PERFORM t.ok('B1 bob got one mention notification from alice', t.count(format($q$select 1 from public.board_notifications where user_id=%L and actor_id=%L and type='mention' and post_id=%L$q$, b, a, id1)) = 1);

  PERFORM t.as_user(a);
  PERFORM t.throws('B1 empty post refused', $q$SELECT public.board_create_post('   ')$q$, 'Write something');
  PERFORM t.throws('B1 501 characters refused', format($q$SELECT public.board_create_post(%L)$q$, repeat('x', 501)), 'at most 500');
  PERFORM t.works('B1 exactly 500 characters accepted', format($q$SELECT public.board_create_post(%L)$q$, repeat('y', 500)));
  PERFORM t.works('B1 image-only post accepted (https)', $q$SELECT public.board_create_post('', '[{"type":"image","url":"https://media.example.com/a.jpg","w":800,"h":600,"alt":"a photo"}]')$q$);
  PERFORM t.works('B1 video with thumbnail accepted (storage key)', $q$SELECT public.board_create_post('clip', '[{"type":"video","url":"board/u1/clip.mp4","thumb":"board/u1/clip.jpg"}]')$q$);
  PERFORM t.works('B1 four images accepted', $q$SELECT public.board_create_post('four', '[{"type":"image","url":"https://m.example.com/1.jpg"},{"type":"image","url":"https://m.example.com/2.jpg"},{"type":"image","url":"https://m.example.com/3.jpg"},{"type":"image","url":"https://m.example.com/4.jpg"}]')$q$);
  PERFORM t.throws('B1 five attachments refused', $q$SELECT public.board_create_post('five', '[{"type":"image","url":"https://m.example.com/1.jpg"},{"type":"image","url":"https://m.example.com/2.jpg"},{"type":"image","url":"https://m.example.com/3.jpg"},{"type":"image","url":"https://m.example.com/4.jpg"},{"type":"image","url":"https://m.example.com/5.jpg"}]')$q$, 'up to 4');
  PERFORM t.throws('B1 two videos refused', $q$SELECT public.board_create_post('v', '[{"type":"video","url":"https://m.example.com/1.mp4"},{"type":"video","url":"https://m.example.com/2.mp4"}]')$q$, 'one video');
  PERFORM t.throws('B1 unknown media type refused', $q$SELECT public.board_create_post('v', '[{"type":"audio","url":"https://m.example.com/1.mp3"}]')$q$, 'photos or videos');
  PERFORM t.throws('B1 javascript: url refused', $q$SELECT public.board_create_post('v', '[{"type":"image","url":"javascript:alert(1)"}]')$q$, 'Invalid attachment address');
  PERFORM t.throws('B1 http: (not https) url refused', $q$SELECT public.board_create_post('v', '[{"type":"image","url":"http://m.example.com/1.jpg"}]')$q$, 'Invalid attachment address');
  PERFORM t.throws('B1 url with a quote character refused', $q$SELECT public.board_create_post('v', '[{"type":"image","url":"https://m.example.com/1.jpg\"onerror=1"}]')$q$, 'Invalid attachment address');
  PERFORM t.throws('B1 media that is not a list refused', $q$SELECT public.board_create_post('v', '{"type":"image"}')$q$, 'must be a list');
  v := (SELECT media::text FROM public.board_posts WHERE body = 'clip');
  PERFORM t.ok('B1 media is normalised (only known keys kept)', v LIKE '%"thumb"%' AND v NOT LIKE '%onerror%');
  PERFORM t.works('B1 extra unknown keys are dropped, not stored', $q$SELECT public.board_create_post('x2', '[{"type":"image","url":"https://m.example.com/1.jpg","evil":"<script>"}]')$q$);
  PERFORM t.ok('B1 unknown media keys not stored', NOT EXISTS (SELECT 1 FROM public.board_posts WHERE media::text LIKE '%evil%'));
  PERFORM t.su();
END $$;

-- ===== 4. replies, threads, quotes =====
DO $$
DECLARE a uuid := t.u(1); b uuid := t.u(2); c uuid := t.u(3); p1 uuid := t.get('p1')::uuid; r1 uuid; r2 uuid; q1 uuid;
BEGIN
  PERFORM t.as_user(b);
  r1 := public.board_create_post('Welcome back, Alice! #replies', '[]', p1);
  PERFORM t.as_user(c);
  r2 := public.board_create_post('Agreed with Bob', '[]', r1);
  PERFORM t.set('r1', r1::text); PERFORM t.set('r2', r2::text);
  PERFORM t.ok('B1 reply points at its parent and the thread root', (SELECT parent_id = r1 AND root_id = p1 FROM public.board_posts WHERE id = r2));
  PERFORM t.ok('B1 reply to a top post: root is that post', (SELECT parent_id = p1 AND root_id = p1 FROM public.board_posts WHERE id = r1));
  PERFORM t.ok('B1 parent reply_count counts real replies', (SELECT reply_count FROM public.board_posts WHERE id = p1) = 1 AND (SELECT reply_count FROM public.board_posts WHERE id = r1) = 1);
  PERFORM t.ok('B1 ancestors of the nested reply are root first', (SELECT array_agg(id ORDER BY depth DESC) FROM public.board_ancestors(r2)) = ARRAY[p1, r1]);
  PERFORM t.su();
  PERFORM t.ok('B1 alice was notified of bob''s reply', t.count(format($q$select 1 from public.board_notifications where user_id=%L and actor_id=%L and type='reply' and post_id=%L$q$, a, b, r1)) = 1);
  PERFORM t.ok('B1 bob was notified of carol''s reply', t.count(format($q$select 1 from public.board_notifications where user_id=%L and actor_id=%L and type='reply' and post_id=%L$q$, b, c, r2)) = 1);

  PERFORM t.as_user(c);
  q1 := public.board_create_post('Quoting this with my own words', '[]', NULL, p1);
  PERFORM t.set('q1', q1::text);
  PERFORM t.ok('B1 quote post keeps the quoted id, is top level', (SELECT quote_id = p1 AND parent_id IS NULL FROM public.board_posts WHERE id = q1));
  PERFORM t.ok('B1 quoted post quote_count increments', (SELECT quote_count FROM public.board_posts WHERE id = p1) = 1);
  PERFORM t.throws('B1 quote without any text or media refused', format($q$SELECT public.board_create_post('', '[]', NULL, %L)$q$, p1), 'Write something');
  PERFORM t.throws('B1 a post cannot be both reply and quote', format($q$SELECT public.board_create_post('both', '[]', %L, %L)$q$, p1, p1), 'not both');
  PERFORM t.throws('B1 reply to a missing post refused', $q$SELECT public.board_create_post('x', '[]', gen_random_uuid())$q$, 'not available');
  PERFORM t.su();
  PERFORM t.ok('B1 alice was notified of the quote', t.count(format($q$select 1 from public.board_notifications where user_id=%L and actor_id=%L and type='quote'$q$, a, c)) = 1);
END $$;

-- ===== 5. likes, reposts, bookmarks, views =====
DO $$
DECLARE a uuid := t.u(1); b uuid := t.u(2); c uuid := t.u(3); p1 uuid := t.get('p1')::uuid;
BEGIN
  PERFORM t.as_user(b);
  PERFORM t.works('B1 bob likes alice''s post', format($q$SELECT public.board_set_like(%L,true)$q$, p1));
  PERFORM t.works('B1 liking twice is harmless', format($q$SELECT public.board_set_like(%L,true)$q$, p1));
  PERFORM t.ok('B1 like_count is the real number of likes (1)', (SELECT like_count FROM public.board_posts WHERE id = p1) = 1);
  PERFORM t.ok('B1 bob sees his own like', t.count(format($q$select 1 from public.board_likes where post_id=%L$q$, p1)) = 1);
  PERFORM t.as_user(a);
  PERFORM t.ok('B1 alice cannot see who liked (likes are private to the liker)', t.count('select 1 from public.board_likes') = 0);
  PERFORM t.su();
  PERFORM t.ok('B1 exactly one like notification despite two taps', t.count(format($q$select 1 from public.board_notifications where user_id=%L and type='like' and post_id=%L$q$, a, p1)) = 1);
  PERFORM t.as_user(b);
  PERFORM t.works('B1 bob unlikes', format($q$SELECT public.board_set_like(%L,false)$q$, p1));
  PERFORM t.ok('B1 like_count back to 0', (SELECT like_count FROM public.board_posts WHERE id = p1) = 0);
  PERFORM t.works('B1 bob likes again', format($q$SELECT public.board_set_like(%L,true)$q$, p1));
  PERFORM t.as_user(c);
  PERFORM t.works('B1 carol likes', format($q$SELECT public.board_set_like(%L,true)$q$, p1));
  PERFORM t.ok('B1 like_count 2', (SELECT like_count FROM public.board_posts WHERE id = p1) = 2);

  PERFORM t.works('B1 carol reposts', format($q$SELECT public.board_set_repost(%L,true)$q$, p1));
  PERFORM t.ok('B1 repost_count 1', (SELECT repost_count FROM public.board_posts WHERE id = p1) = 1);
  PERFORM t.works('B1 carol undoes the repost', format($q$SELECT public.board_set_repost(%L,false)$q$, p1));
  PERFORM t.ok('B1 repost_count back to 0', (SELECT repost_count FROM public.board_posts WHERE id = p1) = 0);
  PERFORM t.works('B1 carol reposts again (kept for the timelines)', format($q$SELECT public.board_set_repost(%L,true)$q$, p1));

  PERFORM t.as_user(b);
  PERFORM t.works('B1 bob bookmarks', format($q$SELECT public.board_set_bookmark(%L,true)$q$, p1));
  PERFORM t.ok('B1 bob sees his bookmark', t.count('select 1 from public.board_bookmarks') = 1);
  PERFORM t.as_user(a);
  PERFORM t.ok('B1 bookmarks are private (alice sees none of bob''s)', t.count('select 1 from public.board_bookmarks') = 0);
  PERFORM t.as_user(b);
  PERFORM t.works('B1 bob removes the bookmark', format($q$SELECT public.board_set_bookmark(%L,false)$q$, p1));
  PERFORM t.ok('B1 bookmark gone', t.count('select 1 from public.board_bookmarks') = 0);

  -- views: distinct signed-in viewers other than the author, once each
  PERFORM t.works('B1 bob views', format($q$SELECT public.board_record_view(%L)$q$, p1));
  PERFORM t.works('B1 bob views again', format($q$SELECT public.board_record_view(%L)$q$, p1));
  PERFORM t.ok('B1 repeat views by one person count once', (SELECT view_count FROM public.board_posts WHERE id = p1) = 1);
  PERFORM t.as_user(a);
  PERFORM t.works('B1 author viewing own post', format($q$SELECT public.board_record_view(%L)$q$, p1));
  PERFORM t.ok('B1 author''s own views are not counted', (SELECT view_count FROM public.board_posts WHERE id = p1) = 1);
  PERFORM t.as_user(c);
  PERFORM t.works('B1 carol views', format($q$SELECT public.board_record_view(%L)$q$, p1));
  PERFORM t.ok('B1 view_count = 2 distinct viewers', (SELECT view_count FROM public.board_posts WHERE id = p1) = 2);
  PERFORM t.throws('B1 liking a missing post refused', $q$SELECT public.board_set_like(gen_random_uuid(), true)$q$, 'not available');
  PERFORM t.su();
END $$;

-- ===== 6. blocks, mutes, private accounts, reply permission =====
DO $$
DECLARE a uuid := t.u(1); b uuid := t.u(2); c uuid := t.u(3); d uuid := t.u(4); e uuid := t.u(5);
        p1 uuid := t.get('p1')::uuid; pd uuid; pe uuid;
BEGIN
  PERFORM t.as_user(d); pd := public.board_create_post('Dave''s first post #dave'); PERFORM t.set('pd', pd::text);
  PERFORM t.as_user(e); pe := public.board_create_post('Erin''s first post'); PERFORM t.set('pe', pe::text);
  PERFORM t.as_user(a);
  PERFORM t.works('B1 alice blocks dave (existing user_blocks table)', format($q$INSERT INTO public.user_blocks(user_id,target_id,kind) VALUES (%L,%L,'block')$q$, a, d));
  PERFORM t.ok('B1 alice no longer sees dave''s post', t.count(format($q$select 1 from public.board_posts where id=%L$q$, pd)) = 0);
  PERFORM t.as_user(d);
  PERFORM t.ok('B1 dave cannot see alice''s post (block works both ways)', t.count(format($q$select 1 from public.board_posts where id=%L$q$, p1)) = 0);
  PERFORM t.ok('B1 dave''s latest feed hides alice', NOT EXISTS (SELECT 1 FROM public.board_feed('latest') WHERE post_id = p1));
  PERFORM t.throws('B1 blocked: dave cannot reply', format($q$SELECT public.board_create_post('hi', '[]', %L)$q$, p1), 'not available');
  PERFORM t.throws('B1 blocked: dave cannot like', format($q$SELECT public.board_set_like(%L,true)$q$, p1), 'not available');
  PERFORM t.throws('B1 blocked: dave cannot repost', format($q$SELECT public.board_set_repost(%L,true)$q$, p1), 'not available');
  PERFORM t.throws('B1 blocked: dave cannot bookmark', format($q$SELECT public.board_set_bookmark(%L,true)$q$, p1), 'not available');
  PERFORM t.throws('B1 blocked: dave cannot quote', format($q$SELECT public.board_create_post('q', '[]', NULL, %L)$q$, p1), 'not available');
  PERFORM t.as_user(a);
  PERFORM t.throws('B1 blocked: alice cannot reply to dave either', format($q$SELECT public.board_create_post('hi', '[]', %L)$q$, pd), 'not available');
  PERFORM t.as_user(d);
  PERFORM t.works('B1 dave mentions alice (allowed, but no notification)', $q$SELECT public.board_create_post('hello @alice')$q$);
  PERFORM t.su();
  PERFORM t.ok('B1 no notification across a block', t.count(format($q$select 1 from public.board_notifications where user_id=%L and actor_id=%L$q$, a, d)) = 0);
  PERFORM t.as_user(a);
  PERFORM t.works('B1 alice unblocks dave', format($q$DELETE FROM public.user_blocks WHERE user_id=%L AND target_id=%L AND kind='block'$q$, a, d));
  PERFORM t.ok('B1 after unblock alice sees dave''s post again', t.count(format($q$select 1 from public.board_posts where id=%L$q$, pd)) = 1);

  -- mute: hidden from MY timelines, still reachable directly, no notifications from the muted person
  PERFORM t.as_user(e);
  PERFORM t.works('B1 erin mutes bob', format($q$INSERT INTO public.user_blocks(user_id,target_id,kind) VALUES (%L,%L,'mute')$q$, e, b));
  PERFORM t.as_user(b);
  PERFORM t.works('B1 bob posts after being muted', $q$SELECT public.board_create_post('Bob here #muted')$q$);
  PERFORM t.works('B1 bob likes erin''s post', format($q$SELECT public.board_set_like(%L,true)$q$, pe));
  PERFORM t.su();
  PERFORM t.ok('B1 muted: erin gets no like notification from bob', t.count(format($q$select 1 from public.board_notifications where user_id=%L and actor_id=%L$q$, e, b)) = 0);
  PERFORM t.as_user(e);
  PERFORM t.ok('B1 muted: bob''s posts are absent from erin''s Latest', NOT EXISTS (SELECT 1 FROM public.board_feed('latest', 50) f JOIN public.board_posts p ON p.id = f.post_id WHERE p.author_id = b));
  PERFORM t.ok('B1 muted: erin can still open bob''s post directly', t.count(format($q$select 1 from public.board_posts where author_id=%L$q$, b)) > 0);
  PERFORM t.works('B1 erin unmutes bob', format($q$DELETE FROM public.user_blocks WHERE user_id=%L AND target_id=%L AND kind='mute'$q$, e, b));
  PERFORM t.su();

  -- private account: only the owner and followers see the posts
  INSERT INTO public.user_settings(user_id, private_account) VALUES (c, true) ON CONFLICT (user_id) DO UPDATE SET private_account = true;
  PERFORM t.as_user(e); INSERT INTO public.follows(follower_id, following_id) VALUES (e, c) ON CONFLICT DO NOTHING; PERFORM t.su();
  PERFORM t.as_user(b);
  PERFORM t.ok('B1 private: non-follower cannot see carol''s posts', t.count(format($q$select 1 from public.board_posts where author_id=%L$q$, c)) = 0);
  PERFORM t.throws('B1 private: non-follower cannot like', format($q$SELECT public.board_set_like(%L,true)$q$, t.get('q1')::uuid), 'not available');
  PERFORM t.as_user(e);
  PERFORM t.ok('B1 private: follower sees carol''s posts', t.count(format($q$select 1 from public.board_posts where author_id=%L$q$, c)) > 0);
  PERFORM t.as_user(c);
  PERFORM t.ok('B1 private: carol sees her own posts', t.count(format($q$select 1 from public.board_posts where author_id=%L$q$, c)) > 0);
  PERFORM t.su();
  PERFORM set_config('request.jwt.claim.sub', '', false); PERFORM set_config('request.jwt.claim.role', 'anon', false); EXECUTE 'SET ROLE anon';
  PERFORM t.ok('B1 private: signed-out visitors cannot see carol''s posts', t.count(format($q$select 1 from public.board_posts where author_id=%L$q$, c)) = 0);
  PERFORM t.su();
  UPDATE public.user_settings SET private_account = false WHERE user_id = c;

  -- reply permission (existing user_settings.allow_comments)
  UPDATE public.user_settings SET allow_comments = 'nobody' WHERE user_id = c;
  PERFORM t.as_user(b);
  PERFORM t.throws('B1 allow_comments=nobody: bob cannot reply to carol', format($q$SELECT public.board_create_post('x', '[]', %L)$q$, t.get('q1')::uuid), 'turned replies off');
  PERFORM t.as_user(c);
  PERFORM t.works('B1 allow_comments=nobody: carol can reply to herself', format($q$SELECT public.board_create_post('self reply', '[]', %L)$q$, t.get('q1')::uuid));
  PERFORM t.su();
  UPDATE public.user_settings SET allow_comments = 'following' WHERE user_id = c;
  PERFORM t.as_user(b);
  PERFORM t.throws('B1 allow_comments=following: bob (not followed by carol) refused', format($q$SELECT public.board_create_post('x', '[]', %L)$q$, t.get('q1')::uuid), 'follows can reply');
  PERFORM t.su();
  PERFORM t.as_user(c); INSERT INTO public.follows(follower_id, following_id) VALUES (c, b) ON CONFLICT DO NOTHING; PERFORM t.su();
  PERFORM t.as_user(b);
  PERFORM t.works('B1 allow_comments=following: bob allowed once carol follows him', format($q$SELECT public.board_create_post('thanks for the follow', '[]', %L)$q$, t.get('q1')::uuid));
  PERFORM t.su();
  UPDATE public.user_settings SET allow_comments = 'everyone' WHERE user_id = c;
  DELETE FROM public.follows WHERE follower_id = c AND following_id = b;
END $$;

-- ===== 7. account restrictions and rate limit =====
DO $$
DECLARE m uuid := t.u(6); e uuid := t.u(5); i int;
BEGIN
  PERFORM t.su();
  INSERT INTO public.bmn_user_moderation(user_id, status, expires_at) VALUES (m, 'suspended', now() + interval '1 day')
    ON CONFLICT (user_id) DO UPDATE SET status = 'suspended', expires_at = now() + interval '1 day';
  PERFORM t.as_user(m);
  PERFORM t.throws('B1 suspended account cannot post', $q$SELECT public.board_create_post('hi')$q$, 'restricted');
  PERFORM t.throws('B1 suspended account cannot like', format($q$SELECT public.board_set_like(%L,true)$q$, t.get('p1')::uuid), 'restricted');
  PERFORM t.su();
  UPDATE public.bmn_user_moderation SET expires_at = now() - interval '1 minute' WHERE user_id = m;
  PERFORM t.as_user(m);
  PERFORM t.works('B1 an expired suspension no longer blocks posting', $q$SELECT public.board_create_post('back again')$q$);
  PERFORM t.su();
  UPDATE public.bmn_user_moderation SET status = 'banned', expires_at = NULL WHERE user_id = m;
  PERFORM t.as_user(m);
  PERFORM t.throws('B1 banned account cannot post', $q$SELECT public.board_create_post('hi')$q$, 'restricted');
  PERFORM t.su();
  UPDATE public.bmn_user_moderation SET status = 'active' WHERE user_id = m;

  PERFORM t.as_user(e);
  FOR i IN 1..28 LOOP PERFORM public.board_create_post('burst ' || i); END LOOP;   -- erin already has 1 post
  PERFORM t.works('B1 the 30th post in ten minutes is accepted', $q$SELECT public.board_create_post('burst 29')$q$);
  PERFORM t.throws('B1 the 31st post in ten minutes is refused (rate limit)', $q$SELECT public.board_create_post('burst 30')$q$, 'too quickly');
  PERFORM t.su();
END $$;

-- ===== 8. edit and delete =====
DO $$
DECLARE a uuid := t.u(1); b uuid := t.u(2); c uuid := t.u(3); p1 uuid := t.get('p1')::uuid; r1 uuid := t.get('r1')::uuid; old_created timestamptz;
BEGIN
  PERFORM t.as_user(a);
  PERFORM t.works('B1 alice edits her post', format($q$SELECT public.board_edit_post(%L, 'Hello BMN Board, edited #BMN #edited')$q$, p1));
  PERFORM t.ok('B1 edited_at is set and body changed', (SELECT edited_at IS NOT NULL AND body LIKE '%edited%' FROM public.board_posts WHERE id = p1));
  PERFORM t.ok('B1 hashtags re-derived on edit', (SELECT array_agg(tag ORDER BY tag) FROM public.board_post_tags WHERE post_id = p1) = ARRAY['bmn','edited']);
  PERFORM t.ok('B1 alice can read her edit history', t.count(format($q$select 1 from public.board_post_edits where post_id=%L$q$, p1)) = 1);
  PERFORM t.works('B1 an unchanged edit is a no-op', format($q$SELECT public.board_edit_post(%L, 'Hello BMN Board, edited #BMN #edited')$q$, p1));
  PERFORM t.ok('B1 no extra history row for a no-op', t.count(format($q$select 1 from public.board_post_edits where post_id=%L$q$, p1)) = 1);
  PERFORM t.as_user(b);
  PERFORM t.throws('B1 bob cannot edit alice''s post', format($q$SELECT public.board_edit_post(%L, 'hijack')$q$, p1), 'only edit your own');
  PERFORM t.ok('B1 bob cannot read alice''s edit history', t.count('select 1 from public.board_post_edits') = 0);
  PERFORM t.throws('B1 bob cannot delete alice''s post', format($q$SELECT public.board_delete_post(%L)$q$, p1), 'only delete your own');
  PERFORM t.su();
  SELECT created_at INTO old_created FROM public.board_posts WHERE id = p1;
  UPDATE public.board_posts SET created_at = now() - interval '25 hours' WHERE id = p1;
  PERFORM t.as_user(a);
  PERFORM t.throws('B1 edit window closes after 24 hours', format($q$SELECT public.board_edit_post(%L, 'too late')$q$, p1), '24 hours');
  PERFORM t.su();
  UPDATE public.board_posts SET created_at = old_created WHERE id = p1;

  -- deleting a reply: tombstone, parent count falls, notifications and tags removed
  PERFORM t.as_user(b);
  PERFORM t.works('B1 bob deletes his reply', format($q$SELECT public.board_delete_post(%L)$q$, r1));
  PERFORM t.su();
  PERFORM t.ok('B1 deleted post is an empty tombstone', (SELECT deleted_at IS NOT NULL AND body = '' AND media = '[]'::jsonb FROM public.board_posts WHERE id = r1));
  PERFORM t.ok('B1 parent reply_count falls when a reply is deleted', (SELECT reply_count FROM public.board_posts WHERE id = p1) = 0);
  PERFORM t.ok('B1 tombstone keeps the thread intact (carol''s nested reply still points at it)', (SELECT parent_id = r1 FROM public.board_posts WHERE id = t.get('r2')::uuid));
  PERFORM t.ok('B1 tags of the deleted post are gone', t.count(format($q$select 1 from public.board_post_tags where post_id=%L$q$, r1)) = 0);
  PERFORM t.ok('B1 notifications about the deleted post are gone', t.count(format($q$select 1 from public.board_notifications where post_id=%L$q$, r1)) = 0);
  PERFORM t.as_user(c);
  PERFORM t.throws('B1 cannot like a deleted post', format($q$SELECT public.board_set_like(%L,true)$q$, r1), 'not available');
  PERFORM t.ok('B1 deleted posts are not in any feed', NOT EXISTS (SELECT 1 FROM public.board_feed('latest', 50) WHERE post_id = r1));
  PERFORM t.throws('B1 deleting twice is refused', format($q$SELECT public.board_delete_post(%L)$q$, r1), 'not found');
  PERFORM t.su();

  -- owner can remove any post
  INSERT INTO public.bmn_admins(user_id, role) VALUES (t.u(5), 'owner') ON CONFLICT DO NOTHING;
  PERFORM t.as_user(t.u(5));
  PERFORM t.works('B1 BMN owner can delete another user''s post (moderation)', format($q$SELECT public.board_delete_post(%L)$q$, t.get('pd')::uuid));
  PERFORM t.su();
  DELETE FROM public.bmn_admins WHERE user_id = t.u(5);
END $$;

-- ===== 9. reports =====
DO $$
DECLARE a uuid := t.u(1); b uuid := t.u(2); p1 uuid := t.get('p1')::uuid; rid uuid; rid2 uuid;
BEGIN
  PERFORM t.as_user(b);
  rid := public.board_report_post(p1, 'spam', 'looks like spam');
  PERFORM t.ok('B1 report lands in the existing content_reports queue', rid IS NOT NULL);
  rid2 := public.board_report_post(p1, 'spam', 'again');
  PERFORM t.ok('B1 a second report of the same post by the same person is de-duplicated', rid = rid2);
  PERFORM t.throws('B1 invalid report reason refused', format($q$SELECT public.board_report_post(%L, 'because')$q$, p1), 'reason');
  PERFORM t.as_user(a);
  PERFORM t.throws('B1 cannot report your own post', format($q$SELECT public.board_report_post(%L, 'spam')$q$, p1), 'own post');
  PERFORM t.su();
  PERFORM t.ok('B1 report row names the reporter, the author and the Board post',
    (SELECT reporter_id = b AND reported_user_id = a AND board_post_id = p1 AND status = 'pending' AND post_id IS NULL FROM public.content_reports WHERE id = rid));
END $$;

-- ===== 10. notifications =====
DO $$
DECLARE a uuid := t.u(1); b uuid := t.u(2); n int;
BEGIN
  PERFORM t.as_user(a);
  PERFORM t.ok('B1 alice sees her own notifications', t.count('select 1 from public.board_notifications') > 0);
  PERFORM t.ok('B1 alice sees only hers', NOT EXISTS (SELECT 1 FROM public.board_notifications WHERE user_id <> a));
  n := public.board_mark_notifications_read();
  PERFORM t.ok('B1 mark all read returns how many changed', n > 0);
  PERFORM t.ok('B1 nothing unread afterwards', t.count('select 1 from public.board_notifications where read_at is null') = 0);
  PERFORM t.as_user(b);
  PERFORM t.ok('B1 bob''s notifications were not touched by alice', t.count('select 1 from public.board_notifications where read_at is null') > 0);
  PERFORM t.throws('B1 cannot update notifications directly', $q$UPDATE public.board_notifications SET read_at = now()$q$, 'permission denied');
  PERFORM t.su();
END $$;

-- ===== 11. feeds, tags, search, trending, suggestions =====
DO $$
DECLARE a uuid := t.u(1); b uuid := t.u(2); c uuid := t.u(3); d uuid := t.u(4); e uuid := t.u(5); p1 uuid := t.get('p1')::uuid; q1 uuid := t.get('q1')::uuid;
        first_ts timestamptz; n int;
BEGIN
  PERFORM t.as_user(b);
  PERFORM t.ok('B1 Latest holds only top-level posts', NOT EXISTS (SELECT 1 FROM public.board_feed('latest', 50) f JOIN public.board_posts p ON p.id = f.post_id WHERE p.parent_id IS NOT NULL));
  PERFORM t.ok('B1 Latest is newest first', (SELECT bool_and(sort_at <= lag_ts) FROM (SELECT sort_at, lag(sort_at) OVER (ORDER BY ord) AS lag_ts FROM (SELECT f.*, row_number() OVER () AS ord FROM public.board_feed('latest', 50) f) z) y WHERE lag_ts IS NOT NULL));
  PERFORM t.ok('B1 the page size is capped at 50', (SELECT count(*) FROM public.board_feed('latest', 500)) <= 50);
  SELECT sort_at INTO first_ts FROM public.board_feed('latest', 5) ORDER BY sort_at DESC LIMIT 1 OFFSET 2;
  PERFORM t.ok('B1 paging with p_before returns only older posts', NOT EXISTS (SELECT 1 FROM public.board_feed('latest', 50, first_ts) WHERE sort_at >= first_ts));

  -- following: bob follows alice and carol
  PERFORM t.as_user(b);
  PERFORM t.ok('B1 Following starts with only bob''s own posts (he follows nobody yet)', NOT EXISTS (SELECT 1 FROM public.board_feed('following', 50) f JOIN public.board_posts p ON p.id = f.post_id WHERE p.author_id <> b));
  PERFORM t.works('B1 bob follows alice (existing follows table)', format($q$INSERT INTO public.follows(follower_id, following_id) VALUES (%L,%L)$q$, b, a));
  PERFORM t.works('B1 bob follows carol', format($q$INSERT INTO public.follows(follower_id, following_id) VALUES (%L,%L)$q$, b, c));
  PERFORM t.ok('B1 Following shows alice''s post', EXISTS (SELECT 1 FROM public.board_feed('following', 50) WHERE post_id = p1));
  PERFORM t.ok('B1 Following hides people bob does not follow', NOT EXISTS (SELECT 1 FROM public.board_feed('following', 50) f JOIN public.board_posts p ON p.id = f.post_id WHERE p.author_id IN (d, e)));
  PERFORM t.ok('B1 Following shows alice''s post once, marked reposted_by carol (carol reposted it later)', (SELECT count(*) FROM public.board_feed('following', 50) WHERE post_id = p1) = 1 AND (SELECT reposted_by FROM public.board_feed('following', 50) WHERE post_id = p1) = c);
  PERFORM t.ok('B1 Following has no replies', NOT EXISTS (SELECT 1 FROM public.board_feed('following', 50) f JOIN public.board_posts p ON p.id = f.post_id WHERE p.parent_id IS NOT NULL));
  PERFORM t.su();
  PERFORM set_config('request.jwt.claim.sub', '', false); PERFORM set_config('request.jwt.claim.role', 'anon', false); EXECUTE 'SET ROLE anon';
  PERFORM t.ok('B1 signed-out Following is empty', (SELECT count(*) FROM public.board_feed('following', 50)) = 0);
  PERFORM t.ok('B1 signed-out For You still works', (SELECT count(*) FROM public.board_feed('for_you', 50)) > 0);
  PERFORM t.su();

  -- For You: more real engagement ranks higher at similar age
  PERFORM t.as_user(e);
  PERFORM t.ok('B1 For You puts the engaged post above an unengaged older-or-equal one',
    (SELECT min(rn) FROM (SELECT post_id, row_number() OVER () AS rn FROM public.board_feed('for_you', 50)) z WHERE post_id = p1)
      < (SELECT min(rn) FROM (SELECT post_id, row_number() OVER () AS rn FROM public.board_feed('for_you', 50)) z WHERE post_id = t.get('pe')::uuid));
  PERFORM t.ok('B1 For You paging with offset gives different posts', (SELECT count(*) FROM public.board_feed('for_you', 5, NULL, 0) a1 JOIN public.board_feed('for_you', 5, NULL, 5) a2 USING (post_id)) = 0);
  PERFORM t.su();

  -- tags / search / trending / suggestions
  PERFORM t.as_user(d);
  PERFORM t.ok('B1 tag page finds posts (case-insensitive, # optional)', EXISTS (SELECT 1 FROM public.board_tag_posts('#BMN')) AND EXISTS (SELECT 1 FROM public.board_tag_posts('bmn')));
  PERFORM t.ok('B1 tag page respects visibility (dave blocked? no, alice visible after unblock)', EXISTS (SELECT 1 FROM public.board_tag_posts('edited')));
  PERFORM t.ok('B1 search finds a real word', EXISTS (SELECT 1 FROM public.board_search_posts('edited')));
  PERFORM t.ok('B1 search treats % literally (matches nothing)', NOT EXISTS (SELECT 1 FROM public.board_search_posts('%%')));
  PERFORM t.ok('B1 search ignores queries shorter than 2 characters', NOT EXISTS (SELECT 1 FROM public.board_search_posts('e')));
  PERFORM t.ok('B1 trending lists real tags with real counts', (SELECT posts FROM public.board_trending(72, 10) WHERE tag = 'bmn') >= 1);
  PERFORM t.ok('B1 suggestions exclude me', NOT EXISTS (SELECT 1 FROM public.board_suggested_people(20) WHERE user_id = d));
  PERFORM t.as_user(b);
  PERFORM t.ok('B1 suggestions exclude people bob already follows', NOT EXISTS (SELECT 1 FROM public.board_suggested_people(20) WHERE user_id IN (a, c)));
  PERFORM t.su();
  -- block hides a person from suggestions both ways
  INSERT INTO public.user_blocks(user_id, target_id, kind) VALUES (d, e, 'block') ON CONFLICT DO NOTHING;
  PERFORM t.as_user(e);
  PERFORM t.ok('B1 suggestions hide a blocked pair even when the block is the other way round', NOT EXISTS (SELECT 1 FROM public.board_suggested_people(20) WHERE user_id = d));
  PERFORM t.su();
  DELETE FROM public.user_blocks WHERE user_id = d AND target_id = e;
END $$;

-- ===== 12. cascade deletes keep counters equal to the real rows =====
DO $$
DECLARE m uuid := t.u(6); p1 uuid := t.get('p1')::uuid; before_likes int; before_replies int; mp uuid;
BEGIN
  PERFORM t.as_user(m);
  PERFORM public.board_set_like(p1, true);
  mp := public.board_create_post('mallory reply', '[]', p1);
  PERFORM t.su();
  before_likes := (SELECT like_count FROM public.board_posts WHERE id = p1);
  before_replies := (SELECT reply_count FROM public.board_posts WHERE id = p1);
  DELETE FROM public.profiles WHERE id = m;
  PERFORM t.ok('B1 deleting a profile removes her likes from the counter', (SELECT like_count FROM public.board_posts WHERE id = p1) = before_likes - 1);
  PERFORM t.ok('B1 deleting a profile removes her replies from the counter', (SELECT reply_count FROM public.board_posts WHERE id = p1) = before_replies - 1);
  PERFORM t.ok('B1 every counter equals the real rows', NOT EXISTS (
    SELECT 1 FROM public.board_posts p WHERE p.like_count <> (SELECT count(*) FROM public.board_likes l WHERE l.post_id = p.id)
       OR p.repost_count <> (SELECT count(*) FROM public.board_reposts r WHERE r.post_id = p.id)
       OR p.view_count <> (SELECT count(*) FROM public.board_views v WHERE v.post_id = p.id)
       OR p.reply_count <> (SELECT count(*) FROM public.board_posts c WHERE c.parent_id = p.id AND c.deleted_at IS NULL)
       OR p.quote_count <> (SELECT count(*) FROM public.board_posts c WHERE c.quote_id = p.id AND c.deleted_at IS NULL)));
END $$;

-- ===== 13. the video feed is untouched =====
DO $$
BEGIN
  PERFORM t.su();
  PERFORM t.ok('B1 Board wrote nothing into the video posts table', (SELECT count(*) FROM public.posts) = 0);
  PERFORM t.ok('B1 no trigger on the video posts table mentions board', NOT EXISTS (SELECT 1 FROM pg_trigger tg WHERE tg.tgrelid = 'public.posts'::regclass AND NOT tg.tgisinternal AND pg_get_triggerdef(tg.oid) ILIKE '%board%'));
  PERFORM t.ok('B1 no policy on the video posts table mentions board', NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='posts' AND (qual ILIKE '%board%' OR with_check ILIKE '%board%' OR policyname ILIKE '%board%')));
END $$;
