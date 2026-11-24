-- =====================================================================
-- M1  Messaging settings, blocks, message requests, presence masking
-- STATUS: PROPOSED. Not run anywhere. Review first.
-- PURPOSE  Server-side enforcement of block lists and messaging privacy, which today only
--          live on the device. Adds a RESTRICTIVE insert policy to public.messages so no
--          existing policy is edited or dropped.
-- PRODUCTION AUDIT (2026-11-23, PostgreSQL 17.11) found two tables that already exist and are
--          REUSED here, not duplicated:
--            public.user_blocks   (user_id = blocker, target_id = blocked, kind block|mute|restrict)
--            public.user_settings (read_receipts, show_activity_status, who_can_message, ...)
--          This file therefore never drops or alters them. CREATE TABLE IF NOT EXISTS with the
--          exact production shape is kept only so the file also works on an empty database.
-- OBJECTS  Tables: bmn_messaging_settings (extra settings only), message_requests
--          Config: bmn_messaging_config table + bmn_cfg()
--          Functions: bmn_is_blocked_between, bmn_can_message, bmn_peer_flags,
--                     bmn_peers_presence, bmn_respond_message_request,
--                     bmn_touch_message_request (trigger fn)
--          Policy: "BMN restrict blocked or gated sends" (RESTRICTIVE, INSERT) on messages
--          Trigger: bmn_message_request_touch on messages
-- SECURITY RLS on every new table. Writes to message_requests only through the RPC.
--          NOTE: the Render socket handler inserts with the service role, which BYPASSES
--          RLS. server.js must call the same checks (documented in docs/batch3).
-- IDEMPOTENT  Yes.
-- =====================================================================

-- ---------- existing production tables (shape taken from the 2026-11-23 audit) ----------
-- read_receipts, show_activity_status and who_can_message live in public.user_settings.
CREATE TABLE IF NOT EXISTS public.user_settings (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  private_account boolean NOT NULL DEFAULT false,
  suggest_account boolean NOT NULL DEFAULT true,
  allow_downloads boolean NOT NULL DEFAULT true,
  allow_comments text NOT NULL DEFAULT 'everyone',
  allow_mentions text NOT NULL DEFAULT 'everyone',
  allow_tags text NOT NULL DEFAULT 'everyone',
  who_can_message text NOT NULL DEFAULT 'everyone',
  show_activity_status boolean NOT NULL DEFAULT true,
  read_receipts boolean NOT NULL DEFAULT true,
  language text NOT NULL DEFAULT 'en',
  notif_prefs jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.user_blocks (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  target_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('block','mute','restrict')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, target_id, kind)
);
ALTER TABLE public.user_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_blocks ENABLE ROW LEVEL SECURITY;
-- Policies exist in production (own settings select/insert/update, own blocks select/insert/delete).
-- They are only created here when a table has none, i.e. on an empty database.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_settings') THEN
    CREATE POLICY "own settings select" ON public.user_settings FOR SELECT USING (auth.uid() = user_id);
    CREATE POLICY "own settings insert" ON public.user_settings FOR INSERT WITH CHECK (auth.uid() = user_id);
    CREATE POLICY "own settings update" ON public.user_settings FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_blocks') THEN
    CREATE POLICY "own blocks select" ON public.user_blocks FOR SELECT USING (auth.uid() = user_id);
    CREATE POLICY "own blocks insert" ON public.user_blocks FOR INSERT WITH CHECK (auth.uid() = user_id);
    CREATE POLICY "own blocks delete" ON public.user_blocks FOR DELETE USING (auth.uid() = user_id);
  END IF;
END $$;

