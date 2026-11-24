-- ===== M3: message actions (DM + group) =====
DO $$
DECLARE a uuid := t.u(1); b uuid := t.u(2); c uuid := t.u(3); d uuid := t.u(4); m uuid := t.u(6);
        dm uuid; dm2 uuid; dm3 uuid; g uuid; gm uuid; gm2 uuid; r record; res text; rid uuid; nid uuid;
BEGIN
  PERFORM t.su();
  UPDATE public.user_settings SET who_can_message='everyone';
  DELETE FROM public.user_blocks;
  PERFORM t.as_user(a);
  INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (a,b,'original text') RETURNING id INTO dm;
  PERFORM t.set('dm', dm::text);
  INSERT INTO public.messages(sender_id,recipient_id,content,reply_to_id) VALUES (a,b,'a reply',dm) RETURNING id INTO dm2;
  PERFORM t.ok('M3 reply: stored with reply_to_id', (SELECT reply_to_id FROM public.messages WHERE id = dm2) = dm);
  PERFORM t.throws('M3 reply: cannot reply to a message from another conversation', format($q$INSERT INTO public.messages(sender_id,recipient_id,content,reply_to_id) VALUES (%L,%L,'x',%L)$q$, a, c, dm), 'Reply target');
  PERFORM t.works('M3 forged edited_at/unsent_at/forwarded on insert accepted but cleared', format($q$INSERT INTO public.messages(sender_id,recipient_id,content,edited_at,unsent_at,expires_at,forwarded_from_name) VALUES (%L,%L,'forge',now(),now(),now(),'Fake')$q$, a, b));
  SELECT (edited_at IS NULL AND unsent_at IS NULL AND expires_at IS NULL AND forwarded_from_name IS NULL) AS fine INTO STRICT r FROM public.messages WHERE content='forge';
  PERFORM t.ok('M3 forged fields really were cleared', r.fine);
  PERFORM t.works('M3 direct UPDATE of a message by a user is accepted but matches no rows (no UPDATE policy)', format($q$UPDATE public.messages SET content='hacked' WHERE id=%L$q$, dm));
  PERFORM t.ok('M3 direct UPDATE changed nothing', (SELECT content FROM public.messages WHERE id=dm) = 'original text');

  -- edit
  PERFORM t.as_user(b);
  PERFORM t.throws('M3 edit: recipient cannot edit', format($q$SELECT public.bmn_edit_message('dm',%L,'changed')$q$, dm), 'own messages');
  PERFORM t.as_user(m);
  PERFORM t.throws('M3 edit: outsider cannot edit', format($q$SELECT public.bmn_edit_message('dm',%L,'changed')$q$, dm), 'not found');
  PERFORM t.as_user(a);
  PERFORM t.ok('M3 edit: sender edits', public.bmn_edit_message('dm', dm, 'edited text') IS NOT NULL);
  PERFORM t.ok('M3 edit: content and edited_at updated', (SELECT content = 'edited text' AND edited_at IS NOT NULL FROM public.messages WHERE id = dm));
  PERFORM t.ok('M3 edit: history row kept for the sender', t.count(format('select 1 from public.message_edits where message_id=%L', dm)) = 1);
  PERFORM t.as_user(b);
  PERFORM t.ok('M3 edit: recipient cannot read edit history', t.count(format('select 1 from public.message_edits where message_id=%L', dm)) = 0);
  PERFORM t.ok('M3 edit: recipient sees the edited text and indicator', (SELECT content = 'edited text' AND edited_at IS NOT NULL FROM public.messages WHERE id = dm));
  PERFORM t.as_user(a);
  PERFORM t.ok('M3 edit: unchanged text is a no-op', public.bmn_edit_message('dm', dm, 'edited text') IS NULL);
  PERFORM t.throws('M3 edit: empty rejected', format($q$SELECT public.bmn_edit_message('dm',%L,'  ')$q$, dm), 'length');
  PERFORM t.throws('M3 edit: cannot turn text into a fake media message', format($q$SELECT public.bmn_edit_message('dm',%L,'bmn-img:evil.png')$q$, dm), 'Invalid message');
  INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (a,b,'bmn-img:dm/pic.jpg') RETURNING id INTO dm3;
  PERFORM t.throws('M3 edit: media messages are not editable', format($q$SELECT public.bmn_edit_message('dm',%L,'text now')$q$, dm3), 'Only text');
  PERFORM t.su();
  UPDATE public.messages SET created_at = now() - interval '3 days' WHERE id = dm2;
  PERFORM t.as_user(a);
  PERFORM t.throws('M3 edit: window expired', format($q$SELECT public.bmn_edit_message('dm',%L,'late')$q$, dm2), 'window');
  PERFORM t.throws('M3 unsend: window expired', format($q$SELECT public.bmn_unsend_message('dm',%L)$q$, dm2), 'window');

  -- reactions
  PERFORM t.as_user(b);
  PERFORM t.ok('M3 react: add', public.bmn_toggle_reaction('dm', dm, '👍') = 'added');
  PERFORM t.ok('M3 react: change', public.bmn_toggle_reaction('dm', dm, '❤️') = 'changed');
  PERFORM t.ok('M3 react: still one reaction per user', t.q(format('select count(*) from public.message_reactions where message_id=%L and user_id=%L', dm, b)) = '1');
  PERFORM t.as_user(a);
  PERFORM t.ok('M3 react: sender can see the recipient reaction', t.count(format('select 1 from public.message_reactions where message_id=%L', dm)) = 1);
  PERFORM t.ok('M3 react: second participant adds own', public.bmn_toggle_reaction('dm', dm, '😂') = 'added');
  PERFORM t.as_user(m);
  PERFORM t.ok('M3 react: outsider cannot see reactions', t.count(format('select 1 from public.message_reactions where message_id=%L', dm)) = 0);
  PERFORM t.throws('M3 react: outsider cannot react', format($q$SELECT public.bmn_toggle_reaction('dm',%L,'👍')$q$, dm), 'not found');
  PERFORM t.throws('M3 react: direct insert blocked', format($q$INSERT INTO public.message_reactions(message_id,user_id,emoji) VALUES (%L,%L,'x')$q$, dm, m), '');
  PERFORM t.as_user(b);
  PERFORM t.ok('M3 react: same emoji removes', public.bmn_toggle_reaction('dm', dm, '❤️') = 'removed');
  PERFORM t.throws('M3 react: empty emoji rejected', format($q$SELECT public.bmn_toggle_reaction('dm',%L,'')$q$, dm), 'Invalid emoji');

  -- pins
  PERFORM t.as_user(b);
  PERFORM t.works('M3 pin: participant pins a DM message', format($q$SELECT public.bmn_set_message_pin('dm',%L,true)$q$, dm));
  PERFORM t.as_user(a);
  PERFORM t.ok('M3 pin: other participant sees the pin', t.count(format('select 1 from public.message_pins where message_id=%L', dm)) = 1);
  PERFORM t.as_user(m);
  PERFORM t.ok('M3 pin: outsider cannot see the pin', t.count(format('select 1 from public.message_pins where message_id=%L', dm)) = 0);
  PERFORM t.throws('M3 pin: outsider cannot pin', format($q$SELECT public.bmn_set_message_pin('dm',%L,true)$q$, dm), 'not found');
  PERFORM t.as_user(a);
  PERFORM t.works('M3 pin: unpin', format($q$SELECT public.bmn_set_message_pin('dm',%L,false)$q$, dm));
  PERFORM t.ok('M3 pin: pin row removed', t.q(format('select count(*) from public.message_pins where message_id=%L', dm)) = '0');

  -- forward
  PERFORM t.as_user(b);
  nid := public.bmn_forward_message('dm', dm, c, NULL);
  PERFORM t.ok('M3 forward: creates a message to the new peer', (SELECT sender_id = b AND recipient_id = c AND content = 'edited text' FROM public.messages WHERE id = nid));
  PERFORM t.ok('M3 forward: label names the ORIGINAL author, set by the server', (SELECT forwarded_from_user_id = a AND forwarded_from_name = 'Alice' FROM public.messages WHERE id = nid));
  PERFORM t.as_user(m);
  PERFORM t.throws('M3 forward: cannot forward a message you cannot see', format($q$SELECT public.bmn_forward_message('dm',%L,%L,NULL)$q$, dm, c), 'not found');
  PERFORM t.as_user(b);
  PERFORM t.throws('M3 forward: exactly one destination', format($q$SELECT public.bmn_forward_message('dm',%L,%L,%L)$q$, dm, c, gen_random_uuid()), 'one destination');
  PERFORM t.works('M3 forward: to yourself is allowed (Saved messages) and keeps the original-author label', format($q$SELECT public.bmn_forward_message('dm',%L,%L,NULL)$q$, dm, b));
  PERFORM t.ok('M3 forward to yourself: stored as a note to self', (SELECT count(*) = 1 FROM public.messages WHERE sender_id = b AND recipient_id = b AND forwarded_from_user_id = a));
  PERFORM t.su();
  INSERT INTO public.user_blocks(user_id,target_id,kind) VALUES (c, b, 'block');
  PERFORM t.as_user(b);
  PERFORM t.throws('M3 forward: blocked recipient is refused', format($q$SELECT public.bmn_forward_message('dm',%L,%L,NULL)$q$, dm, c), 'cannot message');
  PERFORM t.su();
  DELETE FROM public.user_blocks;

  -- unsend
  PERFORM t.as_user(b);
  PERFORM t.throws('M3 unsend: recipient cannot unsend', format($q$SELECT public.bmn_unsend_message('dm',%L)$q$, dm), 'your own');
  PERFORM t.as_user(a);
  PERFORM public.bmn_toggle_reaction('dm', dm, '👍');
  PERFORM public.bmn_set_message_pin('dm', dm, true);
  PERFORM t.ok('M3 unsend: sender unsends', public.bmn_unsend_message('dm', dm) IS NOT NULL);
  PERFORM t.as_user(b);
  PERFORM t.ok('M3 unsend: recipient sees a tombstone, not the text', (SELECT content = 'bmn-unsent:' AND unsent_at IS NOT NULL FROM public.messages WHERE id = dm));
  PERFORM t.ok('M3 unsend: reactions and pin removed', t.q(format('select count(*) from public.message_reactions where message_id=%L', dm)) = '0' AND t.q(format('select count(*) from public.message_pins where message_id=%L', dm)) = '0');
  PERFORM t.throws('M3 unsend: cannot react to an unsent message', format($q$SELECT public.bmn_toggle_reaction('dm',%L,'👍')$q$, dm), 'Cannot react');
  PERFORM t.throws('M3 unsend: cannot forward an unsent message', format($q$SELECT public.bmn_forward_message('dm',%L,%L,NULL)$q$, dm, c), 'cannot be forwarded');
  PERFORM t.as_user(a);
  PERFORM t.throws('M3 unsend: cannot edit an unsent message', format($q$SELECT public.bmn_edit_message('dm',%L,'back')$q$, dm), 'unsent');
  PERFORM t.su();
  PERFORM t.ok('M3 unsend: the original text is gone from the row (edit history is the only trace, sender-only)', (SELECT content FROM public.messages WHERE id = dm) = 'bmn-unsent:');

  -- delete for me
  PERFORM t.as_user(a);
  INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (a,b,'delete me') RETURNING id INTO rid;
  PERFORM t.as_user(b);
  PERFORM t.works('M3 delete-for-me: recipient hides', format($q$SELECT public.bmn_delete_message_for_me('dm',%L)$q$, rid));
  PERFORM t.ok('M3 delete-for-me: hidden for recipient', t.count(format('select 1 from public.messages where id=%L', rid)) = 0);
  PERFORM t.as_user(a);
  PERFORM t.ok('M3 delete-for-me: still visible to the sender', t.count(format('select 1 from public.messages where id=%L', rid)) = 1);
  PERFORM t.as_user(m);
  PERFORM t.throws('M3 delete-for-me: outsider cannot', format($q$SELECT public.bmn_delete_message_for_me('dm',%L)$q$, rid), 'not found');

  -- report
  PERFORM t.as_user(b);
  PERFORM t.ok('M3 report: recipient can report a message', public.bmn_report_message('dm', dm2, 'harassment', 'rude') IS NOT NULL);
  PERFORM t.ok('M3 report: points at the sender and the message', t.q(format('select (reported_user_id=%L and message_id=%L) from public.content_reports where reporter_id=%L order by created_at desc limit 1', a, dm2, b)) = 'true');
  PERFORM t.as_user(a);
  PERFORM t.throws('M3 report: cannot report your own message', format($q$SELECT public.bmn_report_message('dm',%L,'spam')$q$, dm2), 'own message');
  PERFORM t.as_user(b);
  PERFORM t.throws('M3 report: invalid reason rejected by existing check', format($q$SELECT public.bmn_report_message('dm',%L,'because')$q$, dm2), 'reason_check');
  PERFORM t.as_user(m);
  PERFORM t.throws('M3 report: cannot report a message you cannot see', format($q$SELECT public.bmn_report_message('dm',%L,'spam')$q$, dm2), 'not found');
