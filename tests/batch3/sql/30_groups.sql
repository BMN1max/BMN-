-- ===== M2: groups =====
DO $$
DECLARE a uuid := t.u(1); b uuid := t.u(2); c uuid := t.u(3); d uuid := t.u(4); e uuid := t.u(5); m uuid := t.u(6);
        g uuid; g2 uuid; r record; n int;
BEGIN
  PERFORM t.su();
  UPDATE public.user_settings SET who_can_message='everyone' WHERE user_id=c;
  DELETE FROM public.user_blocks;
  DELETE FROM public.message_requests;
  -- erin does not accept group invites
  INSERT INTO public.bmn_messaging_settings(user_id, group_invites) VALUES (e,'nobody') ON CONFLICT (user_id) DO UPDATE SET group_invites='nobody';

  PERFORM t.as_user(a);
  g := public.bmn_create_group('Team BMN', 'Plans and chat', ARRAY[b, c, e, a], NULL);
  PERFORM t.set('g1', g::text);
  PERFORM t.ok('M2 create: group created', g IS NOT NULL);
  PERFORM t.ok('M2 create: creator is owner', public.bmn_group_role(g) = 'owner');
  PERFORM t.ok('M2 create: invitees added, "nobody" invitee skipped, creator not duplicated', (SELECT count(*) FROM public.group_members WHERE group_id = g) = 3);
  PERFORM t.ok('M2 create: roster readable by a member', t.count(format('select 1 from public.group_members where group_id=%L', g)) = 3);
  PERFORM t.throws('M2 create: empty name rejected', $q$SELECT public.bmn_create_group('   ')$q$, 'Group name');
  PERFORM t.throws('M2 create: 81-char name rejected', format($q$SELECT public.bmn_create_group(%L)$q$, repeat('x', 81)), 'Group name');
  PERFORM t.as_user(m);
  PERFORM t.as_user(b);

  -- visibility
  PERFORM t.as_user(m);
  PERFORM t.ok('M2 outsider cannot see the group', t.count(format('select 1 from public.group_chats where id=%L', g)) = 0);
  PERFORM t.ok('M2 outsider cannot see roster', t.count(format('select 1 from public.group_members where group_id=%L', g)) = 0);
  PERFORM t.ok('M2 outsider cannot read group messages', t.count(format('select 1 from public.group_messages where group_id=%L', g)) = 0);
  PERFORM t.throws('M2 outsider cannot post', format($q$INSERT INTO public.group_messages(group_id,sender_id,content) VALUES (%L,%L,'hack')$q$, g, m), 'row-level security');
  PERFORM t.throws('M2 direct insert into group_members is blocked for users', format($q$INSERT INTO public.group_members(group_id,user_id,role) VALUES (%L,%L,'owner')$q$, g, m), '');
  PERFORM t.works('M2 direct update of group_chats by a user runs but matches no rows', format($q$UPDATE public.group_chats SET name='pwned' WHERE id=%L$q$, g));
  PERFORM t.ok('M2 group name was not changed by the direct update', t.q(format('select name from public.group_chats where id=%L', g)) = 'Team BMN');

  -- posting
  PERFORM t.as_user(b);
  PERFORM t.works('M2 member posts text', format($q$INSERT INTO public.group_messages(group_id,sender_id,content) VALUES (%L,%L,'hello team')$q$, g, b));
  PERFORM t.works('M2 member posts image message', format($q$INSERT INTO public.group_messages(group_id,sender_id,content) VALUES (%L,%L,'bmn-img:groups/x.jpg')$q$, g, b));
  PERFORM t.throws('M2 cannot post as another member', format($q$INSERT INTO public.group_messages(group_id,sender_id,content) VALUES (%L,%L,'spoof')$q$, g, a), 'row-level security');
  PERFORM t.throws('M2 cannot forge a system message', format($q$INSERT INTO public.group_messages(group_id,sender_id,content,kind) VALUES (%L,%L,'bmn-sys:created','system')$q$, g, b), 'row-level security');
  PERFORM t.throws('M2 empty message rejected', format($q$INSERT INTO public.group_messages(group_id,sender_id,content) VALUES (%L,%L,'   ')$q$, g, b), 'check');
  PERFORM t.works('M2 forged edited/unsent/forward fields are cleared on insert', format($q$INSERT INTO public.group_messages(group_id,sender_id,content,edited_at,unsent_at,forwarded_from_name) VALUES (%L,%L,'forge',now(),now(),'Mallory')$q$, g, b));
  SELECT (edited_at IS NULL AND unsent_at IS NULL AND forwarded_from_name IS NULL) AS fine INTO STRICT r FROM public.group_messages WHERE content='forge';
  PERFORM t.ok('M2 forged fields really were cleared', r.fine);
  -- replies
  PERFORM t.set('gm1', (SELECT id::text FROM public.group_messages WHERE group_id=g AND content='hello team'));
  PERFORM t.as_user(c);
  PERFORM t.ok('M2 member reads group history', t.count(format('select 1 from public.group_messages where group_id=%L and kind=''user''', g)) >= 3);
  PERFORM t.works('M2 member replies in-group', format($q$INSERT INTO public.group_messages(group_id,sender_id,content,reply_to_id) VALUES (%L,%L,'hi bob',%L)$q$, g, c, t.get('gm1')::uuid));
  PERFORM t.ok('M2 reply notification created for the replied-to member', t.q(format($q$select count(*) from public.notifications where user_id=%L and type='group_reply'$q$, b)) = '1');
  PERFORM t.su();
  PERFORM t.as_user(a);
  g2 := public.bmn_create_group('Other', NULL, ARRAY[]::uuid[]);
  PERFORM t.throws('M2 reply target from another group rejected', format($q$INSERT INTO public.group_messages(group_id,sender_id,content,reply_to_id) VALUES (%L,%L,'x',%L)$q$, g2, a, t.get('gm1')::uuid), 'Reply target');

  -- posting permission setting
  PERFORM t.as_user(b);
  PERFORM t.throws('M2 member cannot change group settings', format($q$SELECT public.bmn_update_group(%L, p_only_admins_post => true)$q$, g), 'admins');
  PERFORM t.as_user(a);
  PERFORM t.works('M2 owner restricts posting to admins', format($q$SELECT public.bmn_update_group(%L, p_only_admins_post => true)$q$, g));
  PERFORM t.as_user(b);
  PERFORM t.throws('M2 admins-only: member cannot post', format($q$INSERT INTO public.group_messages(group_id,sender_id,content) VALUES (%L,%L,'x')$q$, g, b), 'row-level security');
  PERFORM t.as_user(a);
  PERFORM t.works('M2 admins-only: owner can post', format($q$INSERT INTO public.group_messages(group_id,sender_id,content) VALUES (%L,%L,'announcement')$q$, g, a));
  PERFORM t.works('M2 owner reopens posting + edits info', format($q$SELECT public.bmn_update_group(%L, 'Team BMN 2', 'new desc', 'groups/av.jpg', false, false)$q$, g));
  PERFORM t.ok('M2 group info updated', (SELECT name||'|'||description||'|'||avatar_url FROM public.group_chats WHERE id=g) = 'Team BMN 2|new desc|groups/av.jpg');
  PERFORM t.ok('M2 rename posted a system message', (SELECT count(*) FROM public.group_messages WHERE group_id=g AND content='bmn-sys:renamed:Team BMN 2') = 1);

  -- adding members
  PERFORM t.as_user(b);
  PERFORM t.throws('M2 member cannot add when members_can_add=false', format($q$SELECT public.bmn_add_group_members(%L, ARRAY[%L]::uuid[])$q$, g, d), 'cannot add');
  PERFORM t.as_user(a);
  PERFORM t.ok('M2 admin/owner adds a member', public.bmn_add_group_members(g, ARRAY[d]) = 1);
  PERFORM t.ok('M2 adding an existing member adds nobody', public.bmn_add_group_members(g, ARRAY[d, b]) = 0);
  PERFORM t.ok('M2 member with group_invites=nobody is not added', public.bmn_add_group_members(g, ARRAY[e]) = 0);
  PERFORM t.ok('M2 added member received a notification', t.q(format($q$select count(*) from public.notifications where user_id=%L and type='group_added'$q$, d)) = '1');
  PERFORM t.su();
  INSERT INTO public.user_blocks(user_id, target_id, kind) VALUES (m, a, 'block');
  PERFORM t.as_user(a);
  PERFORM t.ok('M2 users who blocked the adder are skipped', public.bmn_add_group_members(g, ARRAY[m]) = 0);
  PERFORM t.su();
  DELETE FROM public.user_blocks WHERE user_id = m;
