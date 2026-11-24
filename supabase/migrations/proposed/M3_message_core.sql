-- =====================================================================
-- M3  Message actions: reply, edit, unsend, delete-for-me, reactions, pins, forward,
--     report, per-conversation pin/mute/archive. Works for 1:1 AND group messages.
-- STATUS: PROPOSED. Not run anywhere. Review first.
-- DEPENDS ON  M0, M1, M2.
-- PURPOSE  `messages` has only SELECT and INSERT policies, so edits, unsends, reactions and
--          pins need server-side functions. Every action is a SECURITY DEFINER RPC that
--          re-checks who the caller is and what they may see. Nothing here edits an existing
--          policy or function. `bmn_mark_messages_read` and `bmn_clear_conversation` are NOT touched.
-- OBJECTS  Columns on messages: reply_to_id, forwarded_from_user_id, forwarded_from_name,
--            edited_at, unsent_at, expires_at, media_meta
--          Column on content_reports: message_id, group_message_id
--          Tables: message_edits, message_reactions, message_pins, conversation_settings
--          Functions: bmn_msg_info, bmn_edit_message, bmn_unsend_message,
--            bmn_delete_message_for_me, bmn_toggle_reaction, bmn_set_message_pin,
--            bmn_forward_message, bmn_report_message, bmn_message_before (trigger fn)
--          Trigger: bmn_message_before (messages)
-- SECURITY Clients cannot forge edited_at / unsent_at / expires_at / forwarded_* on insert.
--          Edit history is readable only by the editor. Group admins may unsend others'
--          messages in their own group. Reactions/pins are readable only if the message is.
-- IDEMPOTENT  Yes.
-- =====================================================================

ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS reply_to_id uuid REFERENCES public.messages(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS forwarded_from_user_id uuid,
  ADD COLUMN IF NOT EXISTS forwarded_from_name text,
  ADD COLUMN IF NOT EXISTS edited_at timestamptz,
  ADD COLUMN IF NOT EXISTS unsent_at timestamptz,
  ADD COLUMN IF NOT EXISTS expires_at timestamptz,
  ADD COLUMN IF NOT EXISTS media_meta jsonb;

ALTER TABLE public.content_reports
  ADD COLUMN IF NOT EXISTS message_id uuid REFERENCES public.messages(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS group_message_id uuid REFERENCES public.group_messages(id) ON DELETE SET NULL;

-- ---------- tables ----------
CREATE TABLE IF NOT EXISTS public.message_edits (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id uuid REFERENCES public.messages(id) ON DELETE CASCADE,
  group_message_id uuid REFERENCES public.group_messages(id) ON DELETE CASCADE,
  editor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  old_content text NOT NULL,
  edited_at timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(message_id, group_message_id) = 1)
);
CREATE INDEX IF NOT EXISTS message_edits_msg_idx ON public.message_edits (message_id);
CREATE INDEX IF NOT EXISTS message_edits_gmsg_idx ON public.message_edits (group_message_id);

CREATE TABLE IF NOT EXISTS public.message_reactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id uuid REFERENCES public.messages(id) ON DELETE CASCADE,
  group_message_id uuid REFERENCES public.group_messages(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  emoji text NOT NULL CHECK (char_length(emoji) BETWEEN 1 AND 16),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(message_id, group_message_id) = 1)
);
CREATE UNIQUE INDEX IF NOT EXISTS message_reactions_dm_uq ON public.message_reactions (message_id, user_id) WHERE message_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS message_reactions_grp_uq ON public.message_reactions (group_message_id, user_id) WHERE group_message_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.message_pins (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id uuid REFERENCES public.messages(id) ON DELETE CASCADE,
  group_message_id uuid REFERENCES public.group_messages(id) ON DELETE CASCADE,
  pinned_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(message_id, group_message_id) = 1)
);
CREATE UNIQUE INDEX IF NOT EXISTS message_pins_dm_uq ON public.message_pins (message_id) WHERE message_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS message_pins_grp_uq ON public.message_pins (group_message_id) WHERE group_message_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.conversation_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  peer_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  group_id uuid REFERENCES public.group_chats(id) ON DELETE CASCADE,
  pinned_at timestamptz,
  muted_until timestamptz,
  archived_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(peer_id, group_id) = 1),
  CHECK (peer_id IS NULL OR peer_id <> user_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS conversation_settings_peer_uq ON public.conversation_settings (user_id, peer_id) WHERE peer_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS conversation_settings_grp_uq ON public.conversation_settings (user_id, group_id) WHERE group_id IS NOT NULL;

ALTER TABLE public.message_edits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.message_reactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.message_pins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversation_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Editors read their edit history" ON public.message_edits;
CREATE POLICY "Editors read their edit history" ON public.message_edits
  FOR SELECT TO authenticated USING (editor_id = (SELECT auth.uid()));

-- The sub-selects run under the caller's RLS, so a reaction/pin is visible only if its message is.
DROP POLICY IF EXISTS "Reactions visible with their message" ON public.message_reactions;
CREATE POLICY "Reactions visible with their message" ON public.message_reactions
  FOR SELECT TO authenticated USING (
    (message_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.messages m WHERE m.id = message_reactions.message_id))
    OR (group_message_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.group_messages g WHERE g.id = message_reactions.group_message_id)));
