-- BMN Global Spotlight — migration 003 (ADDITIVE; needs the owner's approval before it is run on production).
-- Adds: table bmn_spotlights, table bmn_spotlight_audit, and 7 functions. Changes NO existing table, row, policy or function.
-- Safe to run more than once. Undo with 003_bmn_spotlight.down.sql.
--
-- Security model
--   * Nobody can read or write the tables directly (RLS on, no policies, all table privileges revoked from anon/authenticated).
--   * Everyone (signed in or not) may call bmn_spotlight_active(): it returns only PUBLISHED items inside their start/end window.
--   * Only the BMN owner (public.is_bmn_owner(), from the baseline) may list, save, publish, pause or delete. Each call is audited.
--   * Link URLs must be https:// or an in-app path starting with a single "/". javascript:, data: etc. are rejected by a CHECK constraint.
BEGIN;

CREATE TABLE IF NOT EXISTS public.bmn_spotlights (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind            text NOT NULL CHECK (kind IN ('holiday','seasonal','entertainment','global_event','announcement','campaign')),
  title           text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 80),
  subtitle        text CHECK (subtitle IS NULL OR char_length(subtitle) <= 160),
  accent          text NOT NULL DEFAULT 'gold' CHECK (accent IN ('gold','red','blue','violet','green','pink')),
  emoji           text CHECK (emoji IS NULL OR char_length(emoji) <= 8),
  link_url        text CHECK (link_url IS NULL OR (char_length(link_url) <= 500 AND (link_url ~ '^https://[^[:space:]]+$' OR link_url ~ '^/[^/[:space:]][^[:space:]]*$'))),
  cta_label       text CHECK (cta_label IS NULL OR char_length(cta_label) <= 24),
  starts_at       timestamptz,
  ends_at         timestamptz,
  countdown_to    timestamptz,
  countdown_label text CHECK (countdown_label IS NULL OR char_length(countdown_label) <= 40),
  show_in_search  boolean NOT NULL DEFAULT true,
  show_on_profiles boolean NOT NULL DEFAULT false,
  priority        smallint NOT NULL DEFAULT 0 CHECK (priority BETWEEN -100 AND 100),
  status          text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','published','paused')),
  created_by      uuid,
  updated_by      uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT bmn_spotlights_window_ok CHECK (starts_at IS NULL OR ends_at IS NULL OR ends_at > starts_at)
);
CREATE INDEX IF NOT EXISTS bmn_spotlights_live_ix ON public.bmn_spotlights (status, starts_at, ends_at);

