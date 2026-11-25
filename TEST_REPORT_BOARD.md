# BMN Board — test report (local simulation only)

Environment: throwaway local PostgreSQL 16 (baseline schema + production overlay + M0–M3 + B1), headless Chromium via Playwright
(iPhone 14 emulation), the real `index.html` / `bmn-board.js` / `bmn-messaging.js` against a PostgREST-like stand-in that runs every
request as role `authenticated` so the **real RLS and SECURITY DEFINER functions** decide results.
These are NOT production tests and NOT real-device tests.

## Tests actually run (all in this workspace)
| Suite | Result | Output file |
|---|---|---|
| Board SQL suite (RLS, RPCs, counters, blocks, privacy, feeds, ordering, rollback/re-apply) | **411 PASS / 0 FAIL**; B1 rollback restores the pre-B1 object set: yes; full rollback restores baseline: yes | `tests/board/results/sql_run_output.txt`, `sql_results.txt` |
| Board browser suite (UI end to end) | **66 PASS / 0 FAIL** | `tests/board/results/board_browser_output.txt`, `board_browser_results.json`, screenshots |
| Batch 3 messaging/groups browser regression (with Board in index.html) | **72 PASS / 0 FAIL** | `tests/board/results/batch3_browser_regression_output.txt` |
| Batch 3 messaging SQL regression (inside the Board SQL run, with B1 applied) | **PASS** (part of the 411) | same |
| Batch 2 regression (t1–t5) | **102 PASS / 0 FAIL** (27+20+23+17+15, identical to the Batch 2 baseline) | `tests/board/results/batch2_regression/` |

Covered by the Board browser suite: B button opens Board; empty state without fake data; composer limits; post/hashtag/mention/link
storage and rendering; HTML in posts is inert; like/unlike, bookmark, repost/undo, quote repost, reply and threads, counters equal the real
rows; views (viewer only, never the author); notifications and unread badge; Following feed and reposted context; avatar/name/@mention open
the existing profile with a "← Board" pill; hashtag, search, people search, Discover, follow from Discover; edit (history kept), delete
(tombstone), report to `content_reports.board_post_id`; block via the existing `user_blocks` (UI and server); signed-out read-only behaviour;
dark/light theme; no horizontal overflow; Settings → About BMN opens the personal page; no page errors.

## Bugs found by these tests and fixed
* Board SQL: non-deterministic feed paging for equal timestamps/scores → id tiebreakers added.
* Board UI: a follow-up sheet (Report reason, Delete/Block confirmation) was wiped by the previous sheet's close timer → fixed.
* Board UI: an old global `main { padding-top }` rule pushed the timeline down, and old global textarea styles drew a box around the composer → fixed (element changed, styles scoped with `!important`).

## NOT tested (needs a real device or production)
See the checklist in `docs/board/BOARD_README.md`: real iPhone/Safari and Android behaviour, keyboard and safe-area layout, HEIC photo upload,
R2 video upload and playback, native share sheet, haptics, signed image URLs for anonymous visitors, performance with large timelines,
and anything against the real production database (the audit SQL has not been run, so the production-specific assumptions are unverified).