DROP POLICY IF EXISTS "Pins visible with their message" ON public.message_pins;
CREATE POLICY "Pins visible with their message" ON public.message_pins
  FOR SELECT TO authenticated USING (
    (message_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.messages m WHERE m.id = message_pins.message_id))
    OR (group_message_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.group_messages g WHERE g.id = message_pins.group_message_id)));

DROP POLICY IF EXISTS "Own conversation settings select" ON public.conversation_settings;
CREATE POLICY "Own conversation settings select" ON public.conversation_settings
  FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
DROP POLICY IF EXISTS "Own conversation settings insert" ON public.conversation_settings;
CREATE POLICY "Own conversation settings insert" ON public.conversation_settings
  FOR INSERT TO authenticated WITH CHECK (user_id = (SELECT auth.uid()) AND (group_id IS NULL OR public.bmn_is_group_member(group_id)));
DROP POLICY IF EXISTS "Own conversation settings update" ON public.conversation_settings;
CREATE POLICY "Own conversation settings update" ON public.conversation_settings
  FOR UPDATE TO authenticated USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
DROP POLICY IF EXISTS "Own conversation settings delete" ON public.conversation_settings;
CREATE POLICY "Own conversation settings delete" ON public.conversation_settings
  FOR DELETE TO authenticated USING (user_id = (SELECT auth.uid()));

-- ---------- insert guard on messages ----------
CREATE OR REPLACE FUNCTION public.bmn_message_before() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
BEGIN
  IF current_setting('bmn.rpc', true) = '1' THEN
    PERFORM set_config('bmn.rpc', '0', true);   -- the internal-call flag is single-use
  ELSIF auth.role() <> 'service_role' THEN
    NEW.edited_at := NULL; NEW.unsent_at := NULL; NEW.expires_at := NULL;
    NEW.forwarded_from_user_id := NULL; NEW.forwarded_from_name := NULL;
  END IF;
  IF NEW.reply_to_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.messages r WHERE r.id = NEW.reply_to_id
        AND ((r.sender_id = NEW.sender_id AND r.recipient_id = NEW.recipient_id)
          OR (r.sender_id = NEW.recipient_id AND r.recipient_id = NEW.sender_id))) THEN
      RAISE EXCEPTION 'Reply target is not in this conversation';
    END IF;
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS bmn_message_before ON public.messages;
CREATE TRIGGER bmn_message_before BEFORE INSERT ON public.messages
  FOR EACH ROW EXECUTE FUNCTION public.bmn_message_before();