END $$;
SELECT t.su();
DO $$
DECLARE a uuid := t.u(1); b uuid := t.u(2); c uuid := t.u(3); d uuid := t.u(4); e uuid := t.u(5); m uuid := t.u(6);
        g uuid := t.get('g1')::uuid; r record; n int;
BEGIN
  PERFORM t.as_user(a);
  PERFORM t.works('M2 owner lets members add', format($q$SELECT public.bmn_update_group(%L, p_members_can_add => true)$q$, g));
  PERFORM t.as_user(b);
  PERFORM t.ok('M2 plain member can add when allowed', public.bmn_add_group_members(g, ARRAY[m]) = 1);
  PERFORM t.as_user(a);
  PERFORM t.works('M2 owner turns member-adding off', format($q$SELECT public.bmn_update_group(%L, p_members_can_add => false)$q$, g));

END $$;
SELECT t.su();
-- (separate transaction so created_at > joined_at, as in real use)
DO $$
DECLARE b uuid := t.u(2); m uuid := t.u(6); g uuid := t.get('g1')::uuid;
BEGIN
  PERFORM t.as_user(m);
  PERFORM t.ok('M2 new member sees only messages after joining', t.count(format('select 1 from public.group_messages where group_id=%L and kind=''user''', g)) = 0);
  PERFORM t.as_user(b);
  INSERT INTO public.group_messages(group_id,sender_id,content) VALUES (g, b, 'after mallory joined');
