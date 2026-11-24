-- ===== M1: blocks, settings, requests, presence masking =====
DO $$
DECLARE a uuid := t.u(1); b uuid := t.u(2); c uuid := t.u(3); d uuid := t.u(4); e uuid := t.u(5);
BEGIN
  -- baseline behaviour first: plain 1:1 send still works
  PERFORM t.as_user(a);
  PERFORM t.works('M1 baseline: alice can send to bob', format($q$INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (%L,%L,'hi')$q$, a, b));
  PERFORM t.as_user(b);
  PERFORM t.works('M1 baseline: bob can reply', format($q$INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (%L,%L,'yo')$q$, b, a));
  PERFORM t.throws('M1 baseline: cannot send as someone else', format($q$INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (%L,%L,'spoof')$q$, a, c));

  -- blocks
  PERFORM t.as_user(a);
  PERFORM t.works('M1 alice blocks bob', format($q$INSERT INTO public.user_blocks(user_id,target_id,kind) VALUES (%L,%L,'block')$q$, a, b));
  PERFORM t.throws('M1 cannot block as someone else', format($q$INSERT INTO public.user_blocks(user_id,target_id,kind) VALUES (%L,%L,'block')$q$, c, d), 'row-level security');
  PERFORM t.throws('M1 blocked: alice cannot send to bob', format($q$INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (%L,%L,'x')$q$, a, b), 'row-level security');
  PERFORM t.as_user(b);
  PERFORM t.throws('M1 blocked: bob cannot send to alice', format($q$INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (%L,%L,'x')$q$, b, a), 'row-level security');
  PERFORM t.ok('M1 blocked user cannot see the block row', t.count('select 1 from public.user_blocks') = 0);
  PERFORM t.works('M1 bob can still message carol', format($q$INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (%L,%L,'hello c')$q$, b, c));
  PERFORM t.as_user(a);
  PERFORM t.ok('M1 blocker sees own block', t.count('select 1 from public.user_blocks') = 1);
  PERFORM t.works('M1 alice unblocks bob', format($q$DELETE FROM public.user_blocks WHERE user_id=%L AND target_id=%L$q$, a, b));
  PERFORM t.works('M1 after unblock alice can send again', format($q$INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (%L,%L,'back')$q$, a, b));

  -- settings
  PERFORM t.as_user(c);
  PERFORM t.works('M1 carol sets who_can_message in the EXISTING user_settings', format($q$INSERT INTO public.user_settings(user_id,who_can_message,read_receipts) VALUES (%L,'followers',false)$q$, c));
  PERFORM t.throws('M1 cannot write another user''s user_settings', format($q$INSERT INTO public.user_settings(user_id) VALUES (%L)$q$, d), 'row-level security');
  PERFORM t.works('M1 carol creates own extra settings', format($q$INSERT INTO public.bmn_messaging_settings(user_id,typing_indicator) VALUES (%L,true)$q$, c));
  PERFORM t.throws('M1 cannot create settings for another user', format($q$INSERT INTO public.bmn_messaging_settings(user_id) VALUES (%L)$q$, d), 'row-level security');
  PERFORM t.throws('M1 settings value constraint', format($q$UPDATE public.bmn_messaging_settings SET last_seen='everybody' WHERE user_id=%L$q$, c), 'check');
  PERFORM t.as_user(d);
  PERFORM t.ok('M1 other users cannot read carol settings', t.count(format('select 1 from public.bmn_messaging_settings where user_id=%L', c)) = 0);

  -- message requests: carol only accepts followed people / accepted requests
  PERFORM t.as_user(d);
  PERFORM t.works('M1 request: first message from stranger is allowed', format($q$INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (%L,%L,'hi carol')$q$, d, c));
  PERFORM t.throws('M1 request: second message blocked while pending', format($q$INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (%L,%L,'again')$q$, d, c), 'row-level security');
  PERFORM t.ok('M1 request: pending row visible to requester', t.count('select 1 from public.message_requests where status=''pending''') = 1);
  PERFORM t.as_user(c);
  PERFORM t.ok('M1 request: recipient sees pending request', t.count(format('select 1 from public.message_requests where requester_id=%L and status=''pending''', d)) = 1);
  PERFORM t.as_user(e);
  PERFORM t.throws('M1 request: stranger cannot respond to someone else''s request', format($q$SELECT public.bmn_respond_message_request(%L, true)$q$, d), 'No such request');
  PERFORM t.as_user(c);
  PERFORM t.works('M1 request: carol accepts dave', format($q$SELECT public.bmn_respond_message_request(%L, true)$q$, d));
  PERFORM t.as_user(d);
  PERFORM t.works('M1 request: after accept dave can send', format($q$INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (%L,%L,'thanks')$q$, d, c));
  PERFORM t.as_user(e);
  PERFORM t.works('M1 request: erin first message', format($q$INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (%L,%L,'hello')$q$, e, c));
  PERFORM t.as_user(c);
  PERFORM t.works('M1 request: carol declines erin', format($q$SELECT public.bmn_respond_message_request(%L, false)$q$, e));
  PERFORM t.as_user(e);
  PERFORM t.throws('M1 request: declined sender cannot send', format($q$INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (%L,%L,'pls')$q$, e, c), 'row-level security');
  PERFORM t.as_user(c);
  PERFORM t.works('M1 request: carol can write to erin first', format($q$INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (%L,%L,'ok fine')$q$, c, e));
  PERFORM t.as_user(e);
  PERFORM t.works('M1 request: replying to someone who wrote you is allowed', format($q$INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (%L,%L,'thx')$q$, e, c));
  -- following lifts the gate
  PERFORM t.as_user(c);
  PERFORM t.works('M1 carol follows mallory', format($q$INSERT INTO public.follows(follower_id,following_id) VALUES (%L,%L)$q$, c, t.u(6)));
  PERFORM t.as_user(t.u(6));
  PERFORM t.works('M1 followed user can message carol repeatedly', format($q$INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (%L,%L,'1'),(%L,%L,'2')$q$, t.u(6), c, t.u(6), c));