END $$;
SELECT t.su();

-- group-scoped actions
DO $$
DECLARE a uuid := t.u(1); b uuid := t.u(2); c uuid := t.u(3); m uuid := t.u(6); g uuid; gm uuid; gm2 uuid; nid uuid;
BEGIN
  PERFORM t.as_user(a);
  g := public.bmn_create_group('Actions', NULL, ARRAY[b, c]);
  PERFORM t.as_user(b);
  INSERT INTO public.group_messages(group_id,sender_id,content) VALUES (g, b, 'group text') RETURNING id INTO gm;
  PERFORM t.as_user(c);
  PERFORM t.throws('M3 group edit: another member cannot edit', format($q$SELECT public.bmn_edit_message('group',%L,'x')$q$, gm), 'own messages');
  PERFORM t.as_user(b);
  PERFORM t.ok('M3 group edit: sender edits', public.bmn_edit_message('group', gm, 'group text 2') IS NOT NULL);
  PERFORM t.ok('M3 group edit: edited_at set', (SELECT edited_at IS NOT NULL FROM public.group_messages WHERE id = gm));
  PERFORM t.as_user(c);
  PERFORM t.ok('M3 group react: member reacts', public.bmn_toggle_reaction('group', gm, '🔥') = 'added');
  PERFORM t.as_user(b);
  PERFORM t.ok('M3 group react: others see reactions', t.count(format('select 1 from public.message_reactions where group_message_id=%L', gm)) = 1);
  PERFORM t.as_user(m);
  PERFORM t.ok('M3 group react: outsider sees none', t.count(format('select 1 from public.message_reactions where group_message_id=%L', gm)) = 0);
  PERFORM t.throws('M3 group react: outsider cannot react', format($q$SELECT public.bmn_toggle_reaction('group',%L,'🔥')$q$, gm), 'not found');
  PERFORM t.as_user(b);
  PERFORM t.throws('M3 group pin: plain member cannot pin', format($q$SELECT public.bmn_set_message_pin('group',%L,true)$q$, gm), 'admins');
  PERFORM t.as_user(a);
  PERFORM t.works('M3 group pin: owner pins', format($q$SELECT public.bmn_set_message_pin('group',%L,true)$q$, gm));
  PERFORM t.as_user(c);
  PERFORM t.ok('M3 group pin: members see the pin', t.count(format('select 1 from public.message_pins where group_message_id=%L', gm)) = 1);
  -- forward into group, and out of group
  PERFORM t.as_user(c);
  nid := public.bmn_forward_message('group', gm, a, NULL);
  PERFORM t.ok('M3 forward: group message to a person keeps the original author label', (SELECT forwarded_from_user_id = b AND forwarded_from_name = 'Bob' FROM public.messages WHERE id = nid));
  PERFORM t.as_user(a);
  PERFORM t.works('M3 forward: DM into a group', format($q$SELECT public.bmn_forward_message('dm',%L,NULL,%L)$q$, t.q($z$select id from public.messages where content='a reply' limit 1$z$)::uuid, g));
  PERFORM t.as_user(a);
  PERFORM public.bmn_update_group(g, p_only_admins_post => true);
  PERFORM t.as_user(c);
  PERFORM t.throws('M3 forward: refused where the user cannot post', format($q$SELECT public.bmn_forward_message('group',%L,NULL,%L)$q$, gm, g), 'cannot post');
  PERFORM t.as_user(a);
  PERFORM public.bmn_update_group(g, p_only_admins_post => false);
  -- unsend moderation
  PERFORM t.as_user(c);
  PERFORM t.throws('M3 group unsend: member cannot unsend someone else''s message', format($q$SELECT public.bmn_unsend_message('group',%L)$q$, gm), 'your own');
  PERFORM t.as_user(a);
  PERFORM t.ok('M3 group unsend: owner can remove a member''s message', public.bmn_unsend_message('group', gm) IS NOT NULL);
  PERFORM t.as_user(c);
  PERFORM t.ok('M3 group unsend: members see a tombstone', (SELECT content = 'bmn-unsent:' FROM public.group_messages WHERE id = gm));
  PERFORM t.ok('M3 group unsend: its reactions and pin are gone', t.q(format('select count(*) from public.message_reactions where group_message_id=%L', gm)) = '0');
  PERFORM t.throws('M3 group unsend: system messages are protected', format($q$SELECT public.bmn_unsend_message('group',%L)$q$, t.q(format($z$select id from public.group_messages where group_id=%L and kind='system' limit 1$z$, g))::uuid), 'System messages');
  -- delete for me / report
  PERFORM t.as_user(b);
  INSERT INTO public.group_messages(group_id,sender_id,content) VALUES (g, b, 'second') RETURNING id INTO gm2;
  PERFORM t.as_user(c);
  PERFORM t.works('M3 group delete-for-me', format($q$SELECT public.bmn_delete_message_for_me('group',%L)$q$, gm2));
  PERFORM t.ok('M3 group delete-for-me: hidden from me', t.count(format('select 1 from public.group_messages where id=%L', gm2)) = 0);
  PERFORM t.as_user(a);
  PERFORM t.ok('M3 group delete-for-me: still visible to others', t.count(format('select 1 from public.group_messages where id=%L', gm2)) = 1);
  PERFORM t.ok('M3 group report works', public.bmn_report_message('group', gm2, 'spam') IS NOT NULL);
  PERFORM t.ok('M3 group report stores group_message_id', t.q(format('select (group_message_id=%L) from public.content_reports where reporter_id=%L order by created_at desc limit 1', gm2, a)) = 'true');

  -- conversation settings (pin / mute / archive)
  PERFORM t.as_user(a);
  PERFORM t.works('M3 settings: pin a DM conversation', format($q$INSERT INTO public.conversation_settings(user_id,peer_id,pinned_at) VALUES (%L,%L,now())$q$, a, b));
  PERFORM t.works('M3 settings: mute a group I belong to', format($q$INSERT INTO public.conversation_settings(user_id,group_id,muted_until) VALUES (%L,%L,now()+interval '8 hours')$q$, a, g));
  PERFORM t.throws('M3 settings: cannot configure a group I am not in', format($q$INSERT INTO public.conversation_settings(user_id,group_id,archived_at) VALUES (%L,%L,now())$q$, m, g), 'row-level security');
  PERFORM t.throws('M3 settings: cannot write another user''s settings', format($q$INSERT INTO public.conversation_settings(user_id,peer_id,pinned_at) VALUES (%L,%L,now())$q$, b, c), 'row-level security');
  PERFORM t.throws('M3 settings: duplicate row rejected', format($q$INSERT INTO public.conversation_settings(user_id,peer_id) VALUES (%L,%L)$q$, a, b), 'duplicate');
  PERFORM t.works('M3 settings: archive via update', format($q$UPDATE public.conversation_settings SET archived_at=now() WHERE user_id=%L AND peer_id=%L$q$, a, b));
  PERFORM t.as_user(b);
  PERFORM t.ok('M3 settings: others cannot read my settings', t.count('select 1 from public.conversation_settings') = 0);
  PERFORM t.as_user(m);
  PERFORM t.throws('M3 settings: self-conversation rejected', format($q$INSERT INTO public.conversation_settings(user_id,peer_id) VALUES (%L,%L)$q$, m, m), 'check');
