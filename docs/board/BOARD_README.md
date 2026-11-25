# BMN Board (Batch 3, part 2) — what it is, how to ship it, how to undo it

BMN Board is a text-first, X/Twitter-style discussion page **inside BMN Community**. One account, one profile system:
it has no users, profiles or follows of its own. Names, photos, @usernames, verification, follows, blocks, reports and media
storage are the existing BMN ones. Tapping any name, photo or @mention opens the normal Community profile.

Nothing in this package has been deployed, pushed, or run against production. Everything below is for you to approve.

## What changed for users
* **B button** (Community header) now opens **BMN Board**. If the Board file fails to load for any reason, B falls back to the old BMN page.
* The old personal BMN page is untouched and now lives at **Settings → App → About BMN** (all users). Its own settings sheet has an "Open BMN Board" row to get back.
* Board: For You / Following / Latest timelines, Discover (real trending #hashtags, people to follow, popular posts), Search (posts and people),
  Alerts (likes, reposts, quotes, replies, mentions), Saved (private bookmarks), post thread view with ancestors and replies,
  composer (text up to 500 chars, up to 4 photos or 1 video, #hashtags, @mentions, links), like/unlike, repost/undo, quote repost, reply,
  bookmark, share (native share sheet, else copy link), report, mute, block, edit own post (24 h, "edited" label), delete own post, views.
* No demo users, no demo posts, no invented counts. An empty database shows empty states.
* Board posts live in their own `board_*` tables and can never appear in the video feeds. The existing `posts` table is not touched.

## Files (exact repo paths)
| Status | Path |
|---|---|
| NEW | `bmn-board.js` |
| NEW | `bmn-board.css` |
| MODIFIED | `index.html` (see "What changed in index.html") |
| NEW (SQL, not run) | `supabase/proposed/B1_board_core.sql` |
| NEW (SQL, read-only) | `docs/board/BMN_BOARD_AUDIT_READONLY.sql` |
| NEW | `docs/board/BOARD_README.md` (this file) |
| NEW | `TEST_REPORT_BOARD.md` |
| NEW (tests, never shipped to users) | `tests/board/**` |

### What changed in index.html (4 edits, nothing else)
1. The B-button click handler opens `BMNBoard.open()` (falls back to `enterPersonal()` if Board is unavailable).
2. B button label/tooltip: "Open BMN Board" / "BMN Board".
3. `<link rel="stylesheet" href="/bmn-board.css">` and `<script src="/bmn-board.js" defer>` added after the messaging tags.
4. A small inline script (`id="bmn-board-integration"`) that adds the "About BMN" row to Community Settings and the "Open BMN Board" row to the personal settings sheet.

## Deployment order (each step needs your approval)
1. **Review** `docs/board/BMN_BOARD_AUDIT_READONLY.sql` (one SELECT, metadata only) and run it in Supabase SQL Editor. Send me the JSON result.
   I will check my assumptions (posts policies, `user_blocks` columns, `notifications` rules, helper function bodies) against it before you apply B1.
2. Supabase → SQL Editor: run `supabase/proposed/B1_board_core.sql` (idempotent, additive; adds `board_*` tables, RPCs, RLS, and one nullable column `content_reports.board_post_id`).
   It does not depend on the Batch 3 messaging migrations M0–M3, and does not change any existing table except that one column.
3. Upload to GitHub (Vercel deploys): `bmn-board.js`, `bmn-board.css`, `index.html`.
   Order does not matter. If the JS is live but B1 is not applied, Board shows "BMN Board is not switched on yet on this server" instead of fake content.
4. Real-device checks below.

## Rollback
* **Front end only:** revert `index.html` (B opens the personal page again). `bmn-board.js/css` can stay; they do nothing unless called.
* **Database:** the `ROLLBACK-BEGIN … ROLLBACK-END` block at the bottom of `B1_board_core.sql` drops only Board objects and the `board_post_id` column.
  **It deletes all Board data. Export first if Board already has real posts.** Tested locally: after rollback the object set equals the pre-B1 snapshot, and re-applying works.

## Things that need YOUR decision / approval
1. Run the read-only audit and send me the result (step 1).
2. Apply B1 to production (step 2) and deploy the three files (step 3).
3. **Private accounts:** Board is the first feature that honours `user_settings.private_account`. Anyone who already has it switched on will have followers-only Board posts. Say if you prefer Board to ignore it.
4. **Block enforcement outside Board:** Board honours the same `user_blocks` as messaging, but the main Community video feed does not enforce blocks today (existing behaviour, untouched).
5. "Home" is the For You / Following / Latest tab bar; there is no separate page called Home.
6. The previous "master instructions" were never received in this chat. I followed the Board correction text and your decisions. If the master instructions contain anything else for Board, paste them.

## Known limits (honest list)
* Views count one view per signed-in non-author viewer (a post must be 60% visible for ~1.2 s). Signed-out viewing is not counted.
* For You uses a simple recency + engagement score, paged by offset; at identical scores two posts that appear in the same second could in rare cases shift between pages.
* Anonymous visitors only see Board images/videos if the storage URLs can be signed for them (existing `community-media` rules). Needs a check on the real site.
* Realtime is not used; Alerts poll every 45–90 s while the app is open.
* Hashtag/mention parsing is ASCII (`#word`, `@username`).

## Real-device checklist (NOT done: cannot be tested in this workspace)
iPhone Safari (and installed home-screen app), plus one Android phone:
- [ ] B button opens Board; dock hides; Back returns to the feed; video feed resumes and sound does not leak while Board is open
- [ ] Composer: keyboard does not cover the text or the Post button; safe areas at the notch and home bar; autosize
- [ ] Photo picker: library photos including HEIC upload and display; 4 photos grid; tap to open the photo viewer
- [ ] Video: pick a video, upload through the R2 presign flow, and it plays inline in the post (this is the least proven path)
- [ ] Share: native share sheet on iPhone; Copy link on desktop; a `#board-<id>` link opens the thread
- [ ] Tap avatar / name / @mention opens the real profile; "← Board" pill returns
- [ ] Dark / light / system theme; Dynamic Type; VoiceOver labels on actions
- [ ] Scroll performance with 100+ posts; pull around the bottom nav on small phones (iPhone SE)
- [ ] Alerts badge dot on the B button appears and clears
- [ ] Settings → App → About BMN opens the old personal page; "Open BMN Board" row on the personal settings sheet works
