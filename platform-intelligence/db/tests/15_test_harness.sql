-- Test-only helpers. Lives in schema "pgtest", which is never touched by the migration or its rollback.

CREATE SCHEMA IF NOT EXISTS pgtest;

CREATE TABLE IF NOT EXISTS pgtest.results (
  n      serial PRIMARY KEY,
  name   text NOT NULL,
  ok     boolean NOT NULL,
  detail text
);

CREATE OR REPLACE FUNCTION pgtest.u(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
$$;

CREATE OR REPLACE FUNCTION pgtest.rec(p_name text, p_ok boolean, p_detail text DEFAULT NULL) RETURNS void
  LANGUAGE sql AS $$ INSERT INTO pgtest.results (name, ok, detail) VALUES (p_name, p_ok, p_detail) $$;

-- t(): run a statement, optionally as a role / JWT subject.
--   p_expect NULL      -> the statement must succeed
--   p_expect '23514'   -> the statement must fail with exactly that SQLSTATE (and is rolled back)
CREATE OR REPLACE FUNCTION pgtest.t(p_name text, p_sql text, p_role text DEFAULT NULL,
                                    p_sub uuid DEFAULT NULL, p_expect text DEFAULT NULL) RETURNS void
  LANGUAGE plpgsql AS $$
DECLARE v_state text; v_msg text;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
    PERFORM set_config('request.jwt.claim.role', coalesce(p_role, ''), true);
    IF p_role IS NOT NULL THEN EXECUTE format('SET LOCAL ROLE %I', p_role); END IF;
    EXECUTE p_sql;
    RESET ROLE;
    IF p_expect IS NOT NULL THEN
      RAISE EXCEPTION 'statement succeeded but should have failed' USING ERRCODE = 'XXTST';
    END IF;
    INSERT INTO pgtest.results (name, ok, detail) VALUES (p_name, true, 'succeeded as expected');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    v_state := SQLSTATE;
    IF p_expect IS NOT NULL AND v_state = p_expect THEN
      INSERT INTO pgtest.results (name, ok, detail) VALUES (p_name, true, 'rejected as expected (' || v_state || ': ' || left(v_msg, 120) || ')');
    ELSIF v_state = 'XXTST' THEN
      INSERT INTO pgtest.results (name, ok, detail) VALUES (p_name, false, 'expected error ' || p_expect || ' but the statement SUCCEEDED');
    ELSE
      INSERT INTO pgtest.results (name, ok, detail) VALUES (p_name, false,
        CASE WHEN p_expect IS NULL THEN 'unexpected error ' || v_state || ': ' || left(v_msg, 200)
             ELSE 'expected ' || p_expect || ' but got ' || v_state || ': ' || left(v_msg, 200) END);
    END IF;
  END;
END $$;

-- q(): run a scalar boolean expression (optionally as a role / JWT subject); it must be TRUE.
CREATE OR REPLACE FUNCTION pgtest.q(p_name text, p_expr text, p_role text DEFAULT NULL, p_sub uuid DEFAULT NULL) RETURNS void
  LANGUAGE plpgsql AS $$
DECLARE v_ok boolean; v_msg text; v_state text;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
    PERFORM set_config('request.jwt.claim.role', coalesce(p_role, ''), true);
    IF p_role IS NOT NULL THEN EXECUTE format('SET LOCAL ROLE %I', p_role); END IF;
    EXECUTE 'SELECT (' || p_expr || ')' INTO v_ok;
    RESET ROLE;
    INSERT INTO pgtest.results (name, ok, detail) VALUES (p_name, coalesce(v_ok, false),
      CASE WHEN coalesce(v_ok, false) THEN 'true as expected' ELSE 'expression was ' || coalesce(v_ok::text, 'NULL') END);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    v_state := SQLSTATE;
    INSERT INTO pgtest.results (name, ok, detail) VALUES (p_name, false, 'error ' || v_state || ': ' || left(v_msg, 200));
  END;
END $$;

-- Fingerprints of everything that is NOT a pi_ object, to prove the migration/rollback leave BMN untouched.
CREATE OR REPLACE FUNCTION pgtest.schema_fp() RETURNS text LANGUAGE sql AS $$
  SELECT concat_ws(' | ',
    (SELECT md5(coalesce(string_agg(concat_ws(':', table_name, column_name, data_type, is_nullable, column_default), ',' ORDER BY table_name, column_name), ''))
       FROM information_schema.columns WHERE table_schema = 'public' AND table_name NOT LIKE 'pi\_%'),
    (SELECT md5(coalesce(string_agg(concat_ws(':', c.relname, o.conname, pg_get_constraintdef(o.oid)), ',' ORDER BY c.relname, o.conname), ''))
       FROM pg_constraint o JOIN pg_class c ON c.oid = o.conrelid
      WHERE c.relnamespace = 'public'::regnamespace AND c.relname NOT LIKE 'pi\_%'),
    (SELECT md5(coalesce(string_agg(indexdef, ',' ORDER BY indexname), ''))
       FROM pg_indexes WHERE schemaname = 'public' AND tablename NOT LIKE 'pi\_%'),
    (SELECT md5(coalesce(string_agg(concat_ws(':', tablename, policyname, cmd, roles::text, qual, with_check), ',' ORDER BY tablename, policyname), ''))
       FROM pg_policies WHERE schemaname = 'public' AND tablename NOT LIKE 'pi\_%'),
    (SELECT md5(coalesce(string_agg(pg_get_triggerdef(t.oid), ',' ORDER BY t.tgname), ''))
       FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
      WHERE NOT t.tgisinternal AND c.relnamespace = 'public'::regnamespace AND c.relname NOT LIKE 'pi\_%'),
    (SELECT md5(coalesce(string_agg(pg_get_functiondef(p.oid) || coalesce(p.proacl::text, ''), ',' ORDER BY p.proname, p.oid::text), ''))
       FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname NOT LIKE 'pi\_%' AND p.prokind = 'f'),
    (SELECT md5(coalesce(string_agg(concat_ws(':', c.relname, c.relkind::text, c.relrowsecurity::text, coalesce(c.relacl::text, '')), ',' ORDER BY c.relname), ''))
       FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relname NOT LIKE 'pi\_%' AND c.relkind IN ('r', 'v', 'S')));
$$;

CREATE OR REPLACE FUNCTION pgtest.data_fp() RETURNS text LANGUAGE plpgsql AS $$
DECLARE r record; v text; out text := '';
BEGIN
  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename NOT LIKE 'pi\_%' ORDER BY tablename LOOP
    EXECUTE format('SELECT md5(coalesce(string_agg(t::text, E''\n'' ORDER BY t::text), '''')) || '':'' || count(*) FROM public.%I t', r.tablename) INTO v;
    out := out || r.tablename || '=' || v || ';';
  END LOOP;
  RETURN md5(out) || ' (' || (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename NOT LIKE 'pi\_%') || ' tables)';
END $$;

CREATE TABLE IF NOT EXISTS pgtest.fps (label text PRIMARY KEY, schema_fp text NOT NULL, data_fp text NOT NULL);

CREATE OR REPLACE FUNCTION pgtest.snap(p_label text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO pgtest.fps (label, schema_fp, data_fp) VALUES (p_label, pgtest.schema_fp(), pgtest.data_fp())
  ON CONFLICT (label) DO UPDATE SET schema_fp = EXCLUDED.schema_fp, data_fp = EXCLUDED.data_fp
$$;

CREATE OR REPLACE FUNCTION pgtest.pi_object_count() RETURNS integer LANGUAGE sql AS $$
  SELECT (SELECT count(*) FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname LIKE 'pi\_%')
       + (SELECT count(*) FROM pg_proc  WHERE pronamespace = 'public'::regnamespace AND proname  LIKE 'pi\_%')
       + (SELECT count(*) FROM pg_type  WHERE typnamespace = 'public'::regnamespace AND typname   LIKE 'pi\_%' AND typtype = 'd')
$$;

-- Fingerprint of the ENTIRE pi_ installation (structure + row counts). Used to prove a refused migration changed nothing.
CREATE OR REPLACE FUNCTION pgtest.pi_fp() RETURNS text LANGUAGE sql AS $$
  SELECT md5(concat_ws('#',
    (SELECT coalesce(string_agg(c.relname || ':' || c.relkind::text || ':' || c.relrowsecurity::text || ':' || coalesce(c.relacl::text, ''), ',' ORDER BY c.relname), '')
       FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relname LIKE 'pi\_%'),
    (SELECT coalesce(string_agg(c.relname || '.' || a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull::text, ',' ORDER BY c.relname, a.attname), '')
       FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
      WHERE c.relnamespace = 'public'::regnamespace AND c.relname LIKE 'pi\_%' AND c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped),
    (SELECT coalesce(string_agg(c.relname || '.' || o.conname || ':' || pg_get_constraintdef(o.oid), ',' ORDER BY c.relname, o.conname), '')
       FROM pg_constraint o JOIN pg_class c ON c.oid = o.conrelid WHERE c.relnamespace = 'public'::regnamespace AND c.relname LIKE 'pi\_%'),
    (SELECT coalesce(string_agg(pg_get_triggerdef(t.oid), ',' ORDER BY t.tgname), '')
       FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid WHERE NOT t.tgisinternal AND c.relnamespace = 'public'::regnamespace AND c.relname LIKE 'pi\_%'),
    (SELECT coalesce(string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || '):' || md5(p.prosrc) || ':' || coalesce(p.proacl::text, ''), ',' ORDER BY p.proname, p.oid::text), '')
       FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'pi\_%'),
    (SELECT coalesce(string_agg(tablename || ':' || policyname || ':' || cmd || ':' || roles::text || ':' || coalesce(qual, ''), ',' ORDER BY tablename, policyname), '')
       FROM pg_policies WHERE schemaname = 'public' AND tablename LIKE 'pi\_%'),
    (SELECT coalesce(string_agg(c.relname || '=' || (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM public.%I', c.relname), false, true, '')))[1]::text, ',' ORDER BY c.relname), '')
       FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relname LIKE 'pi\_%' AND c.relkind = 'r')))
$$;
