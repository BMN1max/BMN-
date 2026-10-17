-- BMN Community: enable follows + automatic notifications.
-- Run this once in Supabase Dashboard > SQL Editor.
-- This supplements the tables/policies you already created; it does not replace them.

create table if not exists public.follows (
  follower_id uuid not null references auth.users(id) on delete cascade,
  following_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, following_id),
  constraint follows_no_self_follow check (follower_id <> following_id)
);

create index if not exists follows_following_id_idx on public.follows(following_id);
alter table public.follows enable row level security;

drop policy if exists "Authenticated users can view follows" on public.follows;
create policy "Authenticated users can view follows"
  on public.follows for select to authenticated using (true);

drop policy if exists "Users can follow from their own account" on public.follows;
create policy "Users can follow from their own account"
  on public.follows for insert to authenticated with check (auth.uid() = follower_id);

drop policy if exists "Users can unfollow from their own account" on public.follows;
create policy "Users can unfollow from their own account"
  on public.follows for delete to authenticated using (auth.uid() = follower_id);

grant select, insert, delete on public.follows to authenticated;

-- Trigger functions run with the table owner's privileges so notification events
-- can be created safely even when the browser is not allowed to insert notifications.
create or replace function public.bmn_notify_follow()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.notifications (user_id, actor_id, type, message)
  values (new.following_id, new.follower_id, 'follow', 'Someone started following you.');
  return new;
end;
$$;

drop trigger if exists bmn_follow_notification on public.follows;
create trigger bmn_follow_notification after insert on public.follows
for each row execute function public.bmn_notify_follow();

create or replace function public.bmn_notify_like()
returns trigger language plpgsql security definer set search_path = public
as $$
declare post_owner uuid;
begin
  select user_id into post_owner from public.posts where id = new.post_id;
  if post_owner is not null and post_owner <> new.user_id then
    insert into public.notifications (user_id, actor_id, post_id, type, message)
    values (post_owner, new.user_id, new.post_id, 'like', 'Someone liked your post.');
  end if;
  return new;
end;
$$;

drop trigger if exists bmn_like_notification on public.likes;
create trigger bmn_like_notification after insert on public.likes
for each row execute function public.bmn_notify_like();

create or replace function public.bmn_notify_comment()
returns trigger language plpgsql security definer set search_path = public
as $$
declare post_owner uuid;
begin
  select user_id into post_owner from public.posts where id = new.post_id;
  if post_owner is not null and post_owner <> new.user_id then
    insert into public.notifications (user_id, actor_id, post_id, type, message)
    values (post_owner, new.user_id, new.post_id, 'comment', 'Someone commented on your post.');
  end if;
  return new;
end;
$$;

drop trigger if exists bmn_comment_notification on public.comments;
create trigger bmn_comment_notification after insert on public.comments
for each row execute function public.bmn_notify_comment();

create or replace function public.bmn_notify_message()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.notifications (user_id, actor_id, type, message)
  values (new.recipient_id, new.sender_id, 'message', 'You received a new private message.');
  return new;
end;
$$;

drop trigger if exists bmn_message_notification on public.messages;
create trigger bmn_message_notification after insert on public.messages
for each row execute function public.bmn_notify_message();
