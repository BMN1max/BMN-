-- =====================================================================
-- BMN Board — production audit  (READ-ONLY, metadata only)
-- Run in: Supabase Dashboard -> SQL Editor -> New query -> paste -> Run.
--
-- This file is ONE select statement. It contains no INSERT, UPDATE, DELETE, ALTER, CREATE,
-- DROP, GRANT, TRUNCATE or function calls that write. It reads catalog metadata only:
-- table/column names, policies, constraints, triggers, indexes, grants, function definitions
-- (the code of a few existing helper functions) and extension availability.
-- It does NOT read posts, comments, messages, notifications, emails or any other user content,
-- and it does not count or list users. "approx_rows" is the planner's estimate (can be -1 or 0).
--
-- It answers the three questions I need before finalising the Board schema:
--   1. posts            -> RLS policies, triggers, constraints, grants (so Board never touches video feeds)
--   2. user_blocks      -> exact columns, kinds, policies (so Board honours the same blocks as messaging)
--   3. notifications    -> columns, type rules, policies, triggers (so I know whether Board may reuse it)
-- plus the other tables Board reuses (profiles, follows, verification, reports, settings) and a
-- collision check that no board_* object already exists.
--
-- RESULT: one cell named "bmn_board_audit" holding JSON. Tap/click the cell, copy it, paste it to me.
-- =====================================================================
select jsonb_pretty(jsonb_build_object(
  'generated_at', now(),
  'server_version', current_setting('server_version'),

  -- 0. collision check: anything already named like Board objects?
  'existing_board_objects', jsonb_build_object(
    'tables', (select coalesce(jsonb_agg(c.relname order by c.relname), '[]'::jsonb)
               from pg_class c join pg_namespace n on n.oid = c.relnamespace
               where n.nspname = 'public' and c.relkind in ('r','p','v','m') and (c.relname like 'board\_%' or c.relname like 'bmn\_board%')),
    'functions', (select coalesce(jsonb_agg(p.proname order by p.proname), '[]'::jsonb)
                  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and (p.proname like 'board\_%' or p.proname like 'bmn\_board%')),
    'types', (select coalesce(jsonb_agg(t.typname order by t.typname), '[]'::jsonb)
              from pg_type t join pg_namespace n on n.oid = t.typnamespace
              where n.nspname = 'public' and t.typtype in ('e','d','c') and (t.typname like 'board\_%' or t.typname like 'bmn\_board%')
                and t.typrelid = 0)),

  -- 1. tables Board reuses: RLS state and planner row estimate
  'reused_tables', (
    select jsonb_agg(jsonb_build_object('table', c.relname, 'rls_enabled', c.relrowsecurity,
                                        'rls_forced', c.relforcerowsecurity, 'approx_rows', c.reltuples::bigint) order by c.relname)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r','p')
      and c.relname in ('posts','profiles','follows','user_blocks','user_settings','notifications','content_reports',
                        'likes','comments','post_reposts','post_saves','post_views','bmn_verified_users','bmn_admins','bmn_user_moderation')),

  -- 2. exact columns of those tables
  'columns', (
    select jsonb_object_agg(table_name, cols) from (
      select table_name,
             jsonb_agg(column_name || ' ' || data_type
                       || case when is_nullable = 'NO' then ' NOT NULL' else '' end
                       || coalesce(' DEFAULT ' || column_default, '') order by ordinal_position) as cols
      from information_schema.columns
      where table_schema = 'public'
        and table_name in ('posts','profiles','follows','user_blocks','user_settings','notifications','content_reports',
                           'bmn_verified_users','bmn_admins','bmn_user_moderation')
      group by table_name) x),

  -- 3. RLS policies on those tables (posts, user_blocks and notifications are the three that matter most)
  'policies', (
    select jsonb_agg(jsonb_build_object('table', tablename, 'name', policyname, 'permissive', permissive,
                                        'roles', roles, 'cmd', cmd, 'using', qual, 'with_check', with_check)
                     order by tablename, policyname)
    from pg_policies
    where schemaname = 'public'
      and tablename in ('posts','profiles','follows','user_blocks','user_settings','notifications','content_reports',
                        'bmn_verified_users','bmn_admins','bmn_user_moderation')),

  -- 4. check constraints (notifications.type rules, user_blocks.kind, content_reports.reason, user_settings values)
  'check_constraints', (
    select jsonb_agg(jsonb_build_object('table', conrelid::regclass::text, 'name', conname,
                                        'definition', pg_get_constraintdef(oid)) order by conrelid::regclass::text, conname)
    from pg_constraint
    where contype = 'c' and connamespace = 'public'::regnamespace
      and conrelid in (select c2.oid from pg_class c2 where c2.relnamespace = 'public'::regnamespace and c2.relname in ('posts','profiles','follows','user_blocks','user_settings','notifications','content_reports','bmn_verified_users','bmn_user_moderation'))),

  -- 5. keys and foreign keys (is content_reports.post_id a foreign key? are notifications tied to posts?)
  'keys_and_foreign_keys', (
    select jsonb_agg(jsonb_build_object('table', conrelid::regclass::text, 'type', contype, 'name', conname,
                                        'definition', pg_get_constraintdef(oid)) order by conrelid::regclass::text, conname)
    from pg_constraint
    where contype in ('p','u','f') and connamespace = 'public'::regnamespace
      and conrelid in (select c2.oid from pg_class c2 where c2.relnamespace = 'public'::regnamespace and c2.relname in ('posts','profiles','follows','user_blocks','user_settings','notifications','content_reports','bmn_verified_users','bmn_admins','bmn_user_moderation'))),

  -- 6. triggers (account-status enforcement, notification fan-out, profile creation on signup)
  'triggers', (
    select jsonb_agg(jsonb_build_object('table', t.tgrelid::regclass::text, 'name', t.tgname,
                                        'enabled', t.tgenabled, 'definition', pg_get_triggerdef(t.oid))
                     order by t.tgrelid::regclass::text, t.tgname)
    from pg_trigger t
    where not t.tgisinternal
      and (t.tgrelid in (select c2.oid from pg_class c2 where c2.relnamespace = 'public'::regnamespace and c2.relname in ('posts','profiles','follows','user_blocks','user_settings','notifications','content_reports','likes','comments','post_reposts','bmn_verified_users'))
           or t.tgrelid = (select c3.oid from pg_class c3 where c3.relnamespace = 'auth'::regnamespace and c3.relname = 'users'))),

  -- 7. indexes on the tables Board looks up by (profiles.username for @mentions, follows, blocks, notifications)
  'indexes', (
    select jsonb_agg(jsonb_build_object('table', tablename, 'index', indexname, 'definition', indexdef)
                     order by tablename, indexname)
    from pg_indexes
    where schemaname = 'public'
      and tablename in ('posts','profiles','follows','user_blocks','user_settings','notifications','content_reports')),

  -- 8. who may touch these tables at the privilege level (RLS applies on top of this)
  'table_grants', (
    select jsonb_agg(jsonb_build_object('table', table_name, 'grantee', grantee, 'privileges', privs) order by table_name, grantee)
    from (select table_name, grantee, string_agg(privilege_type, ',' order by privilege_type) as privs
          from information_schema.role_table_grants
          where table_schema = 'public' and grantee in ('anon','authenticated','service_role')
            and table_name in ('posts','profiles','follows','user_blocks','user_settings','notifications','content_reports')
          group by table_name, grantee) g),

  -- 9. existing helper functions Board will call or imitate (name, security mode, search_path, grants, source)
  'helper_functions', (
    select jsonb_agg(jsonb_build_object(
             'name', p.proname, 'args', pg_get_function_identity_arguments(p.oid),
             'security_definer', p.prosecdef, 'config', p.proconfig, 'returns', pg_get_function_result(p.oid),
             'definition', pg_get_functiondef(p.oid)) order by p.proname)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
      and p.proname in ('is_bmn_owner','bmn_my_account_status','bmn_is_blocked_between','bmn_can_message',
                        'bmn_enforce_interaction_account_status','bmn_is_verified','is_bmn_admin')),

  -- 10. every public function whose name suggests verification, blocking or account status (names only)
  'related_function_names', (
    select jsonb_agg(jsonb_build_object('name', p.proname, 'args', pg_get_function_identity_arguments(p.oid),
                                        'security_definer', p.prosecdef) order by p.proname)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
      and (p.proname ilike '%verif%' or p.proname ilike '%block%' or p.proname ilike '%account_status%' or p.proname ilike '%owner%')),

  -- 11. realtime: which tables are published (notifications / board tables could be added later)
  'realtime_publication_tables', (
    select coalesce(jsonb_agg(schemaname || '.' || tablename order by schemaname, tablename), '[]'::jsonb)
    from pg_publication_tables where pubname = 'supabase_realtime'),

  -- 12. extensions Board search could use (pg_trgm) and what is installed
  'extensions_installed', (select jsonb_agg(extname || ' ' || extversion order by extname) from pg_extension),
  'extensions_available_of_interest', (
    select jsonb_agg(jsonb_build_object('name', name, 'default_version', default_version, 'installed_version', installed_version) order by name)
    from pg_available_extensions where name in ('pg_trgm', 'pgcrypto', 'unaccent'))
)) as bmn_board_audit;
