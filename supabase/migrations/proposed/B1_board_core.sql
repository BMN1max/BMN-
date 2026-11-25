-- =====================================================================
-- B1  BMN Board core: posts, replies/threads, quotes, likes, reposts, bookmarks, tags, views,
--     notifications, edit history, feeds, search, reports
-- STATUS: PROPOSED. Not run anywhere except a throwaway local PostgreSQL 16. Review first.
--
-- ARCHITECTURE (one account, one profile system)
--   Board has NO accounts and NO profiles of its own. Every author is a row of the existing
--   public.profiles (FK board_posts.author_id -> profiles.id). It reuses, and never alters:
--     public.profiles          names, usernames, avatars (client opens the normal Community profile)
--     public.follows           Following timeline
--     public.user_blocks       kind 'block' hides both ways; kind 'mute' hides from MY timelines
--     public.user_settings     private_account (followers-only visibility), allow_comments (who may reply)
--     public.bmn_user_moderation  suspended / banned accounts cannot post or interact
--     public.bmn_verified_users   verification badge (client reads it, as everywhere else)
--     public.content_reports   Board reports land in the SAME moderation queue (new column board_post_id)
--     public.is_bmn_owner()    owner can see removed posts
--   The existing public.posts table (video feed) is NOT touched: no column, policy, trigger or
--   index is added to it, so a Board post can never appear in a video feed.
--
-- OBJECTS
--   Tables:    board_posts, board_likes, board_reposts, board_bookmarks, board_post_tags,
--              board_post_mentions, board_views, board_notifications, board_post_edits
--   Column:    content_reports.board_post_id (additive, nullable)
--   Functions: board_can_view (used by RLS), board_feed, board_ancestors, board_tag_posts,
--              board_search_posts, board_trending, board_suggested_people,
--              board_create_post, board_edit_post, board_delete_post, board_set_like,
--              board_set_repost, board_set_bookmark, board_record_view, board_report_post,
--              board_mark_notifications_read   (+ internal helpers, not callable by clients)
--
-- SECURITY MODEL
--   * RLS is ON for every table. Clients have SELECT only. INSERT/UPDATE/DELETE are REVOKED from
--     anon and authenticated, so every write goes through the SECURITY DEFINER functions
--     (search_path = ''), which validate everything server-side: sign-in, restricted accounts,
--     length (500), media (max 4, max 1 video, https or storage-key only), reply permission,
--     blocks, visibility, rate limit (30 posts / 10 min), 24 h edit window, own-content rules.
--   * Counters (likes, reposts, replies, quotes, views) are maintained by triggers on the real
--     rows, so they can never be set by a client and always equal the real records.
--   * "views" = distinct signed-in viewers other than the author, recorded once per person
--     per post by board_record_view. Nothing is estimated.
--   * board_likes / board_bookmarks / board_notifications / board_post_edits are readable only by
--     their owner. board_views has no read policy at all.
--   * Blocked pairs (either direction) cannot see, reply to, quote, like, repost or notify each other.
--     Private accounts' posts are visible to themselves and their followers only.
--   * Deleted posts are kept as an empty tombstone (body and media cleared) so threads stay intact.
--
-- IDEMPOTENT  Yes (IF NOT EXISTS / OR REPLACE / DROP POLICY IF EXISTS). Safe to run twice.
-- ROLLBACK    See the ROLLBACK-BEGIN block at the end. It drops only Board objects. user_blocks,
--             user_settings, profiles, follows, posts and all messaging objects are never touched.
--             Rolling back deletes every Board post: export first if any exist.
-- DEPENDS ON  Existing production tables profiles, follows, user_blocks, user_settings,
--             bmn_user_moderation, content_reports and function is_bmn_owner(). It does NOT
--             require the messaging migrations M0-M3.
-- =====================================================================

