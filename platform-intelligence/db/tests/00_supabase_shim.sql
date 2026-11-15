-- Test-only: emulates the parts of Supabase that the BMN schema depends on, so the real baseline
-- and the Platform Intelligence migration can be exercised on a plain, disposable PostgreSQL.
-- NEVER run this against a real Supabase project (it would try to create roles and an auth schema).
--
-- Fidelity notes (what is and is not emulated):
--   * roles anon / authenticated / service_role exist; service_role has BYPASSRLS (as in Supabase)
--   * auth.users (id, email) and auth.uid() (reads request.jwt.claim.sub, as PostgREST does)
--   * default privileges: Supabase grants ALL on new public objects to anon/authenticated/service_role,
--     which is the situation the migration must tighten, so it is emulated here
--   NOT emulated: GoTrue, PostgREST, realtime, storage, pg_graphql, real JWT verification.

-- Roles are cluster-wide, so create them only if a previous test run has not already done so.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')          THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role')  THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END $$;

CREATE SCHEMA auth;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;

CREATE TABLE auth.users (
  id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION auth.uid() RETURNS uuid
  LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role;

-- As in Supabase: the role comes from the JWT claim, not from current_user.
CREATE FUNCTION auth.role() RETURNS text
  LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
                  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'))::text
$$;
GRANT EXECUTE ON FUNCTION auth.role() TO anon, authenticated, service_role;

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;
