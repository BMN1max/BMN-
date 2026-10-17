-- BMN Community profile photos and post views
-- Run once in Supabase Dashboard -> SQL Editor -> New query -> Run.

alter table public.profiles
  add column if not exists avatar_url text;

alter table public.posts
  add column if not exists views bigint not null default 0;

-- Counts one post view. This function only changes the count; it does not expose private data.
create or replace function public.increment_post_view(p_post_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update public.posts
  set views = coalesce(views, 0) + 1
  where id = p_post_id;
$$;

revoke all on function public.increment_post_view(uuid) from public;
grant execute on function public.increment_post_view(uuid) to anon, authenticated;

-- Let public visitors load public community media from the private bucket via signed URLs.
-- This is read-only access to objects in this bucket; it does not make the bucket public.
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and policyname = 'BMN community media read for feed'
  ) then
    create policy "BMN community media read for feed"
      on storage.objects for select
      to anon, authenticated
      using (bucket_id = 'community-media');
  end if;
end $$;