END $$;
SELECT t.su();
DO $$
DECLARE a uuid := t.u(1); b uuid := t.u(2); c uuid := t.u(3); d uuid := t.u(4); m uuid := t.u(6); g uuid := t.get('g1')::uuid; r record; n int;
BEGIN
  PERFORM t.as_user(m);
  PERFORM t.ok('M2 new member sees new messages', t.count(format('select 1 from public.group_messages where group_id=%L and kind=''user''', g)) = 1);

  -- removal rules
  PERFORM t.as_user(b);
  PERFORM t.throws('M2 member cannot remove another member', format($q$SELECT public.bmn_remove_group_member(%L,%L)$q$, g, c), 'permission');
  PERFORM t.throws('M2 member cannot change roles', format($q$SELECT public.bmn_set_group_role(%L,%L,'admin')$q$, g, c), 'owner');
  PERFORM t.as_user(a);
  PERFORM t.works('M2 owner promotes bob to admin', format($q$SELECT public.bmn_set_group_role(%L,%L,'admin')$q$, g, b));
  PERFORM t.as_user(b);
  PERFORM t.works('M2 admin removes a plain member (mallory)', format($q$SELECT public.bmn_remove_group_member(%L,%L)$q$, g, m));
  PERFORM t.as_user(m);
  PERFORM t.ok('M2 removed member can no longer read the group', t.count(format('select 1 from public.group_messages where group_id=%L', g)) = 0);
  PERFORM t.ok('M2 removed member can no longer see the group', t.count(format('select 1 from public.group_chats where id=%L', g)) = 0);
  PERFORM t.throws('M2 removed member cannot post', format($q$INSERT INTO public.group_messages(group_id,sender_id,content) VALUES (%L,%L,'x')$q$, g, m), 'row-level security');
  PERFORM t.as_user(a);
  PERFORM t.works('M2 owner promotes carol to admin', format($q$SELECT public.bmn_set_group_role(%L,%L,'admin')$q$, g, c));
  PERFORM t.as_user(b);
  PERFORM t.throws('M2 admin cannot remove another admin', format($q$SELECT public.bmn_remove_group_member(%L,%L)$q$, g, c), 'permission');
  PERFORM t.throws('M2 admin cannot remove the owner', format($q$SELECT public.bmn_remove_group_member(%L,%L)$q$, g, a), 'permission');
  PERFORM t.as_user(a);
  PERFORM t.works('M2 owner removes an admin', format($q$SELECT public.bmn_remove_group_member(%L,%L)$q$, g, c));

  -- unread counts + inbox
  PERFORM t.as_user(a);
  PERFORM t.works('M2 inbox runs', 'SELECT * FROM public.bmn_group_inbox()');
  SELECT * INTO r FROM public.bmn_group_inbox() WHERE group_id = g;
  PERFORM t.ok('M2 inbox returns the group with a preview', r.group_id = g AND r.last_message_content IS NOT NULL AND r.my_role = 'owner');
  PERFORM t.as_user(d);
  SELECT unread_count INTO n FROM public.bmn_group_inbox() WHERE group_id = g;
  PERFORM t.ok('M2 unread count is only messages from others after last read', n >= 1, 'unread=' || n);
  PERFORM public.bmn_mark_group_read(g);
END $$;
SELECT t.su();
DO $$
DECLARE b uuid := t.u(2); d uuid := t.u(4); g uuid := t.get('g1')::uuid; n int;
BEGIN
  PERFORM t.as_user(d);
  SELECT unread_count INTO n FROM public.bmn_group_inbox() WHERE group_id = g;
  PERFORM t.ok('M2 mark-read clears unread', n = 0, 'unread=' || n);
  PERFORM t.as_user(b);
  INSERT INTO public.group_messages(group_id,sender_id,content) VALUES (g, b, 'new one');
END $$;
SELECT t.su();
DO $$
DECLARE b uuid := t.u(2); d uuid := t.u(4); m uuid := t.u(6); g uuid := t.get('g1')::uuid; n int;
BEGIN
  PERFORM t.as_user(d);
  SELECT unread_count INTO n FROM public.bmn_group_inbox() WHERE group_id = g;
  PERFORM t.ok('M2 new message raises unread to 1', n = 1, 'unread=' || n);
  PERFORM t.as_user(b);
  PERFORM public.bmn_mark_group_read(g);