END $$;
SELECT t.su();

-- Batch 2 compatibility: existing RPCs and queries keep working
DO $$
DECLARE a uuid := t.u(1); b uuid := t.u(2); n int;
BEGIN
  PERFORM t.as_user(a);
  INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (a,b,'unread for bob');
  PERFORM t.as_user(b);
  PERFORM t.ok('B2 compat: unread query as Batch 2 runs it', t.count(format('select sender_id from public.messages where recipient_id=%L and read_at is null and sender_id<>%L', b, b)) >= 1);
  PERFORM t.ok('B2 compat: bmn_mark_messages_read still works', public.bmn_mark_messages_read(a) >= 1);
  PERFORM t.ok('B2 compat: nothing left unread', t.count(format('select 1 from public.messages where recipient_id=%L and sender_id=%L and read_at is null', b, a)) = 0);
  PERFORM t.ok('B2 compat: bmn_clear_conversation still works', public.bmn_clear_conversation(a) >= 1);
  PERFORM t.ok('B2 compat: cleared conversation hidden for me', t.count(format('select 1 from public.messages where (sender_id=%L and recipient_id=%L) or (sender_id=%L and recipient_id=%L)', a, b, b, a)) = 0);
  PERFORM t.as_user(a);
  PERFORM t.ok('B2 compat: other side still sees their copy', t.count(format('select 1 from public.messages where sender_id=%L and recipient_id=%L', a, b)) >= 1);