-- ---------- extra messaging settings (one row per user) ----------
CREATE TABLE IF NOT EXISTS public.bmn_messaging_settings (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  last_seen text NOT NULL DEFAULT 'everyone' CHECK (last_seen IN ('everyone','followers','nobody')),
  typing_indicator boolean NOT NULL DEFAULT true,
  group_invites text NOT NULL DEFAULT 'everyone' CHECK (group_invites IN ('everyone','followers','nobody')),
  disappearing_default_seconds integer NOT NULL DEFAULT 0 CHECK (disappearing_default_seconds >= 0),
  auto_download jsonb NOT NULL DEFAULT '{"photos":"wifi","video":"wifi","voice":"always"}'::jsonb,
  theme text NOT NULL DEFAULT 'system' CHECK (theme IN ('system','dark','light')),
  accent text NOT NULL DEFAULT 'bmn' CHECK (accent IN ('bmn','ocean','forest','sunset','rose')),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.bmn_messaging_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Own messaging settings select" ON public.bmn_messaging_settings;
CREATE POLICY "Own messaging settings select" ON public.bmn_messaging_settings
  FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
DROP POLICY IF EXISTS "Own messaging settings insert" ON public.bmn_messaging_settings;
CREATE POLICY "Own messaging settings insert" ON public.bmn_messaging_settings
  FOR INSERT TO authenticated WITH CHECK (user_id = (SELECT auth.uid()));
DROP POLICY IF EXISTS "Own messaging settings update" ON public.bmn_messaging_settings;
CREATE POLICY "Own messaging settings update" ON public.bmn_messaging_settings
  FOR UPDATE TO authenticated USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));

-- ---------- message requests ----------
CREATE TABLE IF NOT EXISTS public.message_requests (
  requester_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  recipient_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','accepted','declined')),
  created_at timestamptz NOT NULL DEFAULT now(),
  responded_at timestamptz,
  PRIMARY KEY (requester_id, recipient_id),
  CHECK (requester_id <> recipient_id)
);
CREATE INDEX IF NOT EXISTS message_requests_recipient_idx ON public.message_requests (recipient_id, status);
ALTER TABLE public.message_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Participants see requests" ON public.message_requests;
CREATE POLICY "Participants see requests" ON public.message_requests
  FOR SELECT TO authenticated
  USING (recipient_id = (SELECT auth.uid()) OR requester_id = (SELECT auth.uid()));

-- ---------- helpers ----------
CREATE OR REPLACE FUNCTION public.bmn_is_blocked_between(a uuid, b uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_blocks
                  WHERE kind = 'block' AND ((user_id = a AND target_id = b) OR (user_id = b AND target_id = a)));
$$;