END $$;
SELECT t.su();
DO $$
DECLARE b uuid := t.u(2); m uuid := t.u(6); g uuid := t.get('g1')::uuid; n int;
BEGIN
  PERFORM t.as_user(b);
  INSERT INTO public.group_messages(group_id,sender_id,content) VALUES (g, b, 'my own');
  SELECT unread_count INTO n FROM public.bmn_group_inbox() WHERE group_id = g;
  PERFORM t.ok('M2 own messages never count as unread', n = 0, 'unread=' || n);
  PERFORM t.as_user(m);
  PERFORM t.ok('M2 non-member inbox excludes the group', (SELECT count(*) FROM public.bmn_group_inbox() WHERE group_id = g) = 0);
END $$;
SELECT t.su();

-- ownership transfer, leaving, member cap, disappearing timer
DO $$
DECLARE a uuid := t.u(1); b uuid := t.u(2); c uuid := t.u(3); d uuid := t.u(4);
        g uuid := t.get('g1')::uuid; g3 uuid; n int;
BEGIN
  PERFORM t.as_user(a);
  PERFORM t.throws('M2 cannot give role to yourself', format($q$SELECT public.bmn_set_group_role(%L,%L,'member')$q$, g, a), 'someone else');
  PERFORM t.works('M2 owner transfers ownership to bob', format($q$SELECT public.bmn_set_group_role(%L,%L,'owner')$q$, g, b));
  PERFORM t.ok('M2 exactly one owner after transfer', t.q(format('select count(*) from public.group_members where group_id=%L and role=''owner''', g)) = '1');
  PERFORM t.ok('M2 old owner became admin', t.q(format('select role from public.group_members where group_id=%L and user_id=%L', g, a)) = 'admin');
  PERFORM t.as_user(b);
  PERFORM t.works('M2 owner leaves: next admin becomes owner', format($q$SELECT public.bmn_leave_group(%L)$q$, g));
  PERFORM t.ok('M2 ownership moved to the remaining admin', t.q(format('select role from public.group_members where group_id=%L and user_id=%L', g, a)) = 'owner');
  PERFORM t.ok('M2 leaver is no longer a member', t.q(format('select count(*) from public.group_members where group_id=%L and user_id=%L', g, b)) = '0');
  PERFORM t.as_user(d);
  PERFORM t.works('M2 member leaves', format($q$SELECT public.bmn_leave_group(%L)$q$, g));
  PERFORM t.as_user(a);
  PERFORM t.works('M2 last member leaves', format($q$SELECT public.bmn_leave_group(%L)$q$, g));
  PERFORM t.su();
  PERFORM t.ok('M2 last leave closes the group but keeps history', (SELECT closed_at IS NOT NULL FROM public.group_chats WHERE id=g) AND (SELECT count(*) FROM public.group_messages WHERE group_id=g) > 0);
  PERFORM t.as_user(a);
  PERFORM t.ok('M2 closed group disappears from inbox', (SELECT count(*) FROM public.bmn_group_inbox() WHERE group_id=g) = 0);

  -- member cap from config
  PERFORM t.su();
  UPDATE public.bmn_messaging_config SET value = 3 WHERE key = 'group_max_members';
  PERFORM t.as_user(a);
  g3 := public.bmn_create_group('Cap test', NULL, ARRAY[b, c, d]);
  PERFORM t.ok('M2 member cap enforced on create (cap 3 = owner + 2)', (SELECT count(*) FROM public.group_members WHERE group_id=g3) = 3);
  PERFORM t.ok('M2 member cap enforced on add', public.bmn_add_group_members(g3, ARRAY[t.u(5), t.u(6)]) = 0);
  PERFORM t.su();
  UPDATE public.bmn_messaging_config SET value = 200 WHERE key = 'group_max_members';

  -- disappearing timer
  PERFORM t.as_user(a);
  PERFORM t.works('M2 admin sets disappearing timer', format($q$SELECT public.bmn_update_group(%L, p_disappearing_seconds => 3600)$q$, g3));
  INSERT INTO public.group_messages(group_id,sender_id,content) VALUES (g3, a, 'vanishing');
  PERFORM t.ok('M2 messages in a timed group get expires_at', (SELECT expires_at BETWEEN now() + interval '59 minutes' AND now() + interval '61 minutes' FROM public.group_messages WHERE content='vanishing'));
  PERFORM t.throws('M2 negative timer rejected', format($q$SELECT public.bmn_update_group(%L, p_disappearing_seconds => -5)$q$, g3), 'Invalid timer');
END $$;
SELECT t.su();
