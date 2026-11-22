-- BMN Messaging: OPTIONAL database additions.
-- The Messaging feature works WITHOUT this file. Nothing here has been run against any server.
-- Review it, run it yourself in the Supabase SQL editor only if you want the benefits below.
-- Both parts are additive and idempotent. Rollback statements are at the bottom.

-- 1) Instant delivery. If `messages` is not in the realtime publication, the app falls back to
--    checking for new messages every few seconds. Adding the table makes delivery instant.
--    (RLS still applies: members only receive their own conversations.)
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;
end $$;

-- 2) One-call conversation list. Without it the app reads recent messages and groups them on the phone.
--    SECURITY INVOKER, so the existing RLS policies on `messages` decide what each member can see.
create or replace function public.bmn_inbox_conversations()
returns table (
  peer_id uuid,
  last_message_id uuid,
  last_content text,
  last_sender_id uuid,
  last_created_at timestamptz,
  unread_count bigint
)
language sql
stable
security invoker
set search_path = public
as $$
  with mine as (
    select m.*,
           case when m.sender_id = auth.uid() then m.recipient_id else m.sender_id end as peer
    from public.messages m
    where (m.sender_id = auth.uid() and not coalesce(m.deleted_by_sender, false))
       or (m.recipient_id = auth.uid() and not coalesce(m.deleted_by_recipient, false))
  ),
  last_msg as (
    select distinct on (peer) peer, id, content, sender_id, created_at
    from mine
    order by peer, created_at desc, id desc
  )
  select l.peer, l.id, l.content, l.sender_id, l.created_at,
         (select count(*) from mine u
          where u.peer = l.peer and u.recipient_id = auth.uid()
            and u.sender_id <> auth.uid() and u.read_at is null)
  from last_msg l
  order by l.created_at desc;
$$;
revoke all on function public.bmn_inbox_conversations() from public, anon;
grant execute on function public.bmn_inbox_conversations() to authenticated;

-- ROLLBACK (only if you applied the above and want to undo it):
--   drop function if exists public.bmn_inbox_conversations();
--   alter publication supabase_realtime drop table public.messages;
