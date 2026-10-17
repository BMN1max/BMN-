-- BMN Community: READ-ONLY backend audit
-- Safe to run in Supabase SQL Editor: this file contains SELECT statements only.
-- It does not create, alter, delete, reset, or update anything.

-- 1) Check the current columns for the tables used by the website.
select table_name, column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public'
  and table_name in (
    'profiles', 'posts', 'comments', 'likes', 'follows',
    'messages', 'notifications', 'post_views'
  )
order by table_name, ordinal_position;

-- 2) Check row-level security (RLS) status for those tables.
select n.nspname as schema_name,
       c.relname as table_name,
       c.relrowsecurity as rls_enabled,
       c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind = 'r'
  and c.relname in (
    'profiles', 'posts', 'comments', 'likes', 'follows',
    'messages', 'notifications', 'post_views'
  )
order by c.relname;

-- 3) List current policies for those tables (read-only metadata).
select schemaname, tablename, policyname, permissive,
       roles, cmd, qual, with_check
from pg_policies
where schemaname in ('public', 'storage')
  and (
    tablename in (
      'profiles', 'posts', 'comments', 'likes', 'follows',
      'messages', 'notifications', 'post_views'
    )
    or (schemaname = 'storage' and tablename = 'objects')
  )
order by schemaname, tablename, policyname;

-- 4) Check functions related to post views and notification triggers.
select n.nspname as schema_name,
       p.proname as function_name,
       pg_get_function_identity_arguments(p.oid) as arguments,
       p.prosecdef as security_definer,
       pg_get_function_result(p.oid) as returns
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'increment_post_view', 'increment_post_view_once',
    'bmn_notify_follow', 'bmn_notify_like',
    'bmn_notify_comment', 'bmn_notify_message'
  )
order by p.proname;

-- 5) Check the community-media bucket's public flag (if the bucket exists).
select id, name, public, file_size_limit, allowed_mime_types
from storage.buckets
where id = 'community-media';

-- 6) Check whether the post_views table exists and its indexes.
select schemaname, tablename, indexname, indexdef
from pg_indexes
where schemaname = 'public'
  and tablename = 'post_views'
order by indexname;