CREATE TABLE IF NOT EXISTS public.bmn_spotlight_audit (
  id           bigserial PRIMARY KEY,
  spotlight_id uuid,                       -- no foreign key: the record must outlive a deleted item
  actor        uuid,
  action       text NOT NULL,
  detail       jsonb NOT NULL DEFAULT '{}'::jsonb,
  at           timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.bmn_spotlights ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bmn_spotlight_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.bmn_spotlights, public.bmn_spotlight_audit FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.bmn_spotlight_audit_id_seq FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------- public read
CREATE OR REPLACE FUNCTION public.bmn_spotlight_active(p_surface text DEFAULT 'search')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_surface IS NULL OR p_surface NOT IN ('search','profile') THEN RAISE EXCEPTION 'surface must be search or profile' USING ERRCODE = '22023'; END IF;
  RETURN jsonb_build_object(
    'now', now(),
    'items', COALESCE((
      SELECT jsonb_agg(to_jsonb(x) ORDER BY x.priority DESC, x.starts_at DESC NULLS LAST, x.created_at DESC)
      FROM (
        SELECT id, kind, title, subtitle, accent, emoji, link_url, cta_label, countdown_to, countdown_label, ends_at, starts_at, priority, created_at
        FROM public.bmn_spotlights s
        WHERE s.status = 'published'
          AND (s.starts_at IS NULL OR s.starts_at <= now())
          AND (s.ends_at   IS NULL OR s.ends_at   >  now())
          AND ((p_surface = 'search' AND s.show_in_search) OR (p_surface = 'profile' AND s.show_on_profiles))
        ORDER BY s.priority DESC, s.starts_at DESC NULLS LAST, s.created_at DESC
        LIMIT 5
      ) x), '[]'::jsonb));
END $$;

-- ---------------------------------------------------------------------------------------------------------------- owner helpers
CREATE OR REPLACE FUNCTION public.bmn_spotlight_assert_owner() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v uuid := auth.uid();
BEGIN
  IF v IS NULL OR NOT public.is_bmn_owner() THEN RAISE EXCEPTION 'Only the BMN owner can manage Spotlight.' USING ERRCODE = '42501'; END IF;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION public.bmn_spotlight_state(p public.bmn_spotlights) RETURNS text
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT CASE
    WHEN p.status = 'draft'  THEN 'draft'
    WHEN p.status = 'paused' THEN 'paused'
    WHEN p.ends_at IS NOT NULL AND p.ends_at <= now() THEN 'ended'
    WHEN p.starts_at IS NOT NULL AND p.starts_at > now() THEN 'scheduled'
    ELSE 'live' END
$$;

CREATE OR REPLACE FUNCTION public.bmn_spotlight_owner_list() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.bmn_spotlight_assert_owner();
  RETURN COALESCE((SELECT jsonb_agg(to_jsonb(s) || jsonb_build_object('state', public.bmn_spotlight_state(s)) ORDER BY s.created_at DESC) FROM public.bmn_spotlights s), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION public.bmn_spotlight_owner_save(p_id uuid, p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_actor uuid := public.bmn_spotlight_assert_owner();
  v_row public.bmn_spotlights;
  d jsonb := COALESCE(p_data, '{}'::jsonb);
  has boolean;
  v_new boolean := p_id IS NULL;
BEGIN
  IF jsonb_typeof(d) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'data must be an object' USING ERRCODE = '22023'; END IF;
  IF v_new THEN
    INSERT INTO public.bmn_spotlights (kind, title, created_by, updated_by)
    VALUES (COALESCE(d->>'kind', 'announcement'), COALESCE(d->>'title', ''), v_actor, v_actor) RETURNING * INTO v_row;
  ELSE
    SELECT * INTO v_row FROM public.bmn_spotlights WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Spotlight item not found' USING ERRCODE = 'P0002'; END IF;
  END IF;
  -- a key that is present is applied (null clears optional fields); a key that is absent keeps the stored value
  UPDATE public.bmn_spotlights SET
    kind             = CASE WHEN d ? 'kind'  THEN d->>'kind'  ELSE kind END,
    title            = CASE WHEN d ? 'title' THEN COALESCE(d->>'title','') ELSE title END,
    subtitle         = CASE WHEN d ? 'subtitle' THEN NULLIF(d->>'subtitle','') ELSE subtitle END,
    accent           = CASE WHEN d ? 'accent' THEN COALESCE(d->>'accent','gold') ELSE accent END,
    emoji            = CASE WHEN d ? 'emoji' THEN NULLIF(d->>'emoji','') ELSE emoji END,
    link_url         = CASE WHEN d ? 'link_url' THEN NULLIF(btrim(d->>'link_url'),'') ELSE link_url END,
    cta_label        = CASE WHEN d ? 'cta_label' THEN NULLIF(d->>'cta_label','') ELSE cta_label END,
    starts_at        = CASE WHEN d ? 'starts_at' THEN NULLIF(d->>'starts_at','')::timestamptz ELSE starts_at END,
    ends_at          = CASE WHEN d ? 'ends_at' THEN NULLIF(d->>'ends_at','')::timestamptz ELSE ends_at END,
    countdown_to     = CASE WHEN d ? 'countdown_to' THEN NULLIF(d->>'countdown_to','')::timestamptz ELSE countdown_to END,
    countdown_label  = CASE WHEN d ? 'countdown_label' THEN NULLIF(d->>'countdown_label','') ELSE countdown_label END,
    show_in_search   = CASE WHEN d ? 'show_in_search' THEN COALESCE((d->>'show_in_search')::boolean, true) ELSE show_in_search END,
    show_on_profiles = CASE WHEN d ? 'show_on_profiles' THEN COALESCE((d->>'show_on_profiles')::boolean, false) ELSE show_on_profiles END,
    priority         = CASE WHEN d ? 'priority' THEN COALESCE((d->>'priority')::smallint, 0) ELSE priority END,
    status           = CASE WHEN d ? 'status' THEN COALESCE(d->>'status','draft') ELSE status END,
    updated_by = v_actor, updated_at = now()
  WHERE id = v_row.id RETURNING * INTO v_row;
  INSERT INTO public.bmn_spotlight_audit (spotlight_id, actor, action, detail)
  VALUES (v_row.id, v_actor, CASE WHEN v_new THEN 'created' ELSE 'edited' END, jsonb_build_object('title', v_row.title, 'kind', v_row.kind, 'status', v_row.status));
  RETURN to_jsonb(v_row) || jsonb_build_object('state', public.bmn_spotlight_state(v_row));
EXCEPTION
  WHEN invalid_text_representation OR invalid_datetime_format OR datetime_field_overflow OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'A field has an invalid value (check dates, number and yes/no fields).' USING ERRCODE = '22023';
  WHEN check_violation THEN
    RAISE EXCEPTION 'Rejected: %', SQLERRM USING ERRCODE = '22023';
END $$;

CREATE OR REPLACE FUNCTION public.bmn_spotlight_owner_set_status(p_id uuid, p_status text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid := public.bmn_spotlight_assert_owner(); v_row public.bmn_spotlights;
BEGIN
  IF p_status IS NULL OR p_status NOT IN ('draft','published','paused') THEN RAISE EXCEPTION 'status must be draft, published or paused' USING ERRCODE = '22023'; END IF;
  UPDATE public.bmn_spotlights SET status = p_status, updated_by = v_actor, updated_at = now() WHERE id = p_id RETURNING * INTO v_row;
  IF NOT FOUND THEN RAISE EXCEPTION 'Spotlight item not found' USING ERRCODE = 'P0002'; END IF;
  INSERT INTO public.bmn_spotlight_audit (spotlight_id, actor, action, detail) VALUES (p_id, v_actor, 'status_' || p_status, jsonb_build_object('title', v_row.title));
  RETURN to_jsonb(v_row) || jsonb_build_object('state', public.bmn_spotlight_state(v_row));
END $$;

CREATE OR REPLACE FUNCTION public.bmn_spotlight_owner_delete(p_id uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid := public.bmn_spotlight_assert_owner(); v_row public.bmn_spotlights;
BEGIN
  DELETE FROM public.bmn_spotlights WHERE id = p_id RETURNING * INTO v_row;
  IF NOT FOUND THEN RAISE EXCEPTION 'Spotlight item not found' USING ERRCODE = 'P0002'; END IF;
  INSERT INTO public.bmn_spotlight_audit (spotlight_id, actor, action, detail) VALUES (p_id, v_actor, 'deleted', to_jsonb(v_row));
  RETURN true;
END $$;

CREATE OR REPLACE FUNCTION public.bmn_spotlight_owner_audit(p_limit integer DEFAULT 50) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.bmn_spotlight_assert_owner();
  RETURN COALESCE((SELECT jsonb_agg(to_jsonb(a)) FROM (SELECT * FROM public.bmn_spotlight_audit ORDER BY id DESC LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)) a), '[]'::jsonb);
END $$;

-- ---------------------------------------------------------------------------------------------------------------- privileges
REVOKE ALL ON FUNCTION public.bmn_spotlight_active(text), public.bmn_spotlight_assert_owner(), public.bmn_spotlight_state(public.bmn_spotlights),
  public.bmn_spotlight_owner_list(), public.bmn_spotlight_owner_save(uuid, jsonb), public.bmn_spotlight_owner_set_status(uuid, text),
  public.bmn_spotlight_owner_delete(uuid), public.bmn_spotlight_owner_audit(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bmn_spotlight_active(text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.bmn_spotlight_state(public.bmn_spotlights), public.bmn_spotlight_owner_list(), public.bmn_spotlight_owner_save(uuid, jsonb),
  public.bmn_spotlight_owner_set_status(uuid, text), public.bmn_spotlight_owner_delete(uuid), public.bmn_spotlight_owner_audit(integer), public.bmn_spotlight_assert_owner() TO authenticated, service_role;

COMMIT;
