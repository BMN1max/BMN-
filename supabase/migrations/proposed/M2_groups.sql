-- =====================================================================
-- M2  Group chats
-- STATUS: PROPOSED. Not run anywhere. Review first.
-- DEPENDS ON  M0 (notifications.message) and M1 (blocks, settings, config).
-- PURPOSE  Group conversations that reuse the same infrastructure as 1:1 chat:
--          same Supabase realtime, same media paths (bmn-img: / bmn-voice: content prefixes),
--          same account-status moderation, same reactions/pins/edits tables (added in M3).
--          Group messages are kept in their own table so the existing `messages` table,
--          its RLS and the Batch 2 inbox queries are untouched.
-- OBJECTS  Tables: group_chats, group_members, group_messages, group_message_hides
--          Helpers: bmn_is_group_member, bmn_group_role, bmn_group_joined_at, bmn_can_post_group,
--                   bmn_group_invite_ok
--          RPCs: bmn_create_group, bmn_add_group_members, bmn_remove_group_member,
--                bmn_leave_group, bmn_set_group_role, bmn_update_group,
--                bmn_mark_group_read, bmn_group_inbox
--          Triggers: bmn_group_message_before, bmn_group_message_after
-- SECURITY RLS on all tables. Membership, roles and group settings can ONLY be changed
--          through the SECURITY DEFINER RPCs, which enforce owner/admin rules.
--          Members read only messages sent after they joined. Removed members lose access.
-- ROLES    owner (exactly one) > admin > member.
-- IDEMPOTENT  Yes.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.group_chats (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 80),
  description text CHECK (description IS NULL OR char_length(description) <= 500),
  avatar_url text CHECK (avatar_url IS NULL OR char_length(avatar_url) <= 600),
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  only_admins_post boolean NOT NULL DEFAULT false,
  members_can_add boolean NOT NULL DEFAULT false,
  disappearing_seconds integer NOT NULL DEFAULT 0 CHECK (disappearing_seconds >= 0),
  closed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.group_members (
  group_id uuid NOT NULL REFERENCES public.group_chats(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role text NOT NULL DEFAULT 'member' CHECK (role IN ('owner','admin','member')),
  added_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  joined_at timestamptz NOT NULL DEFAULT now(),
  last_read_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (group_id, user_id)
);
CREATE INDEX IF NOT EXISTS group_members_user_idx ON public.group_members (user_id);
CREATE UNIQUE INDEX IF NOT EXISTS group_members_one_owner ON public.group_members (group_id) WHERE role = 'owner';

CREATE TABLE IF NOT EXISTS public.group_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL REFERENCES public.group_chats(id) ON DELETE CASCADE,
  sender_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  content text NOT NULL CHECK (char_length(btrim(content)) > 0 AND char_length(content) <= 4000),
  kind text NOT NULL DEFAULT 'user' CHECK (kind IN ('user','system')),
  reply_to_id uuid REFERENCES public.group_messages(id) ON DELETE SET NULL,
  forwarded_from_user_id uuid,
  forwarded_from_name text,
  edited_at timestamptz,
  unsent_at timestamptz,
  expires_at timestamptz,
  media_meta jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS group_messages_group_created_idx ON public.group_messages (group_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.group_message_hides (
  group_message_id uuid NOT NULL REFERENCES public.group_messages(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (group_message_id, user_id)
);

ALTER TABLE public.group_chats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_message_hides ENABLE ROW LEVEL SECURITY;

-- ---------- helpers (SECURITY DEFINER avoids recursive RLS on group_members) ----------
CREATE OR REPLACE FUNCTION public.bmn_is_group_member(p_group uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.group_members m JOIN public.group_chats g ON g.id = m.group_id
                  WHERE m.group_id = p_group AND m.user_id = auth.uid() AND g.closed_at IS NULL);
$$;
CREATE OR REPLACE FUNCTION public.bmn_group_role(p_group uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT m.role FROM public.group_members m JOIN public.group_chats g ON g.id = m.group_id
   WHERE m.group_id = p_group AND m.user_id = auth.uid() AND g.closed_at IS NULL;
$$;
CREATE OR REPLACE FUNCTION public.bmn_group_joined_at(p_group uuid)
RETURNS timestamptz LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT joined_at FROM public.group_members WHERE group_id = p_group AND user_id = auth.uid();
$$;
CREATE OR REPLACE FUNCTION public.bmn_can_post_group(p_group uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.group_members m JOIN public.group_chats g ON g.id = m.group_id
                  WHERE m.group_id = p_group AND m.user_id = auth.uid() AND g.closed_at IS NULL
                    AND (NOT g.only_admins_post OR m.role IN ('owner','admin')));
$$;
CREATE OR REPLACE FUNCTION public.bmn_group_invite_ok(p_inviter uuid, p_invitee uuid)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_mode text;
BEGIN
  IF p_inviter = p_invitee THEN RETURN true; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_invitee) THEN RETURN false; END IF;
  IF public.bmn_is_blocked_between(p_inviter, p_invitee) THEN RETURN false; END IF;
  SELECT group_invites INTO v_mode FROM public.bmn_messaging_settings WHERE user_id = p_invitee;
  v_mode := COALESCE(v_mode, 'everyone');
  IF v_mode = 'everyone' THEN RETURN true; END IF;
  IF v_mode = 'nobody' THEN RETURN false; END IF;
  RETURN EXISTS (SELECT 1 FROM public.follows WHERE follower_id = p_invitee AND following_id = p_inviter);
END; $$;

-- ---------- RLS ----------
DROP POLICY IF EXISTS "Members read their groups" ON public.group_chats;
CREATE POLICY "Members read their groups" ON public.group_chats
  FOR SELECT TO authenticated USING (public.bmn_is_group_member(id));

DROP POLICY IF EXISTS "Members read their group roster" ON public.group_members;
CREATE POLICY "Members read their group roster" ON public.group_members
  FOR SELECT TO authenticated USING (public.bmn_is_group_member(group_id));

DROP POLICY IF EXISTS "Members read group messages since joining" ON public.group_messages;
CREATE POLICY "Members read group messages since joining" ON public.group_messages
  FOR SELECT TO authenticated
  USING (public.bmn_is_group_member(group_id)
         AND created_at >= public.bmn_group_joined_at(group_id)
         AND NOT EXISTS (SELECT 1 FROM public.group_message_hides h
                          WHERE h.group_message_id = group_messages.id AND h.user_id = (SELECT auth.uid())));

DROP POLICY IF EXISTS "Members send group messages as themselves" ON public.group_messages;
CREATE POLICY "Members send group messages as themselves" ON public.group_messages
  FOR INSERT TO authenticated
  WITH CHECK (sender_id = (SELECT auth.uid()) AND kind = 'user' AND public.bmn_can_post_group(group_id));

DROP POLICY IF EXISTS "Own group message hides" ON public.group_message_hides;
CREATE POLICY "Own group message hides" ON public.group_message_hides
  FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));

-- ---------- triggers on group_messages ----------
CREATE OR REPLACE FUNCTION public.bmn_group_message_before() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_actor uuid; v_status text; v_exp timestamptz; v_ok boolean; v_dis integer;
BEGIN
  IF current_setting('bmn.rpc', true) = '1' THEN
    PERFORM set_config('bmn.rpc', '0', true);   -- the internal-call flag is single-use
  ELSIF auth.role() <> 'service_role' THEN
    v_actor := auth.uid();
    IF v_actor IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
    SELECT status, expires_at INTO v_status, v_exp FROM public.bmn_user_moderation WHERE user_id = v_actor;
    IF v_status = 'banned' OR (v_status = 'suspended' AND (v_exp IS NULL OR v_exp > now())) THEN
      RAISE EXCEPTION 'Your BMN account is restricted';
    END IF;
    -- clients may not forge server-owned fields
    NEW.edited_at := NULL; NEW.unsent_at := NULL; NEW.expires_at := NULL;
    NEW.forwarded_from_user_id := NULL; NEW.forwarded_from_name := NULL;
  END IF;
  IF NEW.reply_to_id IS NOT NULL THEN
    SELECT EXISTS (SELECT 1 FROM public.group_messages r WHERE r.id = NEW.reply_to_id AND r.group_id = NEW.group_id) INTO v_ok;
    IF NOT v_ok THEN RAISE EXCEPTION 'Reply target is not in this group'; END IF;
  END IF;
  SELECT disappearing_seconds INTO v_dis FROM public.group_chats WHERE id = NEW.group_id;
  IF NEW.kind = 'user' AND COALESCE(v_dis,0) > 0 THEN NEW.expires_at := now() + make_interval(secs => v_dis); END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS bmn_group_message_before ON public.group_messages;
CREATE TRIGGER bmn_group_message_before BEFORE INSERT ON public.group_messages
  FOR EACH ROW EXECUTE FUNCTION public.bmn_group_message_before();

CREATE OR REPLACE FUNCTION public.bmn_group_message_after() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_target uuid; v_name text;
BEGIN
  UPDATE public.group_chats SET updated_at = now() WHERE id = NEW.group_id;
  IF NEW.kind = 'user' AND NEW.reply_to_id IS NOT NULL THEN
    SELECT sender_id INTO v_target FROM public.group_messages WHERE id = NEW.reply_to_id;
    IF v_target IS NOT NULL AND v_target <> NEW.sender_id
       AND EXISTS (SELECT 1 FROM public.group_members WHERE group_id = NEW.group_id AND user_id = v_target) THEN
      SELECT name INTO v_name FROM public.group_chats WHERE id = NEW.group_id;
      INSERT INTO public.notifications (user_id, actor_id, type, message)
      VALUES (v_target, NEW.sender_id, 'group_reply', 'replied to you in ' || v_name);
    END IF;
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS bmn_group_message_after ON public.group_messages;
CREATE TRIGGER bmn_group_message_after AFTER INSERT ON public.group_messages
  FOR EACH ROW EXECUTE FUNCTION public.bmn_group_message_after();

-- ---------- RPCs ----------
CREATE OR REPLACE FUNCTION public.bmn_create_group(p_name text, p_description text DEFAULT NULL,
                                                   p_member_ids uuid[] DEFAULT '{}', p_avatar text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid(); v_gid uuid; v_uid uuid; v_added uuid[] := '{}'; v_max bigint;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF EXISTS (SELECT 1 FROM public.bmn_user_moderation WHERE user_id = v_me AND (status = 'banned' OR (status = 'suspended' AND (expires_at IS NULL OR expires_at > now())))) THEN
    RAISE EXCEPTION 'Your BMN account is restricted';
  END IF;
  p_name := btrim(COALESCE(p_name,''));
  IF char_length(p_name) < 1 OR char_length(p_name) > 80 THEN RAISE EXCEPTION 'Group name must be 1-80 characters'; END IF;
  v_max := public.bmn_cfg('group_max_members', 200);
  INSERT INTO public.group_chats (name, description, avatar_url, created_by)
  VALUES (p_name, NULLIF(btrim(COALESCE(p_description,'')),''), NULLIF(btrim(COALESCE(p_avatar,'')),''), v_me)
  RETURNING id INTO v_gid;
  INSERT INTO public.group_members (group_id, user_id, role, added_by) VALUES (v_gid, v_me, 'owner', v_me);
  FOR v_uid IN SELECT DISTINCT u FROM unnest(COALESCE(p_member_ids,'{}')) u WHERE u IS NOT NULL AND u <> v_me LOOP
    EXIT WHEN COALESCE(array_length(v_added,1),0) + 1 >= v_max;
    IF public.bmn_group_invite_ok(v_me, v_uid) THEN
      INSERT INTO public.group_members (group_id, user_id, added_by) VALUES (v_gid, v_uid, v_me) ON CONFLICT DO NOTHING;
      v_added := v_added || v_uid;
    END IF;
  END LOOP;
  PERFORM set_config('bmn.rpc', '1', true);
  INSERT INTO public.group_messages (group_id, sender_id, content, kind) VALUES (v_gid, v_me, 'bmn-sys:created', 'system');
  IF array_length(v_added,1) > 0 THEN
    INSERT INTO public.notifications (user_id, actor_id, type, message)
      SELECT u, v_me, 'group_added', 'added you to ' || p_name FROM unnest(v_added) u;
  END IF;
  RETURN v_gid;
END; $$;

CREATE OR REPLACE FUNCTION public.bmn_add_group_members(p_group uuid, p_user_ids uuid[])
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid(); v_role text; g public.group_chats%ROWTYPE; v_uid uuid; v_added uuid[] := '{}'; v_n bigint; v_max bigint; v_name text;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  SELECT * INTO g FROM public.group_chats WHERE id = p_group AND closed_at IS NULL;
  v_role := public.bmn_group_role(p_group);
  IF g.id IS NULL OR v_role IS NULL THEN RAISE EXCEPTION 'Not a member of this group'; END IF;
  IF NOT (v_role IN ('owner','admin') OR g.members_can_add) THEN RAISE EXCEPTION 'You cannot add members to this group'; END IF;
  v_max := public.bmn_cfg('group_max_members', 200);
  SELECT count(*) INTO v_n FROM public.group_members WHERE group_id = p_group;
  FOR v_uid IN SELECT DISTINCT u FROM unnest(COALESCE(p_user_ids,'{}')) u WHERE u IS NOT NULL LOOP
    EXIT WHEN v_n + COALESCE(array_length(v_added,1),0) >= v_max;
    CONTINUE WHEN EXISTS (SELECT 1 FROM public.group_members WHERE group_id = p_group AND user_id = v_uid);
    IF public.bmn_group_invite_ok(v_me, v_uid) THEN
      INSERT INTO public.group_members (group_id, user_id, added_by) VALUES (p_group, v_uid, v_me);
      v_added := v_added || v_uid;
    END IF;
  END LOOP;
  IF array_length(v_added,1) > 0 THEN
    PERFORM set_config('bmn.rpc', '1', true);
    INSERT INTO public.group_messages (group_id, sender_id, content, kind)
      VALUES (p_group, v_me, 'bmn-sys:added:' || array_to_string(v_added, ','), 'system');
    INSERT INTO public.notifications (user_id, actor_id, type, message)
      SELECT u, v_me, 'group_added', 'added you to ' || g.name FROM unnest(v_added) u;
  END IF;
  RETURN COALESCE(array_length(v_added,1), 0);
END; $$;

CREATE OR REPLACE FUNCTION public.bmn_leave_group(p_group uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid(); v_role text; v_next uuid;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  v_role := public.bmn_group_role(p_group);
  IF v_role IS NULL THEN RAISE EXCEPTION 'Not a member of this group'; END IF;
  PERFORM set_config('bmn.rpc', '1', true);
  INSERT INTO public.group_messages (group_id, sender_id, content, kind) VALUES (p_group, v_me, 'bmn-sys:left', 'system');
  IF v_role = 'owner' THEN
    SELECT user_id INTO v_next FROM public.group_members
      WHERE group_id = p_group AND user_id <> v_me
      ORDER BY (role = 'admin') DESC, joined_at ASC LIMIT 1;
    IF v_next IS NULL THEN
      DELETE FROM public.group_members WHERE group_id = p_group AND user_id = v_me;
      UPDATE public.group_chats SET closed_at = now() WHERE id = p_group;   -- history kept, group closed
      RETURN;
    END IF;
    DELETE FROM public.group_members WHERE group_id = p_group AND user_id = v_me;
    UPDATE public.group_members SET role = 'owner' WHERE group_id = p_group AND user_id = v_next;
  ELSE
    DELETE FROM public.group_members WHERE group_id = p_group AND user_id = v_me;
  END IF;
END; $$;

CREATE OR REPLACE FUNCTION public.bmn_remove_group_member(p_group uuid, p_user uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid(); v_role text; v_target text;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_user = v_me THEN PERFORM public.bmn_leave_group(p_group); RETURN; END IF;
  v_role := public.bmn_group_role(p_group);
  SELECT role INTO v_target FROM public.group_members WHERE group_id = p_group AND user_id = p_user;
  IF v_role IS NULL OR v_target IS NULL THEN RAISE EXCEPTION 'Not allowed'; END IF;
  IF NOT ((v_role = 'owner') OR (v_role = 'admin' AND v_target = 'member')) THEN
    RAISE EXCEPTION 'You do not have permission to remove this member';
  END IF;
  DELETE FROM public.group_members WHERE group_id = p_group AND user_id = p_user;
  PERFORM set_config('bmn.rpc', '1', true);
  INSERT INTO public.group_messages (group_id, sender_id, content, kind)
    VALUES (p_group, v_me, 'bmn-sys:removed:' || p_user::text, 'system');
END; $$;

CREATE OR REPLACE FUNCTION public.bmn_set_group_role(p_group uuid, p_user uuid, p_role text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid(); v_role text; v_target text;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_role NOT IN ('owner','admin','member') THEN RAISE EXCEPTION 'Invalid role'; END IF;
  v_role := public.bmn_group_role(p_group);
  IF v_role IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Only the group owner can change roles'; END IF;
  SELECT role INTO v_target FROM public.group_members WHERE group_id = p_group AND user_id = p_user;
  IF v_target IS NULL THEN RAISE EXCEPTION 'Not a member'; END IF;
  IF p_user = v_me THEN RAISE EXCEPTION 'Transfer ownership to someone else instead'; END IF;
  IF p_role = 'owner' THEN
    UPDATE public.group_members SET role = 'admin' WHERE group_id = p_group AND user_id = v_me;
    UPDATE public.group_members SET role = 'owner' WHERE group_id = p_group AND user_id = p_user;
  ELSE
    UPDATE public.group_members SET role = p_role WHERE group_id = p_group AND user_id = p_user;
  END IF;
  PERFORM set_config('bmn.rpc', '1', true);
  INSERT INTO public.group_messages (group_id, sender_id, content, kind)
    VALUES (p_group, v_me, 'bmn-sys:role:' || p_user::text || ':' || p_role, 'system');
END; $$;

CREATE OR REPLACE FUNCTION public.bmn_update_group(p_group uuid, p_name text DEFAULT NULL, p_description text DEFAULT NULL,
    p_avatar text DEFAULT NULL, p_only_admins_post boolean DEFAULT NULL, p_members_can_add boolean DEFAULT NULL,
    p_disappearing_seconds integer DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid(); v_role text; v_old text;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  v_role := public.bmn_group_role(p_group);
  IF v_role IS NULL OR v_role NOT IN ('owner','admin') THEN RAISE EXCEPTION 'Only group admins can change group settings'; END IF;
  IF p_name IS NOT NULL AND (char_length(btrim(p_name)) < 1 OR char_length(btrim(p_name)) > 80) THEN RAISE EXCEPTION 'Group name must be 1-80 characters'; END IF;
  IF p_description IS NOT NULL AND char_length(p_description) > 500 THEN RAISE EXCEPTION 'Description too long'; END IF;
  IF p_disappearing_seconds IS NOT NULL AND p_disappearing_seconds < 0 THEN RAISE EXCEPTION 'Invalid timer'; END IF;
  SELECT name INTO v_old FROM public.group_chats WHERE id = p_group;
  UPDATE public.group_chats SET
     name = COALESCE(NULLIF(btrim(p_name),''), name),
     description = CASE WHEN p_description IS NULL THEN description ELSE NULLIF(btrim(p_description),'') END,
     avatar_url = CASE WHEN p_avatar IS NULL THEN avatar_url ELSE NULLIF(btrim(p_avatar),'') END,
     only_admins_post = COALESCE(p_only_admins_post, only_admins_post),
     members_can_add = COALESCE(p_members_can_add, members_can_add),
     disappearing_seconds = COALESCE(p_disappearing_seconds, disappearing_seconds),
     updated_at = now()
   WHERE id = p_group;
  IF p_name IS NOT NULL AND btrim(p_name) <> v_old THEN
    PERFORM set_config('bmn.rpc', '1', true);
    INSERT INTO public.group_messages (group_id, sender_id, content, kind)
      VALUES (p_group, v_me, 'bmn-sys:renamed:' || btrim(p_name), 'system');
  END IF;
END; $$;

CREATE OR REPLACE FUNCTION public.bmn_mark_group_read(p_group uuid)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  UPDATE public.group_members SET last_read_at = now() WHERE group_id = p_group AND user_id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.bmn_group_inbox()
RETURNS TABLE (group_id uuid, name text, description text, avatar_url text, my_role text, member_count bigint,
               unread_count bigint, only_admins_post boolean, members_can_add boolean, disappearing_seconds integer,
               last_message_id uuid, last_message_content text, last_message_sender uuid, last_message_kind text,
               last_message_unsent boolean, last_message_at timestamptz, last_read_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid();
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  RETURN QUERY
  SELECT g.id, g.name, g.description, g.avatar_url, m.role,
         (SELECT count(*) FROM public.group_members x WHERE x.group_id = g.id),
         (SELECT count(*) FROM (SELECT 1 FROM public.group_messages u
             WHERE u.group_id = g.id AND u.kind = 'user' AND u.sender_id <> v_me
               AND u.created_at > m.last_read_at AND u.created_at >= m.joined_at AND u.unsent_at IS NULL
               AND (u.expires_at IS NULL OR u.expires_at > now())
               AND NOT EXISTS (SELECT 1 FROM public.group_message_hides h WHERE h.group_message_id = u.id AND h.user_id = v_me)
             LIMIT 999) c),
         g.only_admins_post, g.members_can_add, g.disappearing_seconds,
         lm.id, lm.content, lm.sender_id, lm.kind, (lm.unsent_at IS NOT NULL), lm.created_at, m.last_read_at
    FROM public.group_members m
    JOIN public.group_chats g ON g.id = m.group_id AND g.closed_at IS NULL
    LEFT JOIN LATERAL (
        SELECT l.* FROM public.group_messages l
         WHERE l.group_id = g.id AND l.created_at >= m.joined_at
           AND (l.expires_at IS NULL OR l.expires_at > now())
           AND NOT EXISTS (SELECT 1 FROM public.group_message_hides h WHERE h.group_message_id = l.id AND h.user_id = v_me)
         ORDER BY l.created_at DESC LIMIT 1) lm ON true
   WHERE m.user_id = v_me
   ORDER BY COALESCE(lm.created_at, g.created_at) DESC;
END; $$;

-- Realtime (only if the publication exists, as on Supabase)
DO $$
DECLARE t text;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    FOREACH t IN ARRAY ARRAY['group_messages','group_members','group_chats'] LOOP
      IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename=t) THEN
        EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
      END IF;
    END LOOP;
  END IF;
END $$;

-- ROLLBACK-BEGIN
-- DROP TRIGGER IF EXISTS bmn_group_message_after ON public.group_messages;
-- DROP TRIGGER IF EXISTS bmn_group_message_before ON public.group_messages;
-- DROP FUNCTION IF EXISTS public.bmn_group_inbox();
-- DROP FUNCTION IF EXISTS public.bmn_mark_group_read(uuid);
-- DROP FUNCTION IF EXISTS public.bmn_update_group(uuid, text, text, text, boolean, boolean, integer);
-- DROP FUNCTION IF EXISTS public.bmn_set_group_role(uuid, uuid, text);
-- DROP FUNCTION IF EXISTS public.bmn_remove_group_member(uuid, uuid);
-- DROP FUNCTION IF EXISTS public.bmn_leave_group(uuid);
-- DROP FUNCTION IF EXISTS public.bmn_add_group_members(uuid, uuid[]);
-- DROP FUNCTION IF EXISTS public.bmn_create_group(text, text, uuid[], text);
-- DROP FUNCTION IF EXISTS public.bmn_group_message_after();
-- DROP FUNCTION IF EXISTS public.bmn_group_message_before();
-- DROP POLICY IF EXISTS "Members read group messages since joining" ON public.group_messages;
-- DROP TABLE IF EXISTS public.group_message_hides;
-- DROP TABLE IF EXISTS public.group_messages;
-- DROP TABLE IF EXISTS public.group_members;
-- DROP TABLE IF EXISTS public.group_chats;
-- DROP FUNCTION IF EXISTS public.bmn_group_invite_ok(uuid, uuid);
-- DROP FUNCTION IF EXISTS public.bmn_can_post_group(uuid);
-- DROP FUNCTION IF EXISTS public.bmn_group_joined_at(uuid);
-- DROP FUNCTION IF EXISTS public.bmn_group_role(uuid);
-- DROP FUNCTION IF EXISTS public.bmn_is_group_member(uuid);
-- ROLLBACK-END

-- VERIFY-BEGIN
-- select relname, relrowsecurity from pg_class where relname like 'group_%' and relkind='r';
-- select policyname, cmd from pg_policies where tablename like 'group_%' order by 1;
-- VERIFY-END
