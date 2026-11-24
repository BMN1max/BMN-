-- LOCAL TEST SHIM ONLY (never run on Supabase).
-- Production is PostgreSQL 17; the local test server is PostgreSQL 16, which evaluates every
-- branch of `CASE TG_TABLE_NAME WHEN ... THEN NEW.user_id` and fails on tables without that
-- column. This replaces the baseline trigger function with a logically identical one that reads
-- the column through to_jsonb(NEW), so the real triggers can fire in the PG16 test database.
CREATE OR REPLACE FUNCTION public.bmn_enforce_interaction_account_status() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE v_actor uuid; v_owner uuid; v_status text; v_expires_at timestamptz; j jsonb := to_jsonb(NEW);
BEGIN
  IF auth.role() = 'service_role' THEN RETURN NEW; END IF;
  v_actor := auth.uid();
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  v_owner := CASE TG_TABLE_NAME
    WHEN 'comments' THEN (j->>'user_id')::uuid
    WHEN 'likes' THEN (j->>'user_id')::uuid
    WHEN 'follows' THEN (j->>'follower_id')::uuid
    WHEN 'messages' THEN (j->>'sender_id')::uuid END;
  IF v_owner IS DISTINCT FROM v_actor THEN RAISE EXCEPTION 'You can only act as your own account'; END IF;
  SELECT status, expires_at INTO v_status, v_expires_at FROM public.bmn_user_moderation WHERE user_id = v_actor;
  IF v_status = 'banned' OR (v_status = 'suspended' AND (v_expires_at IS NULL OR v_expires_at > now())) THEN
    RAISE EXCEPTION 'Your BMN account is restricted';
  END IF;
  RETURN NEW;
END; $$;
