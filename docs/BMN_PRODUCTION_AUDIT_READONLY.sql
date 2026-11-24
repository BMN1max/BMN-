-- =====================================================================
-- BMN production audit  (READ-ONLY, metadata only)
-- Run in: Supabase Dashboard -> SQL Editor -> New query -> paste -> Run.
-- It is ONE select statement. It cannot change anything: no CREATE, ALTER, INSERT,
-- UPDATE, DELETE, DROP or GRANT. It reads catalog metadata only (table and column names,
-- policies, functions, triggers, indexes, extensions). It does NOT read message text,
-- emails, posts or any other user content. Row counts are the planner's approximate
-- estimates (can show -1 or 0 if the table was never analysed).
-- RESULT: a single cell named "bmn_audit" holding JSON. Tap/click the cell, copy it,
-- and paste it back to me.
-- =====================================================================
select jsonb_pretty(jsonb_build_object(
  'generated_at', now(),
  'server_version', current_setting('server_version'),

  'tables', (
    select jsonb_agg(jsonb_build_object(
      'table', c.relname, 'rls_enabled', c.relrowsecurity, 'rls_forced', c.relforcerowsecurity,
      'approx_rows', c.reltuples::bigint) order by c.relname)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r','p')),

  'columns', (
    select jsonb_object_agg(table_name, cols) from (
      select table_name,
             jsonb_agg(column_name || ' ' || data_type
                       || case when is_nullable = 'NO' then ' NOT NULL' else '' end
                       || coalesce(' DEFAULT ' || column_default, '') order by ordinal_position) as cols
      from information_schema.columns where table_schema = 'public' group by table_name) x),

  'policies_public', (
    select jsonb_agg(jsonb_build_object(
      'table', tablename, 'name', policyname, 'permissive', permissive, 'roles', roles,
      'cmd', cmd, 'using', qual, 'with_check', with_check) order by tablename, policyname)
    from pg_policies where schemaname = 'public'),

  'policies_storage', (
    select jsonb_agg(jsonb_build_object(
      'table', tablename, 'name', policyname, 'permissive', permissive, 'roles', roles,
      'cmd', cmd, 'using', qual, 'with_check', with_check) order by tablename, policyname)
    from pg_policies where schemaname = 'storage'),

  'functions_public', (
    select jsonb_agg(jsonb_build_object(
      'name', p.proname, 'args', pg_get_function_identity_arguments(p.oid),
      'security_definer', p.prosecdef, 'returns', pg_get_function_result(p.oid)) order by p.proname)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'),

  'triggers', (
    select jsonb_agg(jsonb_build_object(
      'table', t.tgrelid::regclass::text, 'name', t.tgname, 'definition', pg_get_triggerdef(t.oid))
      order by t.tgrelid::regclass::text, t.tgname)
    from pg_trigger t
    where not t.tgisinternal
      and (t.tgrelid::regclass::text like 'public.%' or t.tgrelid::regclass::text = 'auth.users')),

  'check_constraints', (
    select jsonb_agg(jsonb_build_object('table', conrelid::regclass::text, 'name', conname,
                                        'definition', pg_get_constraintdef(oid)) order by conrelid::regclass::text, conname)
    from pg_constraint where contype = 'c' and connamespace = 'public'::regnamespace),

  'foreign_keys', (
    select jsonb_agg(jsonb_build_object('table', conrelid::regclass::text, 'name', conname,
                                        'definition', pg_get_constraintdef(oid)) order by conrelid::regclass::text, conname)
    from pg_constraint where contype = 'f' and connamespace = 'public'::regnamespace),

  'indexes', (
    select jsonb_agg(jsonb_build_object('table', tablename, 'index', indexname, 'definition', indexdef)
                     order by tablename, indexname)
    from pg_indexes where schemaname = 'public'),

  'extensions_installed', (
    select jsonb_agg(extname || ' ' || extversion order by extname) from pg_extension),

  'extensions_available_of_interest', (
    select jsonb_agg(jsonb_build_object('name', name, 'default_version', default_version,
                                        'installed_version', installed_version) order by name)
    from pg_available_extensions where name in ('pg_cron', 'pg_net', 'pg_trgm', 'pgcrypto', 'unaccent')),

  'realtime_publication_tables', (
    select jsonb_agg(schemaname || '.' || tablename order by schemaname, tablename)
    from pg_publication_tables where pubname = 'supabase_realtime'),

  'storage_buckets', (
    select jsonb_agg(jsonb_build_object('id', id, 'public', public, 'file_size_limit', file_size_limit,
                                        'allowed_mime_types', allowed_mime_types) order by id)
    from storage.buckets),

  'storage_objects_rls_enabled', (
    select c.relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'storage' and c.relname = 'objects')
)) as bmn_audit;
