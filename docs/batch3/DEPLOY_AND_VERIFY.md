# Batch 3 — deploy steps, limits, and what still needs a real device

## Upload (GitHub mobile)
Replace these two files at the repo root (everything else in this batch is new files under `supabase/proposed/`, `docs/batch3/`, `tests/batch3/`):
- `bmn-messaging.js` — MODIFIED (messaging, groups, inbox redesign, themes, actions, gestures, settings)
- `bmn-messaging.css` — MODIFIED

`index.html` is unchanged from Batch 2 (it already loads these two files). Vercel redeploys on commit. Then, when you decide, apply M0→M1→M2→M3 in Supabase (see MIGRATION_REVIEW.md). Nothing else to configure; no paid service.

## What this batch delivers
- **Inbox redesign:** avatar / group picture, name, last-message preview, time, unread count, online dot (only where the person's privacy allows), pinned and muted indicators, "Draft:" preview, All / Unread / Groups filter, Archived, Message requests. List and thread have **solid** backgrounds; Liquid Glass only on small surfaces (back/title circles, search, filter pill, composer, menus, sheets, toasts).
- **Themes:** Dark, Light, System (follows the device live), five accents. Saved on the device and, when M1 is applied, on the account.
- **Groups:** create, name/description/photo, add/remove by permission, owner/admin/member roles, leave, "only admins can send", text/images, replies, reactions, edit, unsend, delete for me, forward, pin, report, unread + previews. Uses the same messaging screen as one-to-one (no second system).
- **Message actions:** long-press menu (Reply, React, Copy, Forward, Edit, Delete for me, Unsend, Pin, Save, Select multiple, Report), swipe to reply, jump to the replied-to message, iPhone-style edge-swipe back, row swipe (pin / mute / archive / delete), persistent drafts.
- **Privacy/settings:** read receipts, activity status (existing `user_settings`), typing indicators, last seen, group invites, auto-download, theme/accent.
- **Block + message requests:** enforced by the database once M1 is applied.

## NOT built in this batch (stated plainly)
Voice messages · scheduled messages (server-side) · disappearing messages in one-to-one chats (the group column exists, no UI/cleanup job) · safe link previews · online/typing for groups beyond what is listed · **BMN Board** (the "B" tab) · **Settings → About BMN** · Liquid Glass polish pass over the whole site · read-receipt enforcement (M6) · Render `server.js` change. These are the next stages; they were not started and nothing claims them.

## Known limits
- Typing indicators use a realtime broadcast channel (no database writes); broadcast channels are not protected by RLS.
- With realtime unpublished, new messages arrive within ~5 s by polling.
- Render start command: `package.json` has `main/start = src/server.js`, which does not exist in the repo. I still need your Safari `/health` result and the Render *Settings → Start Command / Root Directory* values to resolve this honestly. Not changed.

## Verification checklist after you apply the SQL (on your phone)
1. Open Messages → settings (gear). Switch Dark / Light / System; reopen the app — theme persists.
2. New message (pencil) → New group → pick two people → Create. Send a message; the other person sees it within ~5 s with an unread badge.
3. Long-press a message: menu appears. Reply, react, edit your own, unsend.
4. As a member (not admin), confirm Pin is absent; as owner, Pin works.
5. Block someone, then ask them to message you — it must fail.
6. Swipe a row left (mute/archive/delete) and right (pin). Swipe from the left edge inside a chat to go back.

## Tests actually run (all local, simulated — NOT production, NOT a real phone)
| Suite | Result |
|---|---|
| SQL on local PostgreSQL 16 with real RLS (`tests/batch3/sql/run.sh`) incl. idempotency + rollback | **230 pass / 0 fail**, rollback restores baseline |
| New browser suite, real client in headless Chromium (iPhone viewport) against local PostgreSQL via a PostgREST-like stand-in, so real RLS decides (`tests/batch3/browser/t10_batch3.js`) | **72 pass / 0 fail** |
| Batch 2 baseline (original 102 checks, old stand-in) against the new module | **102 pass / 0 fail** |
| `glass/tests` bridge / dock / init | 26 / 27 / 16 pass; `init_test` showed one flaky failure once (15/16), then 16/16 twice, with old and new module |
Raw outputs: `tests/batch3/results/`. Screenshots (headless Chromium, mobile viewport): `tests/batch3/results/screenshots/`.

Not covered by the new automated suite (code exists, untested here): sending images in chats/groups, group photos, forwarding several messages at once, multi-select, wallpapers. Test these on your phone.

Fixed during testing: forwarding to "Saved messages" was refused by M3 (now allowed); settings toggles were being recoloured by the site's glass script; the site's bottom dock covered the settings sheet's buttons.

## Needs a real iPhone / Safari / Android (NOT tested)
Touch feel of long-press, swipe-to-reply, row swipe and edge-swipe (tested only with synthetic pointer events) · haptics · keyboard + safe-area behaviour on real devices · `backdrop-filter` performance and the Android fallback · image picker/camera · iOS PWA behaviour · Dark/Light "System" switch via the real OS setting · notification behaviour · anything against the real Supabase/Render.
