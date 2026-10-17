-- BMN Community: accurate one-view-per-signed-in-user counters
-- Run once in Supabase SQL Editor.

create table if not exists public.post_views (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

alter table public.post_views enable row level security;

grant select, insert on public.post_views to authenticated;

drop policy if exists "post views readable by authenticated" on public.post_views;
create policy "post views readable by authenticated"
on public.post_views
for select to authenticated
using (true);

drop policy if exists "users can record their own post views" on public.post_views;
create policy "users can record their own post views"
on public.post_views
for insert to authenticated
with check (auth.uid() = user_id);

create or replace function public.increment_post_view_once(p_post_id uuid)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  viewer uuid := auth.uid();
  new_count bigint;
begin
  -- Only signed-in users count as views. Anonymous page loads do not.
  if viewer is null then
    select coalesce(views, 0) into new_count from public.posts where id = p_post_id;
    return coalesce(new_count, 0);
  end if;

  insert into public.post_views(post_id, user_id)
  values (p_post_id, viewer)
  on conflict (post_id, user_id) do nothing;

  if found then
    update public.posts
      set views = coalesce(views, 0) + 1
      where id = p_post_id;
  end if;

  select coalesce(views, 0) into new_count from public.posts where id = p_post_id;
  return coalesce(new_count, 0);
end;
$$;

revoke all on function public.increment_post_view_once(uuid) from public;
grant execute on function public.increment_post_view_once(uuid) to authenticated;

-- Your current test environment has only you using BMN, so clear the old
-- inflated test counters and old view records. Remove these two statements
-- if you already have real community viewers whose historical views matter.
delete from public.post_views;
update public.posts set views = 0;

notify pgrst, 'reload schema';
