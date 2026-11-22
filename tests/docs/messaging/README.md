# BMN Messaging, Batch 2

Messaging is rebuilt as one self-contained module. Authentication, Supabase tables, storage, the Render API and every other section are untouched. **No database change is required.**

## What I found in the existing inbox

| Area | Finding |
|---|---|
| Worked | Opening the inbox from the dock, listing real conversations, sending text, photo upload, per-chat wallpaper (device-only), clearing a conversation, a basic realtime listener. |
| Broken | **Read receipts never saved.** The old code updated `messages.read_at` directly, but the database has no UPDATE policy, so nothing was stored and unread counts came back after reload. Now uses the existing `bmn_mark_messages_read` function. |
| Broken | **Newest messages could be missing** in long chats (history was loaded oldest-first with a limit). Now newest-first with "earlier messages" paging. |
| Broken | **Dock Inbox badge was fake** (it counted demo data). It now shows your real unread count, also while Messages is closed. |
| Missing | No way to start a conversation with someone new. Added (search people, suggestions from who you follow). |
| Missing | No fallback if `messages` is not in the realtime publication. Added polling (every ~5 s) so messages still arrive. |
| Weak | Styling was spread across many overrides and forced dark. Replaced with one stylesheet, dark and light. |

## What Messaging does now
- Conversation list from real data: latest message, time, unread badge, search, long-press / right-click menu.
- New message sheet, "Saved messages" (chat with yourself).
- Chat: newest-first history with paging, day separators, unread divider, grouped bubbles, read ticks, scroll-to-latest button with a count.
- Sending: instant (optimistic) bubble, failure shows "Not sent. Tap to retry" and the text is never lost. Enter sends on desktop; on phones Enter is a new line.
- Photos (existing storage bucket), full-screen photo viewer, safe link detection, large emoji-only messages, shared-post cards, quick reaction buttons.
- Per-chat wallpaper (same device-local storage key as before, so existing wallpapers keep working), clear conversation (hides it for you only).
- Escape steps back one level instead of closing the whole app.
- Liquid Glass: floating glass header, composer and sheets with the BMN specular edge. Bubbles are flat fills so long threads scroll lightly. Android keeps its existing solid fallback. Dark and light follow the app theme. iPhone safe areas, 16 px inputs (no zoom), 44 px targets, keyboard offset.

Deliberately **not** added, because they need database changes or would be a dead control: voice messages, replies, pinned messages, per-message delete, typing/last-seen presence (privacy).

## Files to upload (4 files, exact repo paths)
| # | Path in repo | Status |
|---|---|---|
| 1 | `index.html` | MODIFIED (old inline inbox UI and old wallpaper script switched off, dock and profile "Message" hooks pointed at the new module, real dock badge, 2 tags added) |
| 2 | `bmn-messaging.js` | NEW |
| 3 | `bmn-messaging.css` | NEW |
| 4 | `docs/messaging/OPTIONAL_messaging.sql` | NEW (optional, not deployed by Vercel, see below) |

Nothing else changes. `sw.js` needs no edit (network-first).

## Optional migration (separate, not required)
`docs/messaging/OPTIONAL_messaging.sql` has two additive, idempotent parts with rollback lines: (1) add `messages` to the realtime publication for instant delivery, (2) a read-only `bmn_inbox_conversations()` function, SECURITY INVOKER so existing RLS applies. **I have not run it against any server.** Without it the app works using polling.

## Tests actually run (102 messaging checks, all passed)
Run in headless Chromium (iPhone 14 profile, plus Pixel 7 and desktop) against the real `index.html` with a **stand-in Supabase backend** I wrote from your baseline SQL (RLS for select/insert, no update policy, the two RPCs, realtime). It is not your production database.

- Persistence and delivery (27): history survives reload, exactly one copy per message, live delivery between two accounts, read ticks update live, dock badge is the real count and survives reload, notification row created, logged-out users are sent to sign-in.
- Permissions: a stranger sees none of A/B's messages, a forged `sender_id` is rejected, others' messages cannot be edited.
- Failure and fallback (20): newest-60 paging with scroll anchoring over 150 messages, failed send then retry (stored once), offline then retry, HTML in a message is never executed, 5000-character limit, delivery and badge updates with realtime switched off.
- Features (23): new-message search and first message, list search, photo upload/viewer/non-image rejection, wallpaper persistence, clear (hidden for me only, other side keeps it), saved messages, optional RPC path.
- Layout (17): no horizontal overflow, 16 px inputs, 44 px targets, emulated keyboard (300 px) and emulated notch/home-bar insets, light-mode contrast, Android solid fallback, desktop Enter / Shift+Enter / Escape.
- Entry points and regressions (15): every dock tab, `LGTT.openInbox`, `LGTT.openSelfChat`, profile "Message" button, invalid or unknown ids, rapid open/close, expired session mid-send.
- Existing suites on the final build: dock 27/27, 24/24, 27/27, bridge 26/26, init 15/16 (the one failure, `BMNGlass.disable()`, also fails on the original build). Batch 1 performance harness: idle and transitions unchanged versus before (idle busy 5.3% vs 5%, p50 16.7 ms both).

## NOT tested, needs your real devices
- Real iPhone/Safari: the on-screen keyboard (I only emulated it), notch/home-bar insets (emulated), long-press menu, photo picker, home-screen app mode, scrolling smoothness with the glass header on a real GPU. In headless software rendering with 4x CPU throttle, scrolling a 60-message chat had a median frame of 17-50 ms (noisy) and about 17 ms with blur off, so the blur over the thread is the thing to watch on older iPhones.
- Android devices, other iOS versions.
- Your **production** Supabase: please send one message each way between two real accounts, and check that unread clears after opening. If delivery is slower than a second or two, `messages` is not in the realtime publication (run part 1 of the optional SQL).
- Seen once in my tests: tapping Inbox while logged out within about 3 seconds of page load, with several test browsers running, threw a one-off error from the app's own overlay code before it had finished starting. I could not reproduce it alone and did not confirm whether it exists on the old build.

## Known limits
- "Clear conversation" is not offered for Saved messages (the server function refuses self-chats and there is no UPDATE policy).
- Wallpapers are stored on the device only (as before).
- The old social-hub compose code deeper in `index.html` is untouched and no longer reachable from the dock.
- The client still writes the message notification row (existing behaviour).

## Upload from iPhone
Upload the 4 files from the `repo/` folder to the same paths in GitHub (replace `index.html`). Vercel redeploys on its own.