-- ---------- shared lookup: only returns messages the caller can currently see ----------
CREATE OR REPLACE FUNCTION public.bmn_msg_info(p_scope text, p_id uuid)
RETURNS TABLE (sender uuid, created timestamptz, content text, unsent timestamptz, kind text, grp uuid, peer uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid();
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_scope = 'dm' THEN
    RETURN QUERY SELECT m.sender_id, m.created_at, m.content, m.unsent_at, 'user'::text, NULL::uuid,
                        CASE WHEN m.sender_id = v_me THEN m.recipient_id ELSE m.sender_id END
      FROM public.messages m WHERE m.id = p_id
       AND ((m.sender_id = v_me AND NOT m.deleted_by_sender) OR (m.recipient_id = v_me AND NOT m.deleted_by_recipient));
  ELSIF p_scope = 'group' THEN
    RETURN QUERY SELECT g.sender_id, g.created_at, g.content, g.unsent_at, g.kind, g.group_id, NULL::uuid
      FROM public.group_messages g WHERE g.id = p_id
       AND public.bmn_is_group_member(g.group_id) AND g.created_at >= public.bmn_group_joined_at(g.group_id)
       AND NOT EXISTS (SELECT 1 FROM public.group_message_hides h WHERE h.group_message_id = g.id AND h.user_id = v_me);
  ELSE
    RAISE EXCEPTION 'Unknown scope';
  END IF;
END; $$;

-- ---------- actions ----------
CREATE OR REPLACE FUNCTION public.bmn_edit_message(p_scope text, p_id uuid, p_content text)
RETURNS timestamptz LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid(); i record; v_win bigint; v_max int; v_ts timestamptz := now();
BEGIN
  SELECT * INTO i FROM public.bmn_msg_info(p_scope, p_id);
  IF i.sender IS NULL THEN RAISE EXCEPTION 'Message not found'; END IF;
  IF i.sender <> v_me OR i.kind <> 'user' THEN RAISE EXCEPTION 'You can only edit your own messages'; END IF;
  IF i.unsent IS NOT NULL THEN RAISE EXCEPTION 'Message was unsent'; END IF;
  IF i.content ~ '^bmn-[a-z]+:' THEN RAISE EXCEPTION 'Only text messages can be edited'; END IF;
  p_content := btrim(COALESCE(p_content,''));
  v_max := CASE WHEN p_scope = 'dm' THEN 2000 ELSE 4000 END;
  IF char_length(p_content) < 1 OR char_length(p_content) > v_max THEN RAISE EXCEPTION 'Invalid message length'; END IF;
  IF p_content ~ '^bmn-[a-z]+:' THEN RAISE EXCEPTION 'Invalid message'; END IF;
  v_win := public.bmn_cfg('edit_window_seconds', 172800);
  IF v_ts > i.created + make_interval(secs => v_win) THEN RAISE EXCEPTION 'The edit window has passed'; END IF;
  IF p_content = i.content THEN RETURN NULL; END IF;
  IF p_scope = 'dm' THEN
    INSERT INTO public.message_edits (message_id, editor_id, old_content) VALUES (p_id, v_me, i.content);
    UPDATE public.messages SET content = p_content, edited_at = v_ts WHERE id = p_id;
  ELSE
    INSERT INTO public.message_edits (group_message_id, editor_id, old_content) VALUES (p_id, v_me, i.content);
    UPDATE public.group_messages SET content = p_content, edited_at = v_ts WHERE id = p_id;
  END IF;
  RETURN v_ts;
END; $$;

CREATE OR REPLACE FUNCTION public.bmn_unsend_message(p_scope text, p_id uuid)
RETURNS timestamptz LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid(); i record; v_win bigint; v_ts timestamptz := now(); v_role text;
BEGIN
  SELECT * INTO i FROM public.bmn_msg_info(p_scope, p_id);
  IF i.sender IS NULL THEN RAISE EXCEPTION 'Message not found'; END IF;
  IF i.kind <> 'user' THEN RAISE EXCEPTION 'System messages cannot be unsent'; END IF;
  IF i.unsent IS NOT NULL THEN RETURN i.unsent; END IF;
  v_role := CASE WHEN p_scope = 'group' THEN public.bmn_group_role(i.grp) END;
  IF i.sender <> v_me AND COALESCE(v_role,'member') NOT IN ('owner','admin') THEN
    RAISE EXCEPTION 'You can only unsend your own messages';
  END IF;
  v_win := public.bmn_cfg('unsend_window_seconds', 172800);
  IF i.sender = v_me AND v_ts > i.created + make_interval(secs => v_win) AND COALESCE(v_role,'member') NOT IN ('owner','admin') THEN
    RAISE EXCEPTION 'The unsend window has passed';
  END IF;
  IF p_scope = 'dm' THEN
    UPDATE public.messages SET content = 'bmn-unsent:', unsent_at = v_ts, media_meta = NULL WHERE id = p_id;
    DELETE FROM public.message_reactions WHERE message_id = p_id;
    DELETE FROM public.message_pins WHERE message_id = p_id;
  ELSE
    UPDATE public.group_messages SET content = 'bmn-unsent:', unsent_at = v_ts, media_meta = NULL WHERE id = p_id;
    DELETE FROM public.message_reactions WHERE group_message_id = p_id;
    DELETE FROM public.message_pins WHERE group_message_id = p_id;
  END IF;
  RETURN v_ts;
END; $$;

CREATE OR REPLACE FUNCTION public.bmn_delete_message_for_me(p_scope text, p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid(); i record;
BEGIN
  SELECT * INTO i FROM public.bmn_msg_info(p_scope, p_id);
  IF i.sender IS NULL THEN RAISE EXCEPTION 'Message not found'; END IF;
  IF p_scope = 'dm' THEN
    UPDATE public.messages SET deleted_by_sender = CASE WHEN sender_id = v_me THEN true ELSE deleted_by_sender END,
                               deleted_by_recipient = CASE WHEN recipient_id = v_me THEN true ELSE deleted_by_recipient END
     WHERE id = p_id;
  ELSE
    INSERT INTO public.group_message_hides (group_message_id, user_id) VALUES (p_id, v_me) ON CONFLICT DO NOTHING;
  END IF;
END; $$;

CREATE OR REPLACE FUNCTION public.bmn_toggle_reaction(p_scope text, p_id uuid, p_emoji text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid(); i record; v_old text;
BEGIN
  SELECT * INTO i FROM public.bmn_msg_info(p_scope, p_id);
  IF i.sender IS NULL THEN RAISE EXCEPTION 'Message not found'; END IF;
  IF i.unsent IS NOT NULL OR i.kind <> 'user' THEN RAISE EXCEPTION 'Cannot react to this message'; END IF;
  p_emoji := btrim(COALESCE(p_emoji,''));
  IF char_length(p_emoji) < 1 OR char_length(p_emoji) > 16 THEN RAISE EXCEPTION 'Invalid emoji'; END IF;
  IF p_scope = 'dm' THEN
    SELECT emoji INTO v_old FROM public.message_reactions WHERE message_id = p_id AND user_id = v_me;
    IF v_old IS NULL THEN INSERT INTO public.message_reactions (message_id, user_id, emoji) VALUES (p_id, v_me, p_emoji); RETURN 'added';
    ELSIF v_old = p_emoji THEN DELETE FROM public.message_reactions WHERE message_id = p_id AND user_id = v_me; RETURN 'removed';
    ELSE UPDATE public.message_reactions SET emoji = p_emoji, created_at = now() WHERE message_id = p_id AND user_id = v_me; RETURN 'changed'; END IF;
  ELSE
    SELECT emoji INTO v_old FROM public.message_reactions WHERE group_message_id = p_id AND user_id = v_me;
    IF v_old IS NULL THEN INSERT INTO public.message_reactions (group_message_id, user_id, emoji) VALUES (p_id, v_me, p_emoji); RETURN 'added';
    ELSIF v_old = p_emoji THEN DELETE FROM public.message_reactions WHERE group_message_id = p_id AND user_id = v_me; RETURN 'removed';
    ELSE UPDATE public.message_reactions SET emoji = p_emoji, created_at = now() WHERE group_message_id = p_id AND user_id = v_me; RETURN 'changed'; END IF;
  END IF;
END; $$;

CREATE OR REPLACE FUNCTION public.bmn_set_message_pin(p_scope text, p_id uuid, p_pinned boolean)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid(); i record;
BEGIN
  SELECT * INTO i FROM public.bmn_msg_info(p_scope, p_id);
  IF i.sender IS NULL THEN RAISE EXCEPTION 'Message not found'; END IF;
  IF i.unsent IS NOT NULL OR i.kind <> 'user' THEN RAISE EXCEPTION 'Cannot pin this message'; END IF;
  IF p_scope = 'group' AND COALESCE(public.bmn_group_role(i.grp),'member') NOT IN ('owner','admin') THEN
    RAISE EXCEPTION 'Only group admins can pin messages';
  END IF;
  IF p_scope = 'dm' THEN
    IF p_pinned THEN INSERT INTO public.message_pins (message_id, pinned_by) VALUES (p_id, v_me) ON CONFLICT DO NOTHING;
    ELSE DELETE FROM public.message_pins WHERE message_id = p_id; END IF;
  ELSE
    IF p_pinned THEN INSERT INTO public.message_pins (group_message_id, pinned_by) VALUES (p_id, v_me) ON CONFLICT DO NOTHING;
    ELSE DELETE FROM public.message_pins WHERE group_message_id = p_id; END IF;
  END IF;
  RETURN p_pinned;
END; $$;

-- Forwarding copies the content server-side and fills the "forwarded from" label itself,
-- so a client cannot fake who a message came from.
CREATE OR REPLACE FUNCTION public.bmn_forward_message(p_scope text, p_id uuid, p_to_peer uuid DEFAULT NULL, p_to_group uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid(); i record; v_name text; v_new uuid;
BEGIN
  IF num_nonnulls(p_to_peer, p_to_group) <> 1 THEN RAISE EXCEPTION 'Choose exactly one destination'; END IF;
  SELECT * INTO i FROM public.bmn_msg_info(p_scope, p_id);
  IF i.sender IS NULL THEN RAISE EXCEPTION 'Message not found'; END IF;
  IF i.unsent IS NOT NULL OR i.kind <> 'user' THEN RAISE EXCEPTION 'This message cannot be forwarded'; END IF;
  SELECT COALESCE(NULLIF(display_name,''), NULLIF(username,''), 'BMN user') INTO v_name FROM public.profiles WHERE id = i.sender;
  PERFORM set_config('bmn.rpc', '1', true);
  IF p_to_peer IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_to_peer) THEN RAISE EXCEPTION 'Invalid recipient'; END IF;
    -- p_to_peer = me is "Saved messages" (a note to self, as in Batch 2): no privacy gate applies to yourself.
    IF p_to_peer <> v_me AND NOT public.bmn_can_message(v_me, p_to_peer) THEN RAISE EXCEPTION 'You cannot message this person'; END IF;
    INSERT INTO public.messages (sender_id, recipient_id, content, forwarded_from_user_id, forwarded_from_name)
      VALUES (v_me, p_to_peer, i.content, i.sender, v_name) RETURNING id INTO v_new;
  ELSE
    IF NOT public.bmn_can_post_group(p_to_group) THEN RAISE EXCEPTION 'You cannot post in this group'; END IF;
    INSERT INTO public.group_messages (group_id, sender_id, content, forwarded_from_user_id, forwarded_from_name)
      VALUES (p_to_group, v_me, i.content, i.sender, v_name) RETURNING id INTO v_new;
  END IF;
  RETURN v_new;
END; $$;

CREATE OR REPLACE FUNCTION public.bmn_report_message(p_scope text, p_id uuid, p_reason text, p_details text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid(); i record; v_id uuid;
BEGIN
  SELECT * INTO i FROM public.bmn_msg_info(p_scope, p_id);
  IF i.sender IS NULL THEN RAISE EXCEPTION 'Message not found'; END IF;
  IF i.sender = v_me THEN RAISE EXCEPTION 'You cannot report your own message'; END IF;
  INSERT INTO public.content_reports (reporter_id, reported_user_id, reason, details, message_id, group_message_id)
  VALUES (v_me, i.sender, p_reason, left(p_details, 1000),
          CASE WHEN p_scope = 'dm' THEN p_id END, CASE WHEN p_scope = 'group' THEN p_id END)
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$;


-- Pinned messages of one conversation (so a pin older than the loaded page can still be shown and jumped to).
CREATE OR REPLACE FUNCTION public.bmn_conversation_pins(p_peer uuid DEFAULT NULL, p_group uuid DEFAULT NULL)
RETURNS TABLE (scope text, id uuid, sender_id uuid, content text, created_at timestamptz, pinned_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid();
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF num_nonnulls(p_peer, p_group) <> 1 THEN RAISE EXCEPTION 'Choose a person or a group'; END IF;
  IF p_peer IS NOT NULL THEN
    RETURN QUERY SELECT 'dm'::text, m.id, m.sender_id, m.content, m.created_at, p.created_at
      FROM public.message_pins p JOIN public.messages m ON m.id = p.message_id
     WHERE ((m.sender_id = v_me AND m.recipient_id = p_peer AND NOT m.deleted_by_sender)
         OR (m.sender_id = p_peer AND m.recipient_id = v_me AND NOT m.deleted_by_recipient))
       AND m.unsent_at IS NULL
     ORDER BY p.created_at DESC LIMIT 50;
  ELSE
    IF NOT public.bmn_is_group_member(p_group) THEN RETURN; END IF;
    RETURN QUERY SELECT 'group'::text, g.id, g.sender_id, g.content, g.created_at, p.created_at
      FROM public.message_pins p JOIN public.group_messages g ON g.id = p.group_message_id
     WHERE g.group_id = p_group AND g.created_at >= public.bmn_group_joined_at(p_group) AND g.unsent_at IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.group_message_hides h WHERE h.group_message_id = g.id AND h.user_id = v_me)
     ORDER BY p.created_at DESC LIMIT 50;
  END IF;
END; $$;

-- Realtime
DO $$
DECLARE t text;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    FOREACH t IN ARRAY ARRAY['messages','message_reactions','message_pins','conversation_settings'] LOOP
      IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename=t) THEN
        EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
      END IF;
    END LOOP;
  END IF;
END $$;

-- ROLLBACK-BEGIN
-- DROP TRIGGER IF EXISTS bmn_message_before ON public.messages;
-- DROP FUNCTION IF EXISTS public.bmn_message_before();
-- DROP FUNCTION IF EXISTS public.bmn_conversation_pins(uuid, uuid);
-- DROP FUNCTION IF EXISTS public.bmn_report_message(text, uuid, text, text);
-- DROP FUNCTION IF EXISTS public.bmn_forward_message(text, uuid, uuid, uuid);
-- DROP FUNCTION IF EXISTS public.bmn_set_message_pin(text, uuid, boolean);
-- DROP FUNCTION IF EXISTS public.bmn_toggle_reaction(text, uuid, text);
-- DROP FUNCTION IF EXISTS public.bmn_delete_message_for_me(text, uuid);
-- DROP FUNCTION IF EXISTS public.bmn_unsend_message(text, uuid);
-- DROP FUNCTION IF EXISTS public.bmn_edit_message(text, uuid, text);
-- DROP FUNCTION IF EXISTS public.bmn_msg_info(text, uuid);
-- DROP TABLE IF EXISTS public.conversation_settings;
-- DROP TABLE IF EXISTS public.message_pins;
-- DROP TABLE IF EXISTS public.message_reactions;
-- DROP TABLE IF EXISTS public.message_edits;
-- ALTER TABLE public.content_reports DROP COLUMN IF EXISTS group_message_id, DROP COLUMN IF EXISTS message_id;
-- ALTER TABLE public.messages DROP COLUMN IF EXISTS media_meta, DROP COLUMN IF EXISTS expires_at, DROP COLUMN IF EXISTS unsent_at,
--   DROP COLUMN IF EXISTS edited_at, DROP COLUMN IF EXISTS forwarded_from_name, DROP COLUMN IF EXISTS forwarded_from_user_id,
--   DROP COLUMN IF EXISTS reply_to_id;
-- ROLLBACK-END
-- NOTE: rolling back M3 drops the columns above, which destroys edit/unsend/forward data. Export first.

-- VERIFY-BEGIN
-- select column_name from information_schema.columns where table_name='messages' and column_name in
--   ('reply_to_id','edited_at','unsent_at','expires_at','media_meta','forwarded_from_name');
-- select relname, relrowsecurity from pg_class where relname in ('message_edits','message_reactions','message_pins','conversation_settings');
-- VERIFY-END
