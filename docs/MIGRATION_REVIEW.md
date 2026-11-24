# Batch 3 — Database migrations: review guide

**Status: PROPOSED. Nothing here has been run on production.** Review each file, run it yourself in the Supabase SQL editor only when you decide to. All four files are in `supabase/proposed/` (not in `supabase/migrations/`, so no tool applies them by accident).

Written against the read-only production audit you ran on 2026-11-23 (PostgreSQL 17.11). The audit showed `user_blocks` and `user_settings` already exist, so they are **reused, never altered or duplicated**.

## Order and what each file does

| # | File | Adds | Needs |
|---|------|------|-------|
| M0 | `M0_notifications_message_column.sql` | `notifications.message` column (additive) | nothing |
| M1 | `M1_privacy_blocks_requests.sql` | `bmn_messaging_settings` (last seen, typing, group invites, disappearing default, auto-download, theme, accent), `message_requests`, `bmn_messaging_config` (48 h edit/unsend window, group size 200, voice 300 s), functions `bmn_can_message`, `bmn_is_blocked_between`, `bmn_peer_flags`, `bmn_peers_presence`, `bmn_respond_message_request`, one RESTRICTIVE INSERT policy on `messages` | M0 |
| M2 | `M2_groups.sql` | `group_chats`, `group_members`, `group_messages`, `group_message_hides`; RPCs create group, add/remove member, leave, set role, update group, mark read, group inbox | M1 |
| M3 | `M3_message_core.sql` | new columns on `messages`/`group_messages` (reply, forwarded label, edited, unsent, expires), `message_edits`, `message_reactions`, `message_pins`, `conversation_settings` (pin/mute/archive); RPCs edit, unsend, delete-for-me, react, pin, forward, report | M1, M2 |

Apply in order M0 → M1 → M2 → M3. Each is idempotent (safe to run twice). The client detects what exists and only turns on features whose objects answer, so **deploying the new `bmn-messaging.js` before the SQL is safe** — it behaves like Batch 2 until the tables exist.

## Security model (what is enforced by the database, not the screen)

- Every new table has RLS on. Clients cannot write `message_requests`, `message_edits`, `message_pins`, or group membership directly — only through SECURITY DEFINER functions (`SET search_path TO ''`).
- `messages` INSERT gets one **RESTRICTIVE** policy (`bmn_can_message`): blocked users and "who can message me" rules are enforced for every client insert. Existing permissive policies are untouched.
- Columns `edited_at`, `unsent_at`, `expires_at`, `forwarded_*` cannot be forged by an insert (a trigger clears them); changing them is only possible through the RPCs. Direct `UPDATE` of message content is not possible.
- Groups: roles owner > admin > member. Members only see messages since their `joined_at`. A removed member loses read and post access immediately (RLS). "Only admins can post" and "members can add people" are enforced in the database. Members cannot pin, change roles or remove people (server rejects it — tested).
- Forwarding copies content server-side and fills the "forwarded from" label itself, so it can't be faked. Forwarding **to yourself is allowed** (that is "Saved messages", as in Batch 2).
- Reports go to the existing `content_reports` (new `message_id` column), for moderators.

## Things you must know before applying

1. **Render's `server.js` uses the service role, which bypasses RLS.** The block/privacy rules are enforced for browser inserts; if the Socket.IO handler also inserts messages it must call `bmn_can_message(sender, recipient)` first. This is a one-line server change I have **not** made (no server files in this batch).
2. **Read receipts:** the *display* honours `user_settings.read_receipts`. The server still lets the recipient's client mark messages read. Real enforcement would replace `bmn_mark_messages_read` (I called this M6). **Not done — needs your explicit OK.**
3. **Realtime is not published on your production tables** (audit). The app polls every 5 s, which is the real path today. If you later publish `messages`, `group_messages` etc. the client already listens.
4. `notifications` inserts appear blocked in production; the client stops trying after the first refusal (no errors shown).
5. The account-status triggers look unattached in production; M2 does its own restricted-account check.

## Rollback

Each file ends with a `-- ROLLBACK-BEGIN … ROLLBACK-END` block. Run in reverse order (M3, M2, M1). Rollback **leaves `user_blocks` and `user_settings` alone** and does not delete any messages. Tested locally: after rollback the object set equals the pre-migration snapshot.

## How to verify after you apply (read-only)

```sql
select to_regclass('public.group_chats'), to_regclass('public.conversation_settings'),
       to_regclass('public.message_requests'), to_regclass('public.bmn_messaging_settings');
select count(*) from pg_policies where schemaname='public' and tablename='messages' and policyname like 'BMN restrict%';
select proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and proname in ('bmn_can_message','bmn_group_inbox','bmn_msg_edit','bmn_forward_message');
```
Expect 4 non-null table names, 1 policy, 4 functions. Then re-run `docs/batch3/BMN_PRODUCTION_AUDIT_READONLY.sql` and compare.