END $$;
SELECT t.su();

-- presence / privacy masking
DO $$
DECLARE a uuid := t.u(1); b uuid := t.u(2); c uuid := t.u(3); r record;
BEGIN
  PERFORM t.su();
  UPDATE public.profiles SET last_seen_at = now() WHERE id IN (b, c);
  INSERT INTO public.bmn_messaging_settings(user_id, last_seen, typing_indicator)
    VALUES (b, 'nobody', false) ON CONFLICT (user_id) DO UPDATE SET last_seen='nobody', typing_indicator=false;
  INSERT INTO public.user_settings(user_id, read_receipts, show_activity_status)
    VALUES (b, false, true) ON CONFLICT (user_id) DO UPDATE SET read_receipts=false, show_activity_status=true;
  PERFORM t.as_user(a);
  SELECT * INTO r FROM public.bmn_peer_flags(b);
  PERFORM t.ok('M1 last_seen=nobody hides last seen', r.last_seen_at IS NULL);
  PERFORM t.ok('M1 last_seen=nobody also hides online status', r.online = false);
  PERFORM t.ok('M1 read receipts flag reported as off', r.read_receipts = false);
  PERFORM t.ok('M1 typing indicator flag reported as off', r.typing_indicator = false);
  PERFORM t.su();
  UPDATE public.bmn_messaging_settings SET last_seen='followers', typing_indicator=true WHERE user_id = b;
  PERFORM t.as_user(a);
  SELECT * INTO r FROM public.bmn_peer_flags(b);
  PERFORM t.ok('M1 last_seen=followers hides from non-followed viewer', r.last_seen_at IS NULL);
  PERFORM t.as_service();   -- the follow trigger needs an authenticated or service caller
  INSERT INTO public.follows(follower_id, following_id) VALUES (b, a) ON CONFLICT DO NOTHING;
  PERFORM t.su();
  PERFORM t.as_user(a);
  SELECT * INTO r FROM public.bmn_peer_flags(b);
  PERFORM t.ok('M1 last_seen=followers shows to a viewer the peer follows', r.last_seen_at IS NOT NULL);
  PERFORM t.ok('M1 recently active peer shows online', r.online = true);
  PERFORM t.su();
  UPDATE public.profiles SET last_seen_at = now() - interval '1 hour' WHERE id = b;
  PERFORM t.as_user(a);
  SELECT * INTO r FROM public.bmn_peer_flags(b);
  PERFORM t.ok('M1 stale last_seen is not online', r.online = false);
  PERFORM t.su();
  INSERT INTO public.user_blocks(user_id, target_id, kind) VALUES (b, a, 'block');
  PERFORM t.as_user(a);
  SELECT * INTO r FROM public.bmn_peer_flags(b);
  PERFORM t.ok('M1 blocked viewer gets no presence and blocked=true', r.blocked = true AND r.last_seen_at IS NULL AND r.online = false);
  PERFORM t.su();
  DELETE FROM public.user_blocks WHERE user_id = b AND target_id = a;
  -- service role bypasses RLS: documented limitation, server.js must check bmn_can_message itself
  INSERT INTO public.user_blocks(user_id, target_id, kind) VALUES (a, b, 'block');
  PERFORM t.as_service();
  PERFORM t.works('M1 NOTE service_role bypasses the restrictive policy (server must call bmn_can_message)', format($q$INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (%L,%L,'svc')$q$, b, a));
  PERFORM t.ok('M1 bmn_can_message() reports the block for the server', public.bmn_can_message(b, a) = false);
  PERFORM t.su();
  DELETE FROM public.user_blocks WHERE user_id = a AND target_id = b;
