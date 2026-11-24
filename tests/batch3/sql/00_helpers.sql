-- Test helpers (LOCAL TEST DATABASE ONLY). Never run against production.
CREATE SCHEMA IF NOT EXISTS t;
CREATE TABLE IF NOT EXISTS t.results (n serial, name text, ok boolean, detail text);
GRANT USAGE ON SCHEMA t TO authenticated, anon, service_role;
CREATE OR REPLACE FUNCTION t.as_user(u uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', u::text, false);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', false);
  EXECUTE 'SET ROLE authenticated';
END $$;
CREATE OR REPLACE FUNCTION t.as_service() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '', false);
  PERFORM set_config('request.jwt.claim.role', 'service_role', false);
  EXECUTE 'SET ROLE service_role';
END $$;
CREATE OR REPLACE FUNCTION t.su() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claim.sub', '', false);
  PERFORM set_config('request.jwt.claim.role', '', false);
END $$;
CREATE OR REPLACE FUNCTION t.ok(p_name text, p_cond boolean, p_detail text DEFAULT NULL) RETURNS void
LANGUAGE sql SECURITY DEFINER AS $$ INSERT INTO t.results (name, ok, detail) VALUES (p_name, COALESCE(p_cond,false), p_detail); $$;
-- expects `p_sql` to raise an error containing `p_frag` (empty frag = any error)
CREATE OR REPLACE FUNCTION t.throws(p_name text, p_sql text, p_frag text DEFAULT '') RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_msg text;
BEGIN
  BEGIN
    EXECUTE p_sql;
    PERFORM t.ok(p_name, false, 'expected an error, got none');
  EXCEPTION WHEN OTHERS THEN
    v_msg := SQLERRM;
    PERFORM t.ok(p_name, p_frag = '' OR position(lower(p_frag) in lower(v_msg)) > 0, v_msg);
  END;
END $$;
CREATE OR REPLACE FUNCTION t.works(p_name text, p_sql text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
    PERFORM t.ok(p_name, true);
  EXCEPTION WHEN OTHERS THEN
    PERFORM t.ok(p_name, false, SQLERRM);
  END;
END $$;
CREATE OR REPLACE FUNCTION t.count(p_sql text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE n bigint; BEGIN EXECUTE 'select count(*) from (' || p_sql || ') q' INTO n; RETURN n; END $$;
-- fixed test users
CREATE OR REPLACE FUNCTION t.u(n int) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('00000000-0000-4000-8000-00000000000' || n::text)::uuid $$;
CREATE TABLE IF NOT EXISTS t.vars (k text PRIMARY KEY, v text);
CREATE OR REPLACE FUNCTION t.set(p_k text, p_v text) RETURNS void LANGUAGE sql SECURITY DEFINER AS
$$ INSERT INTO t.vars VALUES (p_k, p_v) ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v; $$;
CREATE OR REPLACE FUNCTION t.get(p_k text) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$ SELECT v FROM t.vars WHERE k = p_k; $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated, anon, service_role;
-- scalar lookup as the table owner (bypasses RLS), for checking internal state
CREATE OR REPLACE FUNCTION t.q(p_sql text) RETURNS text LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v text; BEGIN EXECUTE p_sql INTO v; RETURN v; END $$;
GRANT EXECUTE ON FUNCTION t.q(text) TO authenticated, anon, service_role;