END $$;
SELECT t.su();

-- pins list + batch presence
DO $$
DECLARE a uuid := t.u(1); b uuid := t.u(2); m uuid := t.u(6); g uuid; gm uuid; mid uuid; n bigint;
BEGIN
  PERFORM t.as_user(a);
  INSERT INTO public.messages(sender_id,recipient_id,content) VALUES (a,b,'pin me') RETURNING id INTO mid;
  PERFORM public.bmn_set_message_pin('dm', mid, true);
  PERFORM t.ok('M3 pins list: DM pin returned', t.count(format('select 1 from public.bmn_conversation_pins(%L, NULL)', b)) >= 1);
  PERFORM t.as_user(m);
  PERFORM t.ok('M3 pins list: outsider gets nothing for a DM they are not in', t.count(format('select 1 from public.bmn_conversation_pins(%L, NULL)', b)) = 0);
  PERFORM t.throws('M3 pins list: needs exactly one target', $q$SELECT * FROM public.bmn_conversation_pins(NULL, NULL)$q$, 'Choose');
  PERFORM t.as_user(a);
  g := public.bmn_create_group('Pins', NULL, ARRAY[b]);
  INSERT INTO public.group_messages(group_id,sender_id,content) VALUES (g, a, 'group pin') RETURNING id INTO gm;
  PERFORM public.bmn_set_message_pin('group', gm, true);
  PERFORM t.ok('M3 pins list: group pin returned to members', t.count(format('select 1 from public.bmn_conversation_pins(NULL, %L)', g)) = 1);
  PERFORM t.as_user(m);
  PERFORM t.ok('M3 pins list: non-member gets nothing for a group', t.count(format('select 1 from public.bmn_conversation_pins(NULL, %L)', g)) = 0);
  -- batch presence
  PERFORM t.as_user(a);
  PERFORM t.ok('M1 batch presence returns one row per distinct peer', t.count(format('select 1 from public.bmn_peers_presence(ARRAY[%L,%L,%L]::uuid[])', b, b, m)) = 2);
  PERFORM t.ok('M1 batch presence honours privacy like the single call', (SELECT online FROM public.bmn_peers_presence(ARRAY[b]) LIMIT 1) IS NOT NULL);
END $$;
SELECT t.su();
