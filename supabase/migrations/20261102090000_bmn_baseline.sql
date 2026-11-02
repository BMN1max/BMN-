--
-- PostgreSQL database dump
--


-- Dumped from database version 17.11
-- Dumped by pg_dump version 17.11 (Ubuntu 17.11-1.pgdg24.04+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: bmn_clear_conversation(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.bmn_clear_conversation(p_peer uuid) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  v_user_id uuid;
  v_updated integer;
BEGIN
  v_user_id := auth.uid();

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_peer IS NULL OR p_peer = v_user_id THEN
    RAISE EXCEPTION 'Invalid conversation participant';
  END IF;

  UPDATE public.messages
  SET deleted_by_sender = CASE
        WHEN sender_id = v_user_id THEN true
        ELSE deleted_by_sender
      END,
      deleted_by_recipient = CASE
        WHEN recipient_id = v_user_id THEN true
        ELSE deleted_by_recipient
      END
  WHERE (sender_id = v_user_id AND recipient_id = p_peer)
     OR (sender_id = p_peer AND recipient_id = v_user_id);

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  RETURN v_updated;
END;
$$;


--
-- Name: bmn_delete_my_account(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.bmn_delete_my_account() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := auth.uid();

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  DELETE FROM public.comment_likes
  WHERE user_id = v_user_id;

  DELETE FROM public.likes
  WHERE user_id = v_user_id;

  DELETE FROM public.post_saves
  WHERE user_id = v_user_id;

  DELETE FROM public.saves
  WHERE user_id = v_user_id;

  DELETE FROM public.post_reposts
  WHERE user_id = v_user_id;

  DELETE FROM public.post_views
  WHERE user_id = v_user_id;

  DELETE FROM public.follows
  WHERE follower_id = v_user_id
     OR following_id = v_user_id;

  DELETE FROM public.content_reports
  WHERE reporter_id = v_user_id
     OR reported_user_id = v_user_id;

  DELETE FROM public.notifications
  WHERE user_id = v_user_id
     OR actor_id = v_user_id;

  DELETE FROM public.moderation_actions
  WHERE admin_id = v_user_id
     OR target_user_id = v_user_id;

  DELETE FROM public.bmn_verified_users
  WHERE user_id = v_user_id;

  DELETE FROM public.bmn_verification_requests
  WHERE user_id = v_user_id;

  DELETE FROM public.bmn_user_moderation
  WHERE user_id = v_user_id;

  DELETE FROM public.bmn_admins
  WHERE user_id = v_user_id;

  DELETE FROM public.comments
  WHERE user_id = v_user_id;

  DELETE FROM public.posts
  WHERE user_id = v_user_id;

  DELETE FROM public.messages
  WHERE sender_id = v_user_id
     OR recipient_id = v_user_id;

  DELETE FROM public.profiles
  WHERE id = v_user_id;

  DELETE FROM auth.users
  WHERE id = v_user_id;
END;
$$;


--
-- Name: bmn_enforce_interaction_account_status(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.bmn_enforce_interaction_account_status() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  v_actor uuid;
  v_owner uuid;
  v_status text;
  v_expires_at timestamptz;
BEGIN
  -- Allow trusted service-role operations
  IF auth.role() = 'service_role' THEN
    RETURN NEW;
  END IF;

  v_actor := auth.uid();

  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  v_owner := CASE TG_TABLE_NAME
    WHEN 'comments' THEN NEW.user_id
    WHEN 'likes' THEN NEW.user_id
    WHEN 'follows' THEN NEW.follower_id
    WHEN 'messages' THEN NEW.sender_id
  END;

  IF v_owner IS DISTINCT FROM v_actor THEN
    RAISE EXCEPTION 'You can only act as your own account';
  END IF;

  SELECT status, expires_at
  INTO v_status, v_expires_at
  FROM public.bmn_user_moderation
  WHERE user_id = v_actor;

  IF v_status = 'banned'
     OR (
       v_status = 'suspended'
       AND (v_expires_at IS NULL OR v_expires_at > now())
     ) THEN
    RAISE EXCEPTION 'Your BMN account is restricted';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: bmn_enforce_post_account_status(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.bmn_enforce_post_account_status() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  v_actor uuid;
  v_status text;
  v_expires_at timestamptz;
  v_is_owner boolean;
BEGIN
  IF auth.role() = 'service_role' THEN
    RETURN NEW;
  END IF;

  v_actor := auth.uid();

  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  v_is_owner := public.is_bmn_owner();

  -- Only the post's creator or BMN owner can change it.
  IF NOT v_is_owner THEN
    IF NEW.user_id IS DISTINCT FROM v_actor THEN
      RAISE EXCEPTION 'You can only manage your own posts';
    END IF;

    IF TG_OP = 'UPDATE'
       AND OLD.user_id IS DISTINCT FROM v_actor THEN
      RAISE EXCEPTION 'You cannot change another user''s post';
    END IF;

    IF NEW.status = 'removed' THEN
      RAISE EXCEPTION 'Only BMN owners can remove posts';
    END IF;
  END IF;

  -- Owners can perform moderation actions.
  IF v_is_owner THEN
    RETURN NEW;
  END IF;

  SELECT status, expires_at
  INTO v_status, v_expires_at
  FROM public.bmn_user_moderation
  WHERE user_id = v_actor;

  IF v_status = 'banned'
     OR (
       v_status = 'suspended'
       AND (v_expires_at IS NULL OR v_expires_at > now())
     ) THEN
    RAISE EXCEPTION 'Your BMN account is restricted';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: bmn_mark_messages_read(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.bmn_mark_messages_read(p_sender_id uuid) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  v_user_id uuid;
  v_updated integer;
BEGIN
  v_user_id := auth.uid();

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  UPDATE public.messages
  SET read_at = now()
  WHERE sender_id = p_sender_id
    AND recipient_id = v_user_id
    AND read_at IS NULL
    AND deleted_by_recipient = false;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  RETURN v_updated;
END;
$$;


--
-- Name: bmn_my_account_status(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.bmn_my_account_status() RETURNS TABLE(status text, reason text, expires_at timestamp with time zone)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  SELECT
    CASE
      WHEN m.user_id IS NULL THEN 'active'
      WHEN m.status = 'suspended'
        AND m.expires_at IS NOT NULL
        AND m.expires_at <= now() THEN 'active'
      ELSE m.status
    END,
    CASE
      WHEN m.status = 'suspended'
        AND m.expires_at IS NOT NULL
        AND m.expires_at <= now() THEN NULL
      ELSE m.reason
    END,
    m.expires_at
  FROM (SELECT auth.uid() AS uid) u
  LEFT JOIN public.bmn_user_moderation m
    ON m.user_id = u.uid;
$$;


--
-- Name: bmn_remove_post(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.bmn_remove_post(p_post_id uuid, p_reason text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  v_admin_id uuid;
  v_target_user_id uuid;
BEGIN
  v_admin_id := auth.uid();

  IF v_admin_id IS NULL OR NOT public.is_bmn_owner() THEN
    RAISE EXCEPTION 'Owner permission required';
  END IF;

  SELECT user_id
  INTO v_target_user_id
  FROM public.posts
  WHERE id = p_post_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Post not found';
  END IF;

  UPDATE public.posts
  SET status = 'removed',
      updated_at = now()
  WHERE id = p_post_id;

  INSERT INTO public.moderation_actions (
    admin_id,
    target_user_id,
    post_id,
    action,
    reason
  )
  VALUES (
    v_admin_id,
    v_target_user_id,
    p_post_id,
    'post_removed',
    COALESCE(NULLIF(trim(p_reason), ''), 'Removed by BMN owner')
  );
END;
$$;


--
-- Name: bmn_restore_post(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.bmn_restore_post(p_post_id uuid, p_reason text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  v_admin_id uuid;
  v_target_user_id uuid;
BEGIN
  v_admin_id := auth.uid();

  IF v_admin_id IS NULL OR NOT public.is_bmn_owner() THEN
    RAISE EXCEPTION 'Owner permission required';
  END IF;

  SELECT user_id
  INTO v_target_user_id
  FROM public.posts
  WHERE id = p_post_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Post not found';
  END IF;

  UPDATE public.posts
  SET status = 'published',
      updated_at = now()
  WHERE id = p_post_id
    AND status = 'removed';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Post is not currently removed';
  END IF;

  INSERT INTO public.moderation_actions (
    admin_id,
    target_user_id,
    post_id,
    action,
    reason
  )
  VALUES (
    v_admin_id,
    v_target_user_id,
    p_post_id,
    'post_restored',
    COALESCE(NULLIF(trim(p_reason), ''), 'Restored by BMN owner')
  );
END;
$$;


--
-- Name: bmn_review_verification(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.bmn_review_verification(p_request_id uuid, p_decision text, p_review_note text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  v_admin_id uuid;
  v_user_id uuid;
BEGIN
  v_admin_id := auth.uid();

  IF v_admin_id IS NULL OR NOT public.is_bmn_owner() THEN
    RAISE EXCEPTION 'Owner permission required';
  END IF;

  IF lower(p_decision) NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Decision must be approved or rejected';
  END IF;

  SELECT user_id
  INTO v_user_id
  FROM public.bmn_verification_requests
  WHERE id = p_request_id
    AND status = 'pending'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pending verification request not found';
  END IF;

  UPDATE public.bmn_verification_requests
  SET status = lower(p_decision),
      reviewed_at = now(),
      reviewed_by = v_admin_id,
      review_note = p_review_note
  WHERE id = p_request_id;

  IF lower(p_decision) = 'approved' THEN
    INSERT INTO public.bmn_verified_users (
      user_id,
      verified_at,
      verified_by,
      verification_note
    )
    VALUES (
      v_user_id,
      now(),
      v_admin_id,
      p_review_note
    )
    ON CONFLICT (user_id)
    DO UPDATE SET
      verified_at = EXCLUDED.verified_at,
      verified_by = EXCLUDED.verified_by,
      verification_note = EXCLUDED.verification_note;
  ELSE
    DELETE FROM public.bmn_verified_users
    WHERE user_id = v_user_id;
  END IF;
END;
$$;


--
-- Name: bmn_revoke_verification(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.bmn_revoke_verification(p_user_id uuid, p_reason text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  v_admin_id uuid;
BEGIN
  v_admin_id := auth.uid();

  IF v_admin_id IS NULL OR NOT public.is_bmn_owner() THEN
    RAISE EXCEPTION 'Owner permission required';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'User ID is required';
  END IF;

  DELETE FROM public.bmn_verified_users
  WHERE user_id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User is not currently verified';
  END IF;

  INSERT INTO public.moderation_actions (
    admin_id,
    target_user_id,
    action,
    reason
  )
  VALUES (
    v_admin_id,
    p_user_id,
    'warning',
    COALESCE(
      NULLIF(trim(p_reason), ''),
      'Verification revoked by BMN owner'
    )
  );
END;
$$;


--
-- Name: bmn_set_badge_level(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.bmn_set_badge_level(p_user_id uuid, p_badge_level text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  v_admin_id uuid;
BEGIN
  v_admin_id := auth.uid();

  IF v_admin_id IS NULL OR NOT public.is_bmn_owner() THEN
    RAISE EXCEPTION 'Owner permission required';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'User ID is required';
  END IF;

  IF lower(p_badge_level) NOT IN ('standard', 'creator', 'official') THEN
    RAISE EXCEPTION 'Invalid badge level';
  END IF;

  UPDATE public.bmn_verified_users
  SET badge_level = lower(p_badge_level)
  WHERE user_id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User is not verified';
  END IF;
END;
$$;


--
-- Name: bmn_touch_presence(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.bmn_touch_presence() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := auth.uid();

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  UPDATE public.profiles
  SET last_seen_at = now()
  WHERE id = v_user_id;
END;
$$;


--
-- Name: handle_new_bmn_user(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_new_bmn_user() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  v_display_name text;
  v_username text;
BEGIN
  v_display_name := COALESCE(
    NULLIF(trim(NEW.raw_user_meta_data ->> 'display_name'), ''),
    NULLIF(trim(NEW.raw_user_meta_data ->> 'full_name'), ''),
    NULLIF(trim(NEW.raw_user_meta_data ->> 'name'), ''),
    NULLIF(split_part(COALESCE(NEW.email, ''), '@', 1), ''),
    'BMN Member'
  );

  v_username := 'user_' || left(replace(NEW.id::text, '-', ''), 8);

  INSERT INTO public.profiles (
    id,
    username,
    display_name,
    created_at,
    updated_at
  )
  VALUES (
    NEW.id,
    v_username,
    v_display_name,
    now(),
    now()
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
END;
$$;


--
-- Name: increment_post_view_once(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.increment_post_view_once(p_post_id uuid) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  v_user_id uuid;
  v_views bigint;
BEGIN
  v_user_id := auth.uid();

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  INSERT INTO public.post_views (post_id, user_id)
  VALUES (p_post_id, v_user_id)
  ON CONFLICT (post_id, user_id) DO NOTHING;

  IF FOUND THEN
    UPDATE public.posts
    SET views = views + 1
    WHERE id = p_post_id;
  END IF;

  SELECT views
  INTO v_views
  FROM public.posts
  WHERE id = p_post_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Post not found';
  END IF;

  RETURN v_views;
END;
$$;


--
-- Name: is_bmn_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_bmn_owner() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.bmn_admins
    WHERE user_id = (SELECT auth.uid())
      AND lower(role) = 'owner'
  );
$$;


--
-- Name: rls_auto_enable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rls_auto_enable() RETURNS event_trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
  tbl name;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        SELECT c.relname INTO tbl FROM pg_catalog.pg_class c WHERE c.oid = cmd.objid;
        EXECUTE format('alter table if exists %I.%I enable row level security', cmd.schema_name, tbl);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: bmn_admins; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bmn_admins (
    user_id uuid NOT NULL,
    role text DEFAULT 'moderator'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT bmn_admins_role_check CHECK ((role = ANY (ARRAY['owner'::text, 'admin'::text, 'moderator'::text])))
);


--
-- Name: bmn_user_moderation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bmn_user_moderation (
    user_id uuid NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    reason text,
    expires_at timestamp with time zone,
    updated_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT bmn_user_moderation_status_check CHECK ((status = ANY (ARRAY['active'::text, 'suspended'::text, 'banned'::text])))
);


--
-- Name: bmn_verification_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bmn_verification_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    request_reason text NOT NULL,
    evidence_url text,
    status text DEFAULT 'pending'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    reviewed_at timestamp with time zone,
    reviewed_by uuid,
    review_note text,
    CONSTRAINT bmn_verification_requests_request_reason_check CHECK (((char_length(TRIM(BOTH FROM request_reason)) >= 20) AND (char_length(TRIM(BOTH FROM request_reason)) <= 2000))),
    CONSTRAINT bmn_verification_requests_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'rejected'::text, 'revoked'::text])))
);


--
-- Name: bmn_verified_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bmn_verified_users (
    user_id uuid NOT NULL,
    verified_at timestamp with time zone DEFAULT now() NOT NULL,
    verified_by uuid NOT NULL,
    verification_note text,
    badge_level text DEFAULT 'standard'::text NOT NULL,
    CONSTRAINT bmn_verified_users_badge_level_check CHECK ((badge_level = ANY (ARRAY['standard'::text, 'gold'::text])))
);


--
-- Name: comment_likes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.comment_likes (
    user_id uuid DEFAULT auth.uid() NOT NULL,
    comment_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.comments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    post_id uuid NOT NULL,
    body text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    content text
);


--
-- Name: content_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.content_reports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    reporter_id uuid,
    post_id uuid,
    reported_user_id uuid,
    reason text NOT NULL,
    details text,
    status text DEFAULT 'pending'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT content_reports_reason_check CHECK ((reason = ANY (ARRAY['nudity'::text, 'sexual_content'::text, 'violence'::text, 'harassment'::text, 'hate'::text, 'spam'::text, 'scam'::text, 'copyright'::text, 'other'::text]))),
    CONSTRAINT content_reports_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'reviewing'::text, 'action_taken'::text, 'dismissed'::text])))
);


--
-- Name: follows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.follows (
    follower_id uuid NOT NULL,
    following_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT follows_check CHECK ((follower_id <> following_id))
);


--
-- Name: likes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.likes (
    user_id uuid NOT NULL,
    post_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    sender_id uuid NOT NULL,
    recipient_id uuid NOT NULL,
    content text NOT NULL,
    read_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_by_sender boolean DEFAULT false NOT NULL,
    deleted_by_recipient boolean DEFAULT false NOT NULL,
    CONSTRAINT messages_content_check CHECK ((char_length(TRIM(BOTH FROM content)) > 0))
);


--
-- Name: moderation_actions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.moderation_actions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    admin_id uuid,
    target_user_id uuid,
    post_id uuid,
    action text NOT NULL,
    reason text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT moderation_actions_action_check CHECK ((action = ANY (ARRAY['warning'::text, 'post_removed'::text, 'post_restored'::text, 'user_suspended'::text, 'user_banned'::text, 'user_unbanned'::text])))
);


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    actor_id uuid,
    type text NOT NULL,
    post_id uuid,
    comment_id uuid,
    read boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    read_at timestamp with time zone
);


--
-- Name: post_like_counts; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.post_like_counts WITH (security_invoker='true') AS
 SELECT post_id,
    (count(*))::integer AS like_count
   FROM public.likes
  GROUP BY post_id;


--
-- Name: post_reposts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_reposts (
    user_id uuid DEFAULT auth.uid() NOT NULL,
    post_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: post_saves; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_saves (
    user_id uuid DEFAULT auth.uid() NOT NULL,
    post_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: post_views; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_views (
    post_id uuid NOT NULL,
    user_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: posts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.posts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    title text DEFAULT 'Community post'::text NOT NULL,
    caption text,
    video_url text,
    thumbnail_url text,
    category text,
    tags text[] DEFAULT '{}'::text[],
    status text DEFAULT 'published'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    views bigint DEFAULT 0 NOT NULL,
    content text,
    media_url text,
    CONSTRAINT posts_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'published'::text, 'removed'::text])))
);


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    id uuid NOT NULL,
    username text,
    display_name text,
    bio text,
    avatar_url text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone,
    website_url text,
    website text
);


--
-- Name: saves; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.saves (
    user_id uuid NOT NULL,
    post_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: bmn_admins bmn_admins_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bmn_admins
    ADD CONSTRAINT bmn_admins_pkey PRIMARY KEY (user_id);


--
-- Name: bmn_user_moderation bmn_user_moderation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bmn_user_moderation
    ADD CONSTRAINT bmn_user_moderation_pkey PRIMARY KEY (user_id);


--
-- Name: bmn_verification_requests bmn_verification_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bmn_verification_requests
    ADD CONSTRAINT bmn_verification_requests_pkey PRIMARY KEY (id);


--
-- Name: bmn_verified_users bmn_verified_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bmn_verified_users
    ADD CONSTRAINT bmn_verified_users_pkey PRIMARY KEY (user_id);


--
-- Name: comment_likes comment_likes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comment_likes
    ADD CONSTRAINT comment_likes_pkey PRIMARY KEY (user_id, comment_id);


--
-- Name: comments comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comments
    ADD CONSTRAINT comments_pkey PRIMARY KEY (id);


--
-- Name: content_reports content_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_reports
    ADD CONSTRAINT content_reports_pkey PRIMARY KEY (id);


--
-- Name: follows follows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.follows
    ADD CONSTRAINT follows_pkey PRIMARY KEY (follower_id, following_id);


--
-- Name: likes likes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.likes
    ADD CONSTRAINT likes_pkey PRIMARY KEY (user_id, post_id);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (id);


--
-- Name: moderation_actions moderation_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderation_actions
    ADD CONSTRAINT moderation_actions_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: post_reposts post_reposts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_reposts
    ADD CONSTRAINT post_reposts_pkey PRIMARY KEY (user_id, post_id);


--
-- Name: post_saves post_saves_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_saves
    ADD CONSTRAINT post_saves_pkey PRIMARY KEY (user_id, post_id);


--
-- Name: post_views post_views_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_views
    ADD CONSTRAINT post_views_pkey PRIMARY KEY (post_id, user_id);


--
-- Name: posts posts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.posts
    ADD CONSTRAINT posts_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_username_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_username_key UNIQUE (username);


--
-- Name: saves saves_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saves
    ADD CONSTRAINT saves_pkey PRIMARY KEY (user_id, post_id);


--
-- Name: bmn_one_pending_verification_per_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX bmn_one_pending_verification_per_user ON public.bmn_verification_requests USING btree (user_id) WHERE (status = 'pending'::text);


--
-- Name: comments_post_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX comments_post_created_idx ON public.comments USING btree (post_id, created_at);


--
-- Name: follows_following_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX follows_following_id_idx ON public.follows USING btree (following_id);


--
-- Name: likes_post_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX likes_post_id_idx ON public.likes USING btree (post_id);


--
-- Name: messages_inbox_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_inbox_idx ON public.messages USING btree (recipient_id, created_at DESC);


--
-- Name: messages_outbox_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_outbox_idx ON public.messages USING btree (sender_id, created_at DESC);


--
-- Name: messages_recipient_sender_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_recipient_sender_created_idx ON public.messages USING btree (recipient_id, sender_id, created_at);


--
-- Name: messages_sender_recipient_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_sender_recipient_created_idx ON public.messages USING btree (sender_id, recipient_id, created_at);


--
-- Name: notifications_user_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_user_created_idx ON public.notifications USING btree (user_id, created_at DESC);


--
-- Name: posts_category_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX posts_category_idx ON public.posts USING btree (category);


--
-- Name: posts_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX posts_created_at_idx ON public.posts USING btree (created_at DESC);


--
-- Name: posts_user_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX posts_user_created_idx ON public.posts USING btree (user_id, created_at DESC);


--
-- Name: profiles_username_lower_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX profiles_username_lower_idx ON public.profiles USING btree (lower(username)) WHERE (username IS NOT NULL);


--
-- Name: comments bmn_check_comment_account; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER bmn_check_comment_account BEFORE INSERT OR UPDATE ON public.comments FOR EACH ROW EXECUTE FUNCTION public.bmn_enforce_interaction_account_status();


--
-- Name: follows bmn_check_follow_account; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER bmn_check_follow_account BEFORE INSERT OR UPDATE ON public.follows FOR EACH ROW EXECUTE FUNCTION public.bmn_enforce_interaction_account_status();


--
-- Name: likes bmn_check_like_account; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER bmn_check_like_account BEFORE INSERT OR UPDATE ON public.likes FOR EACH ROW EXECUTE FUNCTION public.bmn_enforce_interaction_account_status();


--
-- Name: messages bmn_check_message_account; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER bmn_check_message_account BEFORE INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.bmn_enforce_interaction_account_status();


--
-- Name: posts bmn_check_post_account_status; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER bmn_check_post_account_status BEFORE INSERT OR UPDATE ON public.posts FOR EACH ROW EXECUTE FUNCTION public.bmn_enforce_post_account_status();


--
-- Name: bmn_admins bmn_admins_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bmn_admins
    ADD CONSTRAINT bmn_admins_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: bmn_user_moderation bmn_user_moderation_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bmn_user_moderation
    ADD CONSTRAINT bmn_user_moderation_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: bmn_user_moderation bmn_user_moderation_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bmn_user_moderation
    ADD CONSTRAINT bmn_user_moderation_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: bmn_verification_requests bmn_verification_requests_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bmn_verification_requests
    ADD CONSTRAINT bmn_verification_requests_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES auth.users(id);


--
-- Name: bmn_verification_requests bmn_verification_requests_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bmn_verification_requests
    ADD CONSTRAINT bmn_verification_requests_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: bmn_verified_users bmn_verified_users_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bmn_verified_users
    ADD CONSTRAINT bmn_verified_users_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: bmn_verified_users bmn_verified_users_verified_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bmn_verified_users
    ADD CONSTRAINT bmn_verified_users_verified_by_fkey FOREIGN KEY (verified_by) REFERENCES auth.users(id);


--
-- Name: comment_likes comment_likes_comment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comment_likes
    ADD CONSTRAINT comment_likes_comment_id_fkey FOREIGN KEY (comment_id) REFERENCES public.comments(id) ON DELETE CASCADE;


--
-- Name: comment_likes comment_likes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comment_likes
    ADD CONSTRAINT comment_likes_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: comments comments_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comments
    ADD CONSTRAINT comments_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.posts(id) ON DELETE CASCADE;


--
-- Name: comments comments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comments
    ADD CONSTRAINT comments_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: content_reports content_reports_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_reports
    ADD CONSTRAINT content_reports_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.posts(id) ON DELETE SET NULL;


--
-- Name: content_reports content_reports_reported_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_reports
    ADD CONSTRAINT content_reports_reported_user_id_fkey FOREIGN KEY (reported_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: content_reports content_reports_reporter_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_reports
    ADD CONSTRAINT content_reports_reporter_id_fkey FOREIGN KEY (reporter_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: follows follows_follower_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.follows
    ADD CONSTRAINT follows_follower_id_fkey FOREIGN KEY (follower_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: follows follows_following_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.follows
    ADD CONSTRAINT follows_following_id_fkey FOREIGN KEY (following_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: likes likes_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.likes
    ADD CONSTRAINT likes_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.posts(id) ON DELETE CASCADE;


--
-- Name: likes likes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.likes
    ADD CONSTRAINT likes_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: messages messages_recipient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_recipient_id_fkey FOREIGN KEY (recipient_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: messages messages_sender_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_sender_id_fkey FOREIGN KEY (sender_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: moderation_actions moderation_actions_admin_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderation_actions
    ADD CONSTRAINT moderation_actions_admin_id_fkey FOREIGN KEY (admin_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: moderation_actions moderation_actions_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderation_actions
    ADD CONSTRAINT moderation_actions_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.posts(id) ON DELETE SET NULL;


--
-- Name: moderation_actions moderation_actions_target_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderation_actions
    ADD CONSTRAINT moderation_actions_target_user_id_fkey FOREIGN KEY (target_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: notifications notifications_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: notifications notifications_comment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_comment_id_fkey FOREIGN KEY (comment_id) REFERENCES public.comments(id) ON DELETE CASCADE;


--
-- Name: notifications notifications_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.posts(id) ON DELETE CASCADE;


--
-- Name: notifications notifications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: post_reposts post_reposts_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_reposts
    ADD CONSTRAINT post_reposts_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.posts(id) ON DELETE CASCADE;


--
-- Name: post_reposts post_reposts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_reposts
    ADD CONSTRAINT post_reposts_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: post_saves post_saves_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_saves
    ADD CONSTRAINT post_saves_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.posts(id) ON DELETE CASCADE;


--
-- Name: post_saves post_saves_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_saves
    ADD CONSTRAINT post_saves_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: post_views post_views_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_views
    ADD CONSTRAINT post_views_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.posts(id) ON DELETE CASCADE;


--
-- Name: post_views post_views_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_views
    ADD CONSTRAINT post_views_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: posts posts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.posts
    ADD CONSTRAINT posts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: profiles profiles_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: saves saves_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saves
    ADD CONSTRAINT saves_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.posts(id) ON DELETE CASCADE;


--
-- Name: saves saves_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saves
    ADD CONSTRAINT saves_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: posts BMN owner can view all posts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "BMN owner can view all posts" ON public.posts FOR SELECT TO authenticated USING (public.is_bmn_owner());


--
-- Name: bmn_user_moderation BMN owners manage account restrictions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "BMN owners manage account restrictions" ON public.bmn_user_moderation TO authenticated USING (public.is_bmn_owner()) WITH CHECK (public.is_bmn_owner());


--
-- Name: bmn_admins BMN owners manage admin roles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "BMN owners manage admin roles" ON public.bmn_admins TO authenticated USING (public.is_bmn_owner()) WITH CHECK (public.is_bmn_owner());


--
-- Name: bmn_verification_requests BMN owners review verification requests; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "BMN owners review verification requests" ON public.bmn_verification_requests FOR UPDATE TO authenticated USING (public.is_bmn_owner()) WITH CHECK (public.is_bmn_owner());


--
-- Name: content_reports BMN owners update reports; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "BMN owners update reports" ON public.content_reports FOR UPDATE TO authenticated USING (public.is_bmn_owner()) WITH CHECK (public.is_bmn_owner());


--
-- Name: moderation_actions BMN owners view moderation history; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "BMN owners view moderation history" ON public.moderation_actions FOR SELECT TO authenticated USING (public.is_bmn_owner());


--
-- Name: content_reports BMN owners view reports; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "BMN owners view reports" ON public.content_reports FOR SELECT TO authenticated USING (public.is_bmn_owner());


--
-- Name: profiles BMN profiles are publicly viewable; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "BMN profiles are publicly viewable" ON public.profiles FOR SELECT TO authenticated, anon USING (true);


--
-- Name: messages Participants can view their messages; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Participants can view their messages" ON public.messages FOR SELECT TO authenticated USING ((((sender_id = ( SELECT auth.uid() AS uid)) AND (deleted_by_sender = false)) OR ((recipient_id = ( SELECT auth.uid() AS uid)) AND (deleted_by_recipient = false))));


--
-- Name: comment_likes Public can view comment likes; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Public can view comment likes" ON public.comment_likes FOR SELECT TO authenticated, anon USING (true);


--
-- Name: comments Public can view comments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Public can view comments" ON public.comments FOR SELECT TO authenticated, anon USING (true);


--
-- Name: follows Public can view follows; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Public can view follows" ON public.follows FOR SELECT TO authenticated, anon USING (true);


--
-- Name: likes Public can view likes; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Public can view likes" ON public.likes FOR SELECT TO authenticated, anon USING (true);


--
-- Name: post_reposts Public can view reposts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Public can view reposts" ON public.post_reposts FOR SELECT TO authenticated, anon USING (true);


--
-- Name: posts Published posts are publicly viewable; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Published posts are publicly viewable" ON public.posts FOR SELECT TO authenticated, anon USING (((status = 'published'::text) OR (user_id = ( SELECT auth.uid() AS uid))));


--
-- Name: comment_likes Users add their own comment likes; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users add their own comment likes" ON public.comment_likes FOR INSERT TO authenticated WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: likes Users can add their own likes; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can add their own likes" ON public.likes FOR INSERT TO authenticated WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: comments Users can create their own comments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can create their own comments" ON public.comments FOR INSERT TO authenticated WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: comments Users can delete their own comments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can delete their own comments" ON public.comments FOR DELETE TO authenticated USING ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: follows Users can follow as themselves; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can follow as themselves" ON public.follows FOR INSERT TO authenticated WITH CHECK ((follower_id = ( SELECT auth.uid() AS uid)));


--
-- Name: likes Users can remove their own likes; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can remove their own likes" ON public.likes FOR DELETE TO authenticated USING ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: follows Users can unfollow as themselves; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can unfollow as themselves" ON public.follows FOR DELETE TO authenticated USING ((follower_id = ( SELECT auth.uid() AS uid)));


--
-- Name: comments Users can update their own comments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can update their own comments" ON public.comments FOR UPDATE TO authenticated USING ((user_id = ( SELECT auth.uid() AS uid))) WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: saves Users create their own legacy saves; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users create their own legacy saves" ON public.saves FOR INSERT TO authenticated WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: post_saves Users create their own post saves; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users create their own post saves" ON public.post_saves FOR INSERT TO authenticated WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: posts Users create their own posts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users create their own posts" ON public.posts FOR INSERT TO authenticated WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: profiles Users create their own profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users create their own profile" ON public.profiles FOR INSERT TO authenticated WITH CHECK ((id = ( SELECT auth.uid() AS uid)));


--
-- Name: post_reposts Users create their own reposts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users create their own reposts" ON public.post_reposts FOR INSERT TO authenticated WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: saves Users delete their own legacy saves; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users delete their own legacy saves" ON public.saves FOR DELETE TO authenticated USING ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: post_saves Users delete their own post saves; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users delete their own post saves" ON public.post_saves FOR DELETE TO authenticated USING ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: posts Users delete their own posts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users delete their own posts" ON public.posts FOR DELETE TO authenticated USING ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: profiles Users delete their own profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users delete their own profile" ON public.profiles FOR DELETE TO authenticated USING ((id = ( SELECT auth.uid() AS uid)));


--
-- Name: post_reposts Users delete their own reposts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users delete their own reposts" ON public.post_reposts FOR DELETE TO authenticated USING ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: post_views Users record their own post views; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users record their own post views" ON public.post_views FOR INSERT TO authenticated WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: comment_likes Users remove their own comment likes; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users remove their own comment likes" ON public.comment_likes FOR DELETE TO authenticated USING ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: messages Users send messages as themselves; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users send messages as themselves" ON public.messages FOR INSERT TO authenticated WITH CHECK ((sender_id = ( SELECT auth.uid() AS uid)));


--
-- Name: content_reports Users submit their own reports; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users submit their own reports" ON public.content_reports FOR INSERT TO authenticated WITH CHECK ((reporter_id = ( SELECT auth.uid() AS uid)));


--
-- Name: bmn_verification_requests Users submit verification requests; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users submit verification requests" ON public.bmn_verification_requests FOR INSERT TO authenticated WITH CHECK (((user_id = ( SELECT auth.uid() AS uid)) AND (status = 'pending'::text) AND (reviewed_at IS NULL) AND (reviewed_by IS NULL) AND (review_note IS NULL)));


--
-- Name: notifications Users update their own notifications; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users update their own notifications" ON public.notifications FOR UPDATE TO authenticated USING ((user_id = ( SELECT auth.uid() AS uid))) WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: posts Users update their own posts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users update their own posts" ON public.posts FOR UPDATE TO authenticated USING ((user_id = ( SELECT auth.uid() AS uid))) WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: profiles Users update their own profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users update their own profile" ON public.profiles FOR UPDATE TO authenticated USING ((id = ( SELECT auth.uid() AS uid))) WITH CHECK ((id = ( SELECT auth.uid() AS uid)));


--
-- Name: saves Users view their own legacy saves; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users view their own legacy saves" ON public.saves FOR SELECT TO authenticated USING ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: notifications Users view their own notifications; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users view their own notifications" ON public.notifications FOR SELECT TO authenticated USING ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: post_saves Users view their own post saves; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users view their own post saves" ON public.post_saves FOR SELECT TO authenticated USING ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: post_views Users view their own post views; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users view their own post views" ON public.post_views FOR SELECT TO authenticated USING (((user_id = ( SELECT auth.uid() AS uid)) OR public.is_bmn_owner()));


--
-- Name: bmn_verification_requests Users view their own verification requests; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users view their own verification requests" ON public.bmn_verification_requests FOR SELECT TO authenticated USING (((user_id = ( SELECT auth.uid() AS uid)) OR public.is_bmn_owner()));


--
-- Name: bmn_verified_users Verified badges are publicly viewable; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Verified badges are publicly viewable" ON public.bmn_verified_users FOR SELECT TO authenticated, anon USING (true);


--
-- Name: bmn_admins; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.bmn_admins ENABLE ROW LEVEL SECURITY;

--
-- Name: bmn_user_moderation; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.bmn_user_moderation ENABLE ROW LEVEL SECURITY;

--
-- Name: bmn_verification_requests; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.bmn_verification_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: bmn_verified_users; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.bmn_verified_users ENABLE ROW LEVEL SECURITY;

--
-- Name: comment_likes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.comment_likes ENABLE ROW LEVEL SECURITY;

--
-- Name: comments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.comments ENABLE ROW LEVEL SECURITY;

--
-- Name: content_reports; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.content_reports ENABLE ROW LEVEL SECURITY;

--
-- Name: follows; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.follows ENABLE ROW LEVEL SECURITY;

--
-- Name: likes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.likes ENABLE ROW LEVEL SECURITY;

--
-- Name: messages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

--
-- Name: moderation_actions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.moderation_actions ENABLE ROW LEVEL SECURITY;

--
-- Name: notifications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

--
-- Name: post_reposts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.post_reposts ENABLE ROW LEVEL SECURITY;

--
-- Name: post_saves; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.post_saves ENABLE ROW LEVEL SECURITY;

--
-- Name: post_views; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.post_views ENABLE ROW LEVEL SECURITY;

--
-- Name: posts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.posts ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: saves; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.saves ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--