END $$;
SELECT t.su();

-- ===== M1 additions after the production audit: reuse of user_blocks / user_settings =====
DO $$
DECLARE a uuid := t.u(1); b uuid := t.u(2); e uuid := t.u(5); r record;
BEGIN
  PERFORM t.su();
  DELETE FROM public.user_blocks; DELETE FROM public.message_requests; DELETE FROM public.messages;
  -- a pre-existing production "mute" / "restrict" row must NOT block messaging
  INSERT INTO public.user_blocks(user_id,target_id,kind) VALUES (a,b,'mute'),(a,b,'restrict');
  PERFORM t.ok('M1 mute/restrict rows do not count as a block', public.bmn_is_blocked_between(a,b) = false);
  PERFORM t.as_user(b);
  PERFORM t.works('M1 mute row: bob can still message alice', format($q$INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (%L,%L,'still ok')$q$, b, a));
  PERFORM t.su(); DELETE FROM public.user_blocks;
  -- who_can_message aliases
  UPDATE public.user_settings SET who_can_message='following' WHERE user_id=(SELECT t.u(3));
  PERFORM t.ok('M1 who_can_message=following behaves like followers', public.bmn_msg_mode(t.u(3)) = 'followers');
  PERFORM t.ok('M1 unknown who_can_message value behaves like everyone', (SELECT public.bmn_msg_mode(t.u(4))) = 'everyone');
  INSERT INTO public.user_settings(user_id, who_can_message) VALUES (e, 'nobody') ON CONFLICT (user_id) DO UPDATE SET who_can_message='nobody';
  PERFORM t.as_user(a);
  PERFORM t.throws('M1 who_can_message=nobody blocks a stranger', format($q$INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (%L,%L,'hi')$q$, a, e), 'row-level security');
  PERFORM t.as_service();
  INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (e, a, 'erin writes first');
  PERFORM t.su();
  PERFORM t.as_user(a);
  PERFORM t.works('M1 who_can_message=nobody still allows replies to someone they wrote to', format($q$INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (%L,%L,'reply')$q$, a, e));
  -- show_activity_status=false hides presence even when last_seen audience is everyone
  PERFORM t.su();
  UPDATE public.profiles SET last_seen_at = now() WHERE id = b;
  DELETE FROM public.bmn_messaging_settings WHERE user_id = b;
  INSERT INTO public.user_settings(user_id, show_activity_status) VALUES (b, false) ON CONFLICT (user_id) DO UPDATE SET show_activity_status=false;
  PERFORM t.as_user(a);
  SELECT * INTO r FROM public.bmn_peer_flags(b);
  PERFORM t.ok('M1 show_activity_status=false hides online and last seen', r.online = false AND r.last_seen_at IS NULL);
  PERFORM t.su();
  UPDATE public.user_settings SET show_activity_status=true WHERE user_id = b;
  PERFORM t.as_user(a);
  SELECT * INTO r FROM public.bmn_peer_flags(b);
  PERFORM t.ok('M1 show_activity_status=true shows online again', r.online = true);
  PERFORM t.su();
END $$;
SELECT t.su();