-- Who may start a chat with this user? Source: existing user_settings.who_can_message.
-- 'followers' / 'following' -> only people the user follows (others become a message request);
-- 'nobody' / 'none'         -> only people the user has already written to; anything else -> everyone.
CREATE OR REPLACE FUNCTION public.bmn_msg_mode(p_user uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT COALESCE((SELECT CASE lower(btrim(who_can_message))
                            WHEN 'followers' THEN 'followers' WHEN 'following' THEN 'followers'
                            WHEN 'nobody' THEN 'nobody' WHEN 'none' THEN 'nobody' WHEN 'no_one' THEN 'nobody'
                            ELSE 'everyone' END
                     FROM public.user_settings WHERE user_id = p_user), 'everyone');
$$;

-- May `p_sender` start or continue a 1:1 chat with `p_recipient`?
CREATE OR REPLACE FUNCTION public.bmn_can_message(p_sender uuid, p_recipient uuid)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_mode text; v_status text;
BEGIN
  IF p_sender IS NULL OR p_recipient IS NULL OR p_sender = p_recipient THEN RETURN true; END IF;
  IF public.bmn_is_blocked_between(p_sender, p_recipient) THEN RETURN false; END IF;
  v_mode := public.bmn_msg_mode(p_recipient);
  IF v_mode = 'everyone' THEN RETURN true; END IF;
  -- recipient only accepts messages from people they follow, accepted requests, or people they wrote to
  IF v_mode = 'followers' AND EXISTS (SELECT 1 FROM public.follows WHERE follower_id = p_recipient AND following_id = p_sender) THEN RETURN true; END IF;
  IF EXISTS (SELECT 1 FROM public.messages WHERE sender_id = p_recipient AND recipient_id = p_sender) THEN RETURN true; END IF;
  IF v_mode = 'nobody' THEN RETURN false; END IF;
  SELECT status INTO v_status FROM public.message_requests WHERE requester_id = p_sender AND recipient_id = p_recipient;
  IF v_status = 'accepted' THEN RETURN true; END IF;
  IF v_status = 'declined' THEN RETURN false; END IF;
  -- first contact is allowed once, and becomes a pending request
  RETURN NOT EXISTS (SELECT 1 FROM public.messages WHERE sender_id = p_sender AND recipient_id = p_recipient);
END; $$;

DROP POLICY IF EXISTS "BMN restrict blocked or gated sends" ON public.messages;
CREATE POLICY "BMN restrict blocked or gated sends" ON public.messages
  AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (public.bmn_can_message(sender_id, recipient_id));

CREATE OR REPLACE FUNCTION public.bmn_touch_message_request() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_mode text;
BEGIN
  v_mode := public.bmn_msg_mode(NEW.recipient_id);
  IF v_mode = 'followers'
     AND NOT EXISTS (SELECT 1 FROM public.follows WHERE follower_id = NEW.recipient_id AND following_id = NEW.sender_id)
     AND NOT EXISTS (SELECT 1 FROM public.messages WHERE sender_id = NEW.recipient_id AND recipient_id = NEW.sender_id) THEN
    INSERT INTO public.message_requests (requester_id, recipient_id) VALUES (NEW.sender_id, NEW.recipient_id)
      ON CONFLICT DO NOTHING;
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS bmn_message_request_touch ON public.messages;
CREATE TRIGGER bmn_message_request_touch AFTER INSERT ON public.messages
  FOR EACH ROW EXECUTE FUNCTION public.bmn_touch_message_request();

CREATE OR REPLACE FUNCTION public.bmn_respond_message_request(p_requester uuid, p_accept boolean)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid();
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  UPDATE public.message_requests
     SET status = CASE WHEN p_accept THEN 'accepted' ELSE 'declined' END, responded_at = now()
   WHERE requester_id = p_requester AND recipient_id = v_me;
  IF NOT FOUND THEN RAISE EXCEPTION 'No such request'; END IF;
  RETURN CASE WHEN p_accept THEN 'accepted' ELSE 'declined' END;
END; $$;

-- What may the caller learn about `p_peer`? Never returns values the peer chose to hide.
CREATE OR REPLACE FUNCTION public.bmn_peer_flags(p_peer uuid)
RETURNS TABLE (read_receipts boolean, typing_indicator boolean, online boolean, last_seen_at timestamptz, blocked boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid(); s public.bmn_messaging_settings%ROWTYPE; v_seen timestamptz; v_follows boolean;
        v_rr boolean; v_act boolean;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  SELECT * INTO s FROM public.bmn_messaging_settings WHERE user_id = p_peer;
  SELECT pr.last_seen_at INTO v_seen FROM public.profiles pr WHERE pr.id = p_peer;
  SELECT us.read_receipts, us.show_activity_status INTO v_rr, v_act FROM public.user_settings us WHERE us.user_id = p_peer;
  v_follows := EXISTS (SELECT 1 FROM public.follows WHERE follower_id = p_peer AND following_id = v_me);
  blocked := public.bmn_is_blocked_between(v_me, p_peer);
  read_receipts := COALESCE(v_rr, true);
  typing_indicator := COALESCE(s.typing_indicator, true) AND NOT blocked;
  IF blocked THEN online := false; last_seen_at := NULL; RETURN NEXT; RETURN; END IF;
  IF COALESCE(s.last_seen,'everyone') = 'nobody'
     OR (COALESCE(s.last_seen,'everyone') = 'followers' AND NOT v_follows)
     OR NOT COALESCE(v_act, true) THEN
    last_seen_at := NULL;
  ELSE
    last_seen_at := v_seen;
  END IF;
  online := COALESCE(v_act, true) AND v_seen IS NOT NULL AND v_seen > now() - interval '2 minutes'
            AND last_seen_at IS NOT NULL;
  RETURN NEXT;
END; $$;


-- Batch version for the inbox list: presence of up to 100 peers in one call.
CREATE OR REPLACE FUNCTION public.bmn_peers_presence(p_peers uuid[])
RETURNS TABLE (peer_id uuid, online boolean, last_seen_at timestamptz, blocked boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  RETURN QUERY
  SELECT x.id, f.online, f.last_seen_at, f.blocked
    FROM (SELECT DISTINCT u AS id FROM unnest(p_peers) u WHERE u IS NOT NULL LIMIT 100) x,
         LATERAL public.bmn_peer_flags(x.id) f;
END; $$;

-- ---------- tunable limits (owner edits in SQL editor; no deploy needed) ----------
CREATE TABLE IF NOT EXISTS public.bmn_messaging_config (
  key text PRIMARY KEY,
  value bigint NOT NULL,
  note text
);
ALTER TABLE public.bmn_messaging_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Config readable by signed-in users" ON public.bmn_messaging_config;
CREATE POLICY "Config readable by signed-in users" ON public.bmn_messaging_config
  FOR SELECT TO authenticated USING (true);
INSERT INTO public.bmn_messaging_config (key, value, note) VALUES
  ('unsend_window_seconds', 172800, 'Unsend for everyone allowed for this long after sending (48h)'),
  ('edit_window_seconds',   172800, 'Edit allowed for this long after sending (48h)'),
  ('group_max_members',     200,    'Maximum members in one group'),
  ('voice_max_seconds',     300,    'Maximum voice message length')
ON CONFLICT (key) DO NOTHING;
CREATE OR REPLACE FUNCTION public.bmn_cfg(p_key text, p_default bigint)
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT COALESCE((SELECT value FROM public.bmn_messaging_config WHERE key = p_key), p_default);
$$;

-- ROLLBACK-BEGIN
-- DROP TRIGGER IF EXISTS bmn_message_request_touch ON public.messages;
-- DROP POLICY IF EXISTS "BMN restrict blocked or gated sends" ON public.messages;
-- DROP FUNCTION IF EXISTS public.bmn_peers_presence(uuid[]);
-- DROP FUNCTION IF EXISTS public.bmn_peer_flags(uuid);
-- DROP FUNCTION IF EXISTS public.bmn_respond_message_request(uuid, boolean);
-- DROP FUNCTION IF EXISTS public.bmn_touch_message_request();
-- DROP FUNCTION IF EXISTS public.bmn_can_message(uuid, uuid);
-- DROP FUNCTION IF EXISTS public.bmn_msg_mode(uuid);
-- DROP FUNCTION IF EXISTS public.bmn_is_blocked_between(uuid, uuid);
-- DROP TABLE IF EXISTS public.message_requests;
-- NOTE user_blocks and user_settings already exist in production and are NOT dropped.
-- DROP TABLE IF EXISTS public.bmn_messaging_settings;
-- DROP FUNCTION IF EXISTS public.bmn_cfg(text, bigint);
-- DROP TABLE IF EXISTS public.bmn_messaging_config;
-- ROLLBACK-END

-- VERIFY-BEGIN
-- select policyname, permissive, cmd from pg_policies where tablename='messages';
-- select relname, relrowsecurity from pg_class where relname in ('bmn_messaging_settings','user_blocks','user_settings','message_requests');
-- select kind, count(*) from public.user_blocks group by 1;   -- existing rows are untouched
-- VERIFY-END