DO $$
BEGIN
  IF to_regclass('public.profiles') IS NULL OR to_regclass('public.follows') IS NULL
     OR to_regclass('public.user_blocks') IS NULL OR to_regclass('public.user_settings') IS NULL
     OR to_regclass('public.bmn_user_moderation') IS NULL OR to_regclass('public.content_reports') IS NULL THEN
    RAISE EXCEPTION 'B1 needs the existing BMN tables profiles, follows, user_blocks, user_settings, bmn_user_moderation and content_reports. Run it on the BMN project (or apply M1 first on an empty database).';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.board_posts (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  author_id     uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  body          text NOT NULL DEFAULT '',
  parent_id     uuid REFERENCES public.board_posts(id) ON DELETE CASCADE,   -- reply to
  root_id       uuid REFERENCES public.board_posts(id) ON DELETE CASCADE,   -- top of the thread
  quote_id      uuid REFERENCES public.board_posts(id) ON DELETE SET NULL,  -- quote repost of
  media         jsonb NOT NULL DEFAULT '[]'::jsonb,
  status        text NOT NULL DEFAULT 'published',
  like_count    integer NOT NULL DEFAULT 0,
  repost_count  integer NOT NULL DEFAULT 0,
  reply_count   integer NOT NULL DEFAULT 0,
  quote_count   integer NOT NULL DEFAULT 0,
  view_count    integer NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now(),
  edited_at     timestamptz,
  deleted_at    timestamptz,
  CONSTRAINT board_posts_status_check CHECK (status IN ('published','removed')),
  CONSTRAINT board_posts_body_len CHECK (char_length(body) <= 500),
  CONSTRAINT board_posts_media_array CHECK (jsonb_typeof(media) = 'array' AND jsonb_array_length(media) <= 4),
  CONSTRAINT board_posts_thread_shape CHECK ((parent_id IS NULL) = (root_id IS NULL)),
  CONSTRAINT board_posts_not_both CHECK (parent_id IS NULL OR quote_id IS NULL),
  CONSTRAINT board_posts_has_content CHECK (deleted_at IS NOT NULL OR btrim(body) <> '' OR jsonb_array_length(media) > 0)
);
CREATE INDEX IF NOT EXISTS board_posts_top_idx    ON public.board_posts (created_at DESC) WHERE parent_id IS NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS board_posts_author_idx ON public.board_posts (author_id, created_at DESC);
CREATE INDEX IF NOT EXISTS board_posts_parent_idx ON public.board_posts (parent_id, created_at);
CREATE INDEX IF NOT EXISTS board_posts_root_idx   ON public.board_posts (root_id);
CREATE INDEX IF NOT EXISTS board_posts_quote_idx  ON public.board_posts (quote_id) WHERE quote_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.board_likes (
  post_id uuid NOT NULL REFERENCES public.board_posts(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (post_id, user_id));
CREATE INDEX IF NOT EXISTS board_likes_user_idx ON public.board_likes (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.board_reposts (
  post_id uuid NOT NULL REFERENCES public.board_posts(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (post_id, user_id));
CREATE INDEX IF NOT EXISTS board_reposts_user_idx ON public.board_reposts (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.board_bookmarks (
  post_id uuid NOT NULL REFERENCES public.board_posts(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (post_id, user_id));
CREATE INDEX IF NOT EXISTS board_bookmarks_user_idx ON public.board_bookmarks (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.board_post_tags (
  post_id uuid NOT NULL REFERENCES public.board_posts(id) ON DELETE CASCADE,
  tag text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (post_id, tag),
  CONSTRAINT board_post_tags_tag CHECK (tag = lower(tag) AND char_length(tag) BETWEEN 1 AND 50));
CREATE INDEX IF NOT EXISTS board_post_tags_tag_idx ON public.board_post_tags (tag, created_at DESC);

CREATE TABLE IF NOT EXISTS public.board_post_mentions (
  post_id uuid NOT NULL REFERENCES public.board_posts(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (post_id, user_id));
CREATE INDEX IF NOT EXISTS board_post_mentions_user_idx ON public.board_post_mentions (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.board_views (
  post_id uuid NOT NULL REFERENCES public.board_posts(id) ON DELETE CASCADE,
  viewer_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (post_id, viewer_id));

CREATE TABLE IF NOT EXISTS public.board_notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,   -- recipient
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  type text NOT NULL,
  post_id uuid REFERENCES public.board_posts(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  read_at timestamptz,
  CONSTRAINT board_notifications_type CHECK (type IN ('like','repost','quote','reply','mention')),
  CONSTRAINT board_notifications_once UNIQUE (user_id, actor_id, type, post_id));
CREATE INDEX IF NOT EXISTS board_notifications_user_idx ON public.board_notifications (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.board_post_edits (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid NOT NULL REFERENCES public.board_posts(id) ON DELETE CASCADE,
  editor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  old_body text NOT NULL,
  old_media jsonb NOT NULL DEFAULT '[]'::jsonb,
  edited_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS board_post_edits_post_idx ON public.board_post_edits (post_id, edited_at DESC);

-- Board reports use the existing moderation queue.
ALTER TABLE public.content_reports
  ADD COLUMN IF NOT EXISTS board_post_id uuid REFERENCES public.board_posts(id) ON DELETE SET NULL;

-- ---------------------------------------------------------------------
-- Internal helpers (not callable by clients)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.board_is_blocked(a uuid, b uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_blocks k
                  WHERE k.kind = 'block' AND ((k.user_id = a AND k.target_id = b) OR (k.user_id = b AND k.target_id = a)));
$$;

CREATE OR REPLACE FUNCTION public.board_is_muted_by(p_muter uuid, p_target uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_blocks k WHERE k.kind = 'mute' AND k.user_id = p_muter AND k.target_id = p_target);
$$;

-- Returns the caller's id; raises for signed-out, profile-less, suspended or banned accounts.
CREATE OR REPLACE FUNCTION public.board_assert_active()
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v uuid := auth.uid();
BEGIN
  IF v IS NULL THEN RAISE EXCEPTION 'Sign in to use BMN Board'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = v) THEN
    RAISE EXCEPTION 'Finish setting up your BMN profile first';
  END IF;
  IF EXISTS (SELECT 1 FROM public.bmn_user_moderation m
              WHERE m.user_id = v AND (m.status = 'banned'
                OR (m.status = 'suspended' AND (m.expires_at IS NULL OR m.expires_at > now())))) THEN
    RAISE EXCEPTION 'Your BMN account is restricted';
  END IF;
  RETURN v;
END; $$;

-- Who may reply to this author? Source: existing user_settings.allow_comments.
-- 'followers' / 'following' / 'friends' -> only people the author follows; 'nobody' / 'none' / 'off' -> only the author.
CREATE OR REPLACE FUNCTION public.board_reply_mode(p_author uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT COALESCE((SELECT CASE lower(btrim(s.allow_comments))
                            WHEN 'followers' THEN 'following' WHEN 'following' THEN 'following' WHEN 'friends' THEN 'following'
                            WHEN 'nobody' THEN 'nobody' WHEN 'none' THEN 'nobody' WHEN 'no_one' THEN 'nobody' WHEN 'off' THEN 'nobody'
                            ELSE 'everyone' END
                     FROM public.user_settings s WHERE s.user_id = p_author), 'everyone');
$$;

-- Media: [{url,type,thumb?,w?,h?,alt?}] max 4 items, max 1 video; url must be https or a plain storage key.
CREATE OR REPLACE FUNCTION public.board_clean_media(p_media jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO '' AS $$
DECLARE it jsonb; out jsonb := '[]'::jsonb; v_url text; v_thumb text; v_type text; videos int := 0; o jsonb;
BEGIN
  IF p_media IS NULL OR p_media = 'null'::jsonb THEN RETURN '[]'::jsonb; END IF;
  IF jsonb_typeof(p_media) <> 'array' THEN RAISE EXCEPTION 'Media must be a list'; END IF;
  IF jsonb_array_length(p_media) > 4 THEN RAISE EXCEPTION 'You can attach up to 4 photos or videos'; END IF;
  FOR it IN SELECT * FROM jsonb_array_elements(p_media) LOOP
    IF jsonb_typeof(it) <> 'object' THEN RAISE EXCEPTION 'Invalid attachment'; END IF;
    v_type := it->>'type'; v_url := it->>'url'; v_thumb := NULLIF(it->>'thumb', '');
    IF v_type NOT IN ('image','video') THEN RAISE EXCEPTION 'Attachments must be photos or videos'; END IF;
    IF v_url IS NULL OR char_length(v_url) > 1000
       OR NOT (v_url ~ '^https://[^\s<>"'']+$' OR v_url ~ '^[A-Za-z0-9][A-Za-z0-9/_.~-]*$') THEN
      RAISE EXCEPTION 'Invalid attachment address';
    END IF;
    IF v_thumb IS NOT NULL AND (char_length(v_thumb) > 1000
       OR NOT (v_thumb ~ '^https://[^\s<>"'']+$' OR v_thumb ~ '^[A-Za-z0-9][A-Za-z0-9/_.~-]*$')) THEN
      RAISE EXCEPTION 'Invalid thumbnail address';
    END IF;
    IF v_type = 'video' THEN videos := videos + 1; END IF;
    IF videos > 1 THEN RAISE EXCEPTION 'Only one video per post'; END IF;
    o := jsonb_build_object('type', v_type, 'url', v_url);
    IF v_thumb IS NOT NULL THEN o := o || jsonb_build_object('thumb', v_thumb); END IF;
    IF (it->>'w') ~ '^[0-9]{1,5}$' AND (it->>'h') ~ '^[0-9]{1,5}$' THEN
      o := o || jsonb_build_object('w', (it->>'w')::int, 'h', (it->>'h')::int);
    END IF;
    IF NULLIF(btrim(it->>'alt'), '') IS NOT NULL THEN o := o || jsonb_build_object('alt', left(btrim(it->>'alt'), 200)); END IF;
    out := out || jsonb_build_array(o);
  END LOOP;
  RETURN out;
END; $$;

CREATE OR REPLACE FUNCTION public.board_extract_tags(p_body text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path TO '' AS $$
  SELECT COALESCE((SELECT (array_agg(DISTINCT t))[1:10]
                     FROM (SELECT lower(m[2]) AS t
                             FROM regexp_matches(COALESCE(p_body, ''), '(^|[^[:alnum:]_&/#])#([[:alnum:]_]{1,50})', 'g') AS m) x
                    WHERE t ~ '[[:alpha:]]'), '{}'::text[]);
$$;

CREATE OR REPLACE FUNCTION public.board_extract_mentions(p_body text)
RETURNS uuid[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT COALESCE((SELECT (array_agg(DISTINCT p.id))[1:10]
                     FROM (SELECT lower(regexp_replace(m[2], '\.+$', '')) AS u
                             FROM regexp_matches(COALESCE(p_body, ''), '(^|[^[:alnum:]_@/.])@([[:alnum:]_.]{2,30})', 'g') AS m) x
                     JOIN public.profiles p ON lower(p.username) = x.u), '{}'::uuid[]);
$$;

-- One notification per (recipient, actor, type, post). Never to yourself, never across a block, never if muted.
CREATE OR REPLACE FUNCTION public.board_notify(p_user uuid, p_actor uuid, p_type text, p_post uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
BEGIN
  IF p_user IS NULL OR p_user = p_actor THEN RETURN; END IF;
  IF public.board_is_blocked(p_user, p_actor) OR public.board_is_muted_by(p_user, p_actor) THEN RETURN; END IF;
  INSERT INTO public.board_notifications (user_id, actor_id, type, post_id)
  VALUES (p_user, p_actor, p_type, p_post) ON CONFLICT DO NOTHING;
END; $$;

-- ---------------------------------------------------------------------
-- Visibility (used by RLS): blocks hide both ways; private accounts show to followers only.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.board_can_view(p_author uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT CASE
    WHEN auth.uid() IS NOT NULL AND auth.uid() = p_author THEN true
    WHEN auth.uid() IS NOT NULL AND public.board_is_blocked(auth.uid(), p_author) THEN false
    WHEN COALESCE((SELECT s.private_account FROM public.user_settings s WHERE s.user_id = p_author), false)
      THEN auth.uid() IS NOT NULL AND EXISTS (SELECT 1 FROM public.follows f WHERE f.follower_id = auth.uid() AND f.following_id = p_author)
    ELSE true END;
$$;

-- ---------------------------------------------------------------------
-- Counter triggers: counters always equal the real rows (also on cascade deletes)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.board_count_likes() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN UPDATE public.board_posts SET like_count = like_count + 1 WHERE id = NEW.post_id;
  ELSE UPDATE public.board_posts SET like_count = GREATEST(like_count - 1, 0) WHERE id = OLD.post_id; END IF;
  RETURN NULL;
END; $$;

CREATE OR REPLACE FUNCTION public.board_count_reposts() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN UPDATE public.board_posts SET repost_count = repost_count + 1 WHERE id = NEW.post_id;
  ELSE UPDATE public.board_posts SET repost_count = GREATEST(repost_count - 1, 0) WHERE id = OLD.post_id; END IF;
  RETURN NULL;
END; $$;

CREATE OR REPLACE FUNCTION public.board_count_views() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
BEGIN
  UPDATE public.board_posts SET view_count = view_count + 1 WHERE id = NEW.post_id;
  RETURN NULL;
END; $$;

CREATE OR REPLACE FUNCTION public.board_count_threads() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.parent_id IS NOT NULL THEN UPDATE public.board_posts SET reply_count = reply_count + 1 WHERE id = NEW.parent_id; END IF;
    IF NEW.quote_id  IS NOT NULL THEN UPDATE public.board_posts SET quote_count = quote_count + 1 WHERE id = NEW.quote_id;  END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
      IF NEW.parent_id IS NOT NULL THEN UPDATE public.board_posts SET reply_count = GREATEST(reply_count - 1, 0) WHERE id = NEW.parent_id; END IF;
      IF NEW.quote_id  IS NOT NULL THEN UPDATE public.board_posts SET quote_count = GREATEST(quote_count - 1, 0) WHERE id = NEW.quote_id;  END IF;
    END IF;
  ELSIF TG_OP = 'DELETE' THEN
    IF OLD.deleted_at IS NULL THEN
      IF OLD.parent_id IS NOT NULL THEN UPDATE public.board_posts SET reply_count = GREATEST(reply_count - 1, 0) WHERE id = OLD.parent_id; END IF;
      IF OLD.quote_id  IS NOT NULL THEN UPDATE public.board_posts SET quote_count = GREATEST(quote_count - 1, 0) WHERE id = OLD.quote_id;  END IF;
    END IF;
  END IF;
  RETURN NULL;
END; $$;

DROP TRIGGER IF EXISTS board_likes_count   ON public.board_likes;
CREATE TRIGGER board_likes_count   AFTER INSERT OR DELETE ON public.board_likes   FOR EACH ROW EXECUTE FUNCTION public.board_count_likes();
DROP TRIGGER IF EXISTS board_reposts_count ON public.board_reposts;
CREATE TRIGGER board_reposts_count AFTER INSERT OR DELETE ON public.board_reposts FOR EACH ROW EXECUTE FUNCTION public.board_count_reposts();
DROP TRIGGER IF EXISTS board_views_count   ON public.board_views;
CREATE TRIGGER board_views_count   AFTER INSERT ON public.board_views             FOR EACH ROW EXECUTE FUNCTION public.board_count_views();
DROP TRIGGER IF EXISTS board_posts_threads ON public.board_posts;
CREATE TRIGGER board_posts_threads AFTER INSERT OR UPDATE OF deleted_at OR DELETE ON public.board_posts FOR EACH ROW EXECUTE FUNCTION public.board_count_threads();

-- ---------------------------------------------------------------------
-- Row level security + privileges (clients can only read)
-- ---------------------------------------------------------------------
ALTER TABLE public.board_posts          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.board_likes          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.board_reposts        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.board_bookmarks      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.board_post_tags      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.board_post_mentions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.board_views          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.board_notifications  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.board_post_edits     ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "BMN Board posts are readable" ON public.board_posts;
CREATE POLICY "BMN Board posts are readable" ON public.board_posts FOR SELECT TO anon, authenticated
  USING ((status = 'published' AND public.board_can_view(author_id)) OR author_id = (SELECT auth.uid()));
DROP POLICY IF EXISTS "BMN Board owner reads all" ON public.board_posts;
CREATE POLICY "BMN Board owner reads all" ON public.board_posts FOR SELECT TO authenticated USING (public.is_bmn_owner());

DROP POLICY IF EXISTS "BMN Board own likes" ON public.board_likes;
CREATE POLICY "BMN Board own likes" ON public.board_likes FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS "BMN Board reposts are readable" ON public.board_reposts;
CREATE POLICY "BMN Board reposts are readable" ON public.board_reposts FOR SELECT TO anon, authenticated
  USING (user_id = (SELECT auth.uid()) OR public.board_can_view(user_id));

DROP POLICY IF EXISTS "BMN Board own bookmarks" ON public.board_bookmarks;
CREATE POLICY "BMN Board own bookmarks" ON public.board_bookmarks FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS "BMN Board tags follow their post" ON public.board_post_tags;
CREATE POLICY "BMN Board tags follow their post" ON public.board_post_tags FOR SELECT TO anon, authenticated
  USING (EXISTS (SELECT 1 FROM public.board_posts p WHERE p.id = post_id));

DROP POLICY IF EXISTS "BMN Board own mentions" ON public.board_post_mentions;
CREATE POLICY "BMN Board own mentions" ON public.board_post_mentions FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS "BMN Board own notifications" ON public.board_notifications;
CREATE POLICY "BMN Board own notifications" ON public.board_notifications FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS "BMN Board own edit history" ON public.board_post_edits;
CREATE POLICY "BMN Board own edit history" ON public.board_post_edits FOR SELECT TO authenticated USING (editor_id = (SELECT auth.uid()));
-- board_views: RLS on, no policy -> not readable by clients.

REVOKE ALL ON public.board_posts, public.board_likes, public.board_reposts, public.board_bookmarks, public.board_post_tags,
              public.board_post_mentions, public.board_views, public.board_notifications, public.board_post_edits
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.board_posts, public.board_reposts, public.board_post_tags TO anon, authenticated;
GRANT SELECT ON public.board_likes, public.board_bookmarks, public.board_post_mentions, public.board_notifications, public.board_post_edits TO authenticated;

-- ---------------------------------------------------------------------
-- Write RPCs (SECURITY DEFINER; all validation is here, not in the browser)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.board_create_post(p_body text DEFAULT '', p_media jsonb DEFAULT '[]'::jsonb,
                                                    p_parent uuid DEFAULT NULL, p_quote uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  v_me uuid := public.board_assert_active();
  v_body text := btrim(COALESCE(p_body, ''));
  v_media jsonb; par record; qt record; v_root uuid; v_id uuid; v_men uuid[]; m uuid; v_mode text;
BEGIN
  IF char_length(v_body) > 500 THEN RAISE EXCEPTION 'Posts can be at most 500 characters'; END IF;
  v_media := public.board_clean_media(p_media);
  IF p_parent IS NOT NULL AND p_quote IS NOT NULL THEN RAISE EXCEPTION 'A post is either a reply or a quote, not both'; END IF;
  IF v_body = '' AND jsonb_array_length(v_media) = 0 THEN RAISE EXCEPTION 'Write something or add a photo or video'; END IF;
  IF (SELECT count(*) FROM public.board_posts x WHERE x.author_id = v_me AND x.created_at > now() - interval '10 minutes') >= 30 THEN
    RAISE EXCEPTION 'You are posting too quickly. Try again in a few minutes.';
  END IF;

  IF p_parent IS NOT NULL THEN
    SELECT id, author_id, root_id, deleted_at, status INTO par FROM public.board_posts WHERE id = p_parent;
    IF NOT FOUND OR par.deleted_at IS NOT NULL OR par.status <> 'published' OR NOT public.board_can_view(par.author_id) THEN
      RAISE EXCEPTION 'The post you are replying to is not available';
    END IF;
    IF public.board_is_blocked(v_me, par.author_id) THEN RAISE EXCEPTION 'You cannot reply to this person'; END IF;
    IF par.author_id <> v_me THEN
      v_mode := public.board_reply_mode(par.author_id);
      IF v_mode = 'nobody' THEN RAISE EXCEPTION 'This person has turned replies off'; END IF;
      IF v_mode = 'following' AND NOT EXISTS (SELECT 1 FROM public.follows f WHERE f.follower_id = par.author_id AND f.following_id = v_me) THEN
        RAISE EXCEPTION 'Only people this person follows can reply';
      END IF;
    END IF;
    v_root := COALESCE(par.root_id, par.id);
  END IF;

  IF p_quote IS NOT NULL THEN
    SELECT id, author_id, deleted_at, status INTO qt FROM public.board_posts WHERE id = p_quote;
    IF NOT FOUND OR qt.deleted_at IS NOT NULL OR qt.status <> 'published' OR NOT public.board_can_view(qt.author_id) THEN
      RAISE EXCEPTION 'The post you are quoting is not available';
    END IF;
    IF public.board_is_blocked(v_me, qt.author_id) THEN RAISE EXCEPTION 'You cannot quote this person'; END IF;
  END IF;

  INSERT INTO public.board_posts (author_id, body, parent_id, root_id, quote_id, media)
  VALUES (v_me, v_body, p_parent, v_root, p_quote, v_media) RETURNING id INTO v_id;

  INSERT INTO public.board_post_tags (post_id, tag) SELECT v_id, t FROM unnest(public.board_extract_tags(v_body)) AS t ON CONFLICT DO NOTHING;

  v_men := public.board_extract_mentions(v_body);
  FOREACH m IN ARRAY v_men LOOP
    IF m <> v_me AND NOT public.board_is_blocked(v_me, m) THEN
      INSERT INTO public.board_post_mentions (post_id, user_id) VALUES (v_id, m) ON CONFLICT DO NOTHING;
      PERFORM public.board_notify(m, v_me, 'mention', v_id);
    END IF;
  END LOOP;
  IF p_parent IS NOT NULL THEN PERFORM public.board_notify(par.author_id, v_me, 'reply', v_id); END IF;
  IF p_quote  IS NOT NULL THEN PERFORM public.board_notify(qt.author_id,  v_me, 'quote', v_id); END IF;
  RETURN v_id;
END; $$;

CREATE OR REPLACE FUNCTION public.board_edit_post(p_id uuid, p_body text, p_media jsonb DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  v_me uuid := public.board_assert_active();
  p record; v_body text := btrim(COALESCE(p_body, '')); v_media jsonb; v_men uuid[]; m uuid;
BEGIN
  SELECT * INTO p FROM public.board_posts WHERE id = p_id;
  IF NOT FOUND OR p.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'Post not found'; END IF;
  IF p.author_id <> v_me THEN RAISE EXCEPTION 'You can only edit your own posts'; END IF;
  IF p.created_at < now() - interval '24 hours' THEN RAISE EXCEPTION 'Posts can only be edited for 24 hours'; END IF;
  IF char_length(v_body) > 500 THEN RAISE EXCEPTION 'Posts can be at most 500 characters'; END IF;
  v_media := CASE WHEN p_media IS NULL THEN p.media ELSE public.board_clean_media(p_media) END;
  IF v_body = '' AND jsonb_array_length(v_media) = 0 THEN RAISE EXCEPTION 'Write something or add a photo or video'; END IF;
  IF v_body = p.body AND v_media = p.media THEN RETURN; END IF;

  INSERT INTO public.board_post_edits (post_id, editor_id, old_body, old_media) VALUES (p.id, v_me, p.body, p.media);
  UPDATE public.board_posts SET body = v_body, media = v_media, edited_at = now() WHERE id = p.id;

  DELETE FROM public.board_post_tags WHERE post_id = p.id;
  INSERT INTO public.board_post_tags (post_id, tag, created_at)
    SELECT p.id, t, p.created_at FROM unnest(public.board_extract_tags(v_body)) AS t ON CONFLICT DO NOTHING;

  v_men := public.board_extract_mentions(v_body);
  DELETE FROM public.board_post_mentions WHERE post_id = p.id AND NOT (user_id = ANY (v_men));
  FOREACH m IN ARRAY v_men LOOP
    IF m <> v_me AND NOT public.board_is_blocked(v_me, m)
       AND NOT EXISTS (SELECT 1 FROM public.board_post_mentions x WHERE x.post_id = p.id AND x.user_id = m) THEN
      INSERT INTO public.board_post_mentions (post_id, user_id) VALUES (p.id, m) ON CONFLICT DO NOTHING;
      PERFORM public.board_notify(m, v_me, 'mention', p.id);
    END IF;
  END LOOP;
END; $$;

-- Soft delete: the row stays as an empty tombstone so replies keep their place in the thread.
CREATE OR REPLACE FUNCTION public.board_delete_post(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid(); p record;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'Sign in to use BMN Board'; END IF;
  SELECT * INTO p FROM public.board_posts WHERE id = p_id;
  IF NOT FOUND OR p.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'Post not found'; END IF;
  IF p.author_id <> v_me AND NOT public.is_bmn_owner() THEN RAISE EXCEPTION 'You can only delete your own posts'; END IF;
  UPDATE public.board_posts SET body = '', media = '[]'::jsonb, deleted_at = now() WHERE id = p.id;
  DELETE FROM public.board_post_tags     WHERE post_id = p.id;
  DELETE FROM public.board_post_mentions WHERE post_id = p.id;
  DELETE FROM public.board_notifications WHERE post_id = p.id;
END; $$;

-- Shared guard for like / repost / bookmark
CREATE OR REPLACE FUNCTION public.board_assert_interactable(p_post uuid, p_me uuid)
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
DECLARE p record;
BEGIN
  SELECT id, author_id, deleted_at, status INTO p FROM public.board_posts WHERE id = p_post;
  IF NOT FOUND OR p.deleted_at IS NOT NULL OR p.status <> 'published' OR NOT public.board_can_view(p.author_id) THEN
    RAISE EXCEPTION 'Post not available';
  END IF;
  IF public.board_is_blocked(p_me, p.author_id) THEN RAISE EXCEPTION 'Post not available'; END IF;
  RETURN p.author_id;
END; $$;

CREATE OR REPLACE FUNCTION public.board_set_like(p_post uuid, p_on boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := public.board_assert_active(); v_author uuid; v_new int;
BEGIN
  IF p_on THEN
    v_author := public.board_assert_interactable(p_post, v_me);
    INSERT INTO public.board_likes (post_id, user_id) VALUES (p_post, v_me) ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_new = ROW_COUNT;
    IF v_new > 0 THEN PERFORM public.board_notify(v_author, v_me, 'like', p_post); END IF;
  ELSE
    DELETE FROM public.board_likes WHERE post_id = p_post AND user_id = v_me;
  END IF;
END; $$;

CREATE OR REPLACE FUNCTION public.board_set_repost(p_post uuid, p_on boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := public.board_assert_active(); v_author uuid; v_new int;
BEGIN
  IF p_on THEN
    v_author := public.board_assert_interactable(p_post, v_me);
    INSERT INTO public.board_reposts (post_id, user_id) VALUES (p_post, v_me) ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_new = ROW_COUNT;
    IF v_new > 0 THEN PERFORM public.board_notify(v_author, v_me, 'repost', p_post); END IF;
  ELSE
    DELETE FROM public.board_reposts WHERE post_id = p_post AND user_id = v_me;
  END IF;
END; $$;

CREATE OR REPLACE FUNCTION public.board_set_bookmark(p_post uuid, p_on boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := public.board_assert_active(); v_author uuid;
BEGIN
  IF p_on THEN
    v_author := public.board_assert_interactable(p_post, v_me);
    INSERT INTO public.board_bookmarks (post_id, user_id) VALUES (p_post, v_me) ON CONFLICT DO NOTHING;
  ELSE
    DELETE FROM public.board_bookmarks WHERE post_id = p_post AND user_id = v_me;
  END IF;
END; $$;

-- A view = one signed-in person other than the author opening the post, counted once.
CREATE OR REPLACE FUNCTION public.board_record_view(p_post uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid(); v_author uuid;
BEGIN
  IF v_me IS NULL THEN RETURN; END IF;
  SELECT author_id INTO v_author FROM public.board_posts
   WHERE id = p_post AND deleted_at IS NULL AND status = 'published';
  IF v_author IS NULL OR v_author = v_me OR NOT public.board_can_view(v_author) OR public.board_is_blocked(v_me, v_author) THEN RETURN; END IF;
  INSERT INTO public.board_views (post_id, viewer_id) VALUES (p_post, v_me) ON CONFLICT DO NOTHING;
END; $$;

CREATE OR REPLACE FUNCTION public.board_report_post(p_post uuid, p_reason text, p_details text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := public.board_assert_active(); p record; v_id uuid;
BEGIN
  IF p_reason NOT IN ('nudity','sexual_content','violence','harassment','hate','spam','scam','copyright','other') THEN
    RAISE EXCEPTION 'Choose a reason for the report';
  END IF;
  SELECT id, author_id, deleted_at, status INTO p FROM public.board_posts WHERE id = p_post;
  IF NOT FOUND OR p.deleted_at IS NOT NULL OR NOT public.board_can_view(p.author_id) THEN RAISE EXCEPTION 'Post not available'; END IF;
  IF p.author_id = v_me THEN RAISE EXCEPTION 'You cannot report your own post'; END IF;
  SELECT r.id INTO v_id FROM public.content_reports r
   WHERE r.reporter_id = v_me AND r.board_post_id = p_post AND r.status = 'pending' LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  INSERT INTO public.content_reports (reporter_id, reported_user_id, reason, details, board_post_id)
  VALUES (v_me, p.author_id, p_reason, left(p_details, 1000), p_post) RETURNING id INTO v_id;
  RETURN v_id;
END; $$;

CREATE OR REPLACE FUNCTION public.board_mark_notifications_read(p_ids uuid[] DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid(); n int;
BEGIN
  IF v_me IS NULL THEN RETURN 0; END IF;
  UPDATE public.board_notifications SET read_at = now()
   WHERE user_id = v_me AND read_at IS NULL AND (p_ids IS NULL OR id = ANY (p_ids));
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END; $$;

-- ---------------------------------------------------------------------
-- Read RPCs (SECURITY INVOKER: row level security above decides what each caller may see)
-- ---------------------------------------------------------------------
-- modes: 'latest' (everyone, newest first) | 'following' (people I follow + their reposts + mine) | 'for_you' (recent, ranked by real engagement)
CREATE OR REPLACE FUNCTION public.board_feed(p_mode text DEFAULT 'for_you', p_limit integer DEFAULT 30,
                                             p_before timestamptz DEFAULT NULL, p_offset integer DEFAULT 0)
RETURNS TABLE (post_id uuid, sort_at timestamptz, reposted_by uuid)
LANGUAGE plpgsql STABLE SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid(); v_lim int := LEAST(GREATEST(COALESCE(p_limit, 30), 1), 50);
BEGIN
  IF p_mode = 'following' THEN
    IF v_me IS NULL THEN RETURN; END IF;
    RETURN QUERY
    SELECT d.post_id, d.sort_at, d.reposted_by FROM (
      SELECT DISTINCT ON (s.post_id) s.post_id, s.sort_at, s.reposted_by FROM (
        SELECT p.id AS post_id, p.created_at AS sort_at, NULL::uuid AS reposted_by
          FROM public.board_posts p
         WHERE p.parent_id IS NULL AND p.deleted_at IS NULL AND p.status = 'published'
           AND (p.author_id = v_me OR p.author_id IN (SELECT f.following_id FROM public.follows f WHERE f.follower_id = v_me))
           AND (p_before IS NULL OR p.created_at < p_before)
        UNION ALL
        SELECT r.post_id, r.created_at, r.user_id
          FROM public.board_reposts r JOIN public.board_posts p ON p.id = r.post_id
         WHERE p.deleted_at IS NULL AND p.status = 'published'
           AND r.user_id IN (SELECT f.following_id FROM public.follows f WHERE f.follower_id = v_me)
           AND (p_before IS NULL OR r.created_at < p_before)
      ) s
      WHERE NOT EXISTS (SELECT 1 FROM public.board_posts q, public.user_blocks k
                         WHERE q.id = s.post_id AND k.user_id = v_me AND k.target_id = q.author_id AND k.kind = 'mute')
      ORDER BY s.post_id, s.sort_at DESC
    ) d ORDER BY d.sort_at DESC LIMIT v_lim;
  ELSIF p_mode = 'latest' THEN
    RETURN QUERY
    SELECT p.id, p.created_at, NULL::uuid FROM public.board_posts p
     WHERE p.parent_id IS NULL AND p.deleted_at IS NULL AND p.status = 'published'
       AND (p_before IS NULL OR p.created_at < p_before)
       AND (v_me IS NULL OR NOT EXISTS (SELECT 1 FROM public.user_blocks k WHERE k.user_id = v_me AND k.target_id = p.author_id AND k.kind = 'mute'))
     ORDER BY p.created_at DESC, p.id DESC LIMIT v_lim;
  ELSE
    RETURN QUERY
    SELECT p.id, p.created_at, NULL::uuid FROM public.board_posts p
     WHERE p.parent_id IS NULL AND p.deleted_at IS NULL AND p.status = 'published'
       AND p.created_at > now() - interval '90 days'
       AND (v_me IS NULL OR NOT EXISTS (SELECT 1 FROM public.user_blocks k WHERE k.user_id = v_me AND k.target_id = p.author_id AND k.kind = 'mute'))
     ORDER BY ((1 + p.like_count + 2 * p.repost_count + 2 * p.quote_count + 1.5 * p.reply_count)
               * CASE WHEN v_me IS NOT NULL AND EXISTS (SELECT 1 FROM public.follows f WHERE f.follower_id = v_me AND f.following_id = p.author_id) THEN 1.6 ELSE 1.0 END
               / power(extract(epoch FROM (now() - p.created_at)) / 3600.0 + 2.0, 1.4)) DESC, p.created_at DESC, p.id
     OFFSET GREATEST(COALESCE(p_offset, 0), 0) LIMIT v_lim;
  END IF;
END; $$;

CREATE OR REPLACE FUNCTION public.board_ancestors(p_post uuid)
RETURNS TABLE (id uuid, depth integer)
LANGUAGE sql STABLE SET search_path TO '' AS $$
  WITH RECURSIVE up AS (
    SELECT p.id, p.parent_id, 0 AS depth FROM public.board_posts p WHERE p.id = p_post
    UNION ALL
    SELECT p.id, p.parent_id, up.depth + 1 FROM public.board_posts p JOIN up ON p.id = up.parent_id WHERE up.depth < 30
  ) SELECT up.id, up.depth FROM up WHERE up.id <> p_post ORDER BY up.depth DESC;
$$;

CREATE OR REPLACE FUNCTION public.board_tag_posts(p_tag text, p_limit integer DEFAULT 30, p_before timestamptz DEFAULT NULL)
RETURNS TABLE (post_id uuid, sort_at timestamptz)
LANGUAGE sql STABLE SET search_path TO '' AS $$
  SELECT p.id, p.created_at FROM public.board_post_tags t JOIN public.board_posts p ON p.id = t.post_id
   WHERE t.tag = lower(btrim(p_tag, '# ')) AND p.deleted_at IS NULL AND p.status = 'published'
     AND (p_before IS NULL OR p.created_at < p_before)
   ORDER BY p.created_at DESC LIMIT LEAST(GREATEST(COALESCE(p_limit, 30), 1), 50);
$$;

CREATE OR REPLACE FUNCTION public.board_search_posts(p_q text, p_limit integer DEFAULT 30, p_before timestamptz DEFAULT NULL)
RETURNS TABLE (post_id uuid, sort_at timestamptz)
LANGUAGE sql STABLE SET search_path TO '' AS $$
  SELECT p.id, p.created_at FROM public.board_posts p
   WHERE length(btrim(COALESCE(p_q, ''))) >= 2 AND p.deleted_at IS NULL AND p.status = 'published'
     AND p.body ILIKE '%' || replace(replace(replace(btrim(p_q), '\', '\\'), '%', '\%'), '_', '\_') || '%'
     AND (p_before IS NULL OR p.created_at < p_before)
   ORDER BY p.created_at DESC LIMIT LEAST(GREATEST(COALESCE(p_limit, 30), 1), 50);
$$;

CREATE OR REPLACE FUNCTION public.board_trending(p_hours integer DEFAULT 72, p_limit integer DEFAULT 10)
RETURNS TABLE (tag text, posts bigint, authors bigint)
LANGUAGE sql STABLE SET search_path TO '' AS $$
  SELECT t.tag, count(*)::bigint, count(DISTINCT p.author_id)::bigint
    FROM public.board_post_tags t JOIN public.board_posts p ON p.id = t.post_id
   WHERE p.deleted_at IS NULL AND p.status = 'published'
     AND t.created_at > now() - make_interval(hours => LEAST(GREATEST(COALESCE(p_hours, 72), 1), 720))
   GROUP BY t.tag ORDER BY count(*) DESC, count(DISTINCT p.author_id) DESC, t.tag
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 10), 1), 30);
$$;

-- People active on Board that I do not follow yet (no blocked pairs, not me). DEFINER so the reverse block stays private.
CREATE OR REPLACE FUNCTION public.board_suggested_people(p_limit integer DEFAULT 8)
RETURNS TABLE (user_id uuid, posts bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_me uuid := auth.uid();
BEGIN
  RETURN QUERY
  SELECT p.author_id, count(*)::bigint FROM public.board_posts p
   WHERE p.deleted_at IS NULL AND p.status = 'published' AND p.parent_id IS NULL
     AND p.created_at > now() - interval '30 days'
     AND (v_me IS NULL OR (p.author_id <> v_me
          AND NOT EXISTS (SELECT 1 FROM public.follows f WHERE f.follower_id = v_me AND f.following_id = p.author_id)
          AND NOT public.board_is_blocked(v_me, p.author_id)
          AND NOT public.board_is_muted_by(v_me, p.author_id)))
     AND public.board_can_view(p.author_id)
   GROUP BY p.author_id ORDER BY count(*) DESC, max(p.created_at) DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 8), 1), 20);
END; $$;

-- ---------------------------------------------------------------------
-- Function privileges: internal helpers are not callable by clients
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.board_is_blocked(uuid, uuid), public.board_is_muted_by(uuid, uuid), public.board_assert_active(),
  public.board_reply_mode(uuid), public.board_clean_media(jsonb), public.board_extract_tags(text), public.board_extract_mentions(text),
  public.board_notify(uuid, uuid, text, uuid), public.board_assert_interactable(uuid, uuid), public.board_count_likes(),
  public.board_count_reposts(), public.board_count_views(), public.board_count_threads() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.board_create_post(text, jsonb, uuid, uuid), public.board_edit_post(uuid, text, jsonb),
  public.board_delete_post(uuid), public.board_set_like(uuid, boolean), public.board_set_repost(uuid, boolean),
  public.board_set_bookmark(uuid, boolean), public.board_record_view(uuid), public.board_report_post(uuid, text, text),
  public.board_mark_notifications_read(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.board_create_post(text, jsonb, uuid, uuid), public.board_edit_post(uuid, text, jsonb),
  public.board_delete_post(uuid), public.board_set_like(uuid, boolean), public.board_set_repost(uuid, boolean),
  public.board_set_bookmark(uuid, boolean), public.board_record_view(uuid), public.board_report_post(uuid, text, text),
  public.board_mark_notifications_read(uuid[]) TO authenticated;

REVOKE ALL ON FUNCTION public.board_can_view(uuid), public.board_feed(text, integer, timestamptz, integer), public.board_ancestors(uuid),
  public.board_tag_posts(text, integer, timestamptz), public.board_search_posts(text, integer, timestamptz),
  public.board_trending(integer, integer), public.board_suggested_people(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.board_can_view(uuid), public.board_feed(text, integer, timestamptz, integer), public.board_ancestors(uuid),
  public.board_tag_posts(text, integer, timestamptz), public.board_search_posts(text, integer, timestamptz),
  public.board_trending(integer, integer), public.board_suggested_people(integer) TO anon, authenticated;

-- ROLLBACK-BEGIN
-- DROP FUNCTION IF EXISTS public.board_suggested_people(integer);
-- DROP FUNCTION IF EXISTS public.board_trending(integer, integer);
-- DROP FUNCTION IF EXISTS public.board_search_posts(text, integer, timestamptz);
-- DROP FUNCTION IF EXISTS public.board_tag_posts(text, integer, timestamptz);
-- DROP FUNCTION IF EXISTS public.board_ancestors(uuid);
-- DROP FUNCTION IF EXISTS public.board_feed(text, integer, timestamptz, integer);
-- DROP FUNCTION IF EXISTS public.board_mark_notifications_read(uuid[]);
-- DROP FUNCTION IF EXISTS public.board_report_post(uuid, text, text);
-- DROP FUNCTION IF EXISTS public.board_record_view(uuid);
-- DROP FUNCTION IF EXISTS public.board_set_bookmark(uuid, boolean);
-- DROP FUNCTION IF EXISTS public.board_set_repost(uuid, boolean);
-- DROP FUNCTION IF EXISTS public.board_set_like(uuid, boolean);
-- DROP FUNCTION IF EXISTS public.board_assert_interactable(uuid, uuid);
-- DROP FUNCTION IF EXISTS public.board_delete_post(uuid);
-- DROP FUNCTION IF EXISTS public.board_edit_post(uuid, text, jsonb);
-- DROP FUNCTION IF EXISTS public.board_create_post(text, jsonb, uuid, uuid);
-- ALTER TABLE public.content_reports DROP COLUMN IF EXISTS board_post_id;
-- DROP TABLE IF EXISTS public.board_post_edits;
-- DROP TABLE IF EXISTS public.board_notifications;
-- DROP TABLE IF EXISTS public.board_views;
-- DROP TABLE IF EXISTS public.board_post_mentions;
-- DROP TABLE IF EXISTS public.board_post_tags;
-- DROP TABLE IF EXISTS public.board_bookmarks;
-- DROP TABLE IF EXISTS public.board_reposts;
-- DROP TABLE IF EXISTS public.board_likes;
-- DROP TABLE IF EXISTS public.board_posts;
-- DROP FUNCTION IF EXISTS public.board_can_view(uuid);
-- DROP FUNCTION IF EXISTS public.board_notify(uuid, uuid, text, uuid);
-- DROP FUNCTION IF EXISTS public.board_extract_mentions(text);
-- DROP FUNCTION IF EXISTS public.board_extract_tags(text);
-- DROP FUNCTION IF EXISTS public.board_clean_media(jsonb);
-- DROP FUNCTION IF EXISTS public.board_reply_mode(uuid);
-- DROP FUNCTION IF EXISTS public.board_assert_active();
-- DROP FUNCTION IF EXISTS public.board_is_muted_by(uuid, uuid);
-- DROP FUNCTION IF EXISTS public.board_is_blocked(uuid, uuid);
-- DROP FUNCTION IF EXISTS public.board_count_threads();
-- DROP FUNCTION IF EXISTS public.board_count_views();
-- DROP FUNCTION IF EXISTS public.board_count_reposts();
-- DROP FUNCTION IF EXISTS public.board_count_likes();
-- ROLLBACK-END
-- NOTE: rolling back B1 deletes every Board post, like, repost, bookmark and notification (the tables are dropped). Export first if any exist.
-- NOTE: the report column is dropped; existing content_reports rows are kept (their board_post_id value is lost).
