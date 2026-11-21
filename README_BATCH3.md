# BMN Community — Batch 3 (read this first)

Repo: `BMN1max/BMN-` · Site: https://bmnng.vercel.app · Built on repo commit `65f526b`.

## What this batch is — and is not

**In this batch**

1. **Audit** of the whole product: `docs/BMN_AUDIT_REPORT.md` (inventory, architecture, measured performance problems, plan per phase, risks, release strategy).
2. **Performance governor** (`bmn-perf.js`): watches real frame times on the phone and, only when needed, switches off decorative canvases / blur. Visual identity stays. Modes: `?perf=auto` (default), `?perf=full`, `?perf=saver`.
3. **BMN Global Spotlight**: a database-driven card next to Discover search (and optionally on profiles) for holidays, seasonal and entertainment moments, global events, announcements and campaigns, with scheduling and an optional countdown. Owner manager inside the app. **No content is hard-coded and nothing is pre-filled.**
4. **Two bug fixes to my own Batch 2 work**: the Intelligence console was invisible inside the real app and was not even loaded by `index.html`; Escape did not close it.

**NOT in this batch (still to do, in later numbered batches)**

- A full redesign of every page, Liquid Glass 2.0 across all pages, Creator Studio, stories, collections, messaging redesign, the interactive BMN AI. This is a large amount of work on a 1.3 MB single-file app; doing it in one drop would break working features. The plan and order are in the audit report (section 11).
- Real-device performance results. I have no iPhone or Android phone. Everything measured is in a sandbox (see `docs/BMN_PERF_RESULTS.md`).

## Safety guarantees (checked by tests, see `docs/TEST_RESULTS_BATCH3.txt`)

- **Nothing changes in your database** by uploading these files. The one database change (Spotlight) is a separate step you run yourself, after approving it.
- The Spotlight migration is **additive only**: 2 new tables + 8 new functions; no existing table, row, policy or function is touched (tested). It has a tested rollback.
- All Platform Intelligence flags stay **off**, workers stay **off**, no AI service is connected, no moderation action is taken.
- No secrets in any browser file. **No new Render environment variables are needed for this batch.**
- Nothing is faked: no sample users, posts, statistics or Spotlight items.

## Upload order (iPhone, GitHub in Safari)

The GitHub mobile app cannot upload files. Use **Safari → github.com/BMN1max/BMN- → request desktop site** (aA menu), then **Add file → Upload files** (or **Create new file** and paste for the small ones). Uploading a file with the same name and folder **replaces** it; GitHub shows it as "modified". Commit to `main` after each group.

| Step | Files (exact repo path) | Why this order |
|---|---|---|
| 1 | `bmn-perf.js` (NEW), `bmn-spotlight.js` (NEW) | Harmless on their own: nothing loads them yet. |
| 2 | `bmn-intelligence.js` (MODIFIED) | Console visibility + Escape fix. Replaces the Batch 2 file. |
| 3 | `.vercelignore` (MODIFIED) | Keeps `spotlight/` (SQL, tests) off the public website. |
| 4 | Folder `spotlight/db/`: `003_bmn_spotlight.up.sql`, `003_bmn_spotlight.down.sql`, `spotlight_tests.sql`, `run_spotlight_tests.sh` (all NEW). Folder `spotlight/test/`: `spotlight_ui.test.js`, `pi_console_visible.test.js` (NEW). Folder `docs/`: `BMN_AUDIT_REPORT.md`, `BMN_DEVICE_TEST_CHECKLIST.md`, `BMN_PERF_RESULTS.md`, `TEST_RESULTS_BATCH3.txt` (NEW). Root: `README_BATCH3.md` (NEW) | Documentation and tests. No effect on the site. For a folder, open `…/upload/main/spotlight/db` (or type the path in "Create new file": `spotlight/db/003_bmn_spotlight.up.sql`). |
| 5 | `index.html` (MODIFIED) — **last** | This is the file that switches everything on (loads the three scripts and gates two heavy loops). Vercel redeploys in about a minute. |
| 6 | **Database (needs your approval)** — see below | Only after you have looked at the site. |

Vercel redeploys automatically after each commit. If the site ever looks wrong after step 5: open `https://bmnng.vercel.app/?perf=full`, and tell me what you see. To undo everything, restore the previous `index.html` from GitHub history (**History → the previous commit → "…" → View file → Raw**, or revert the commit).

### If you would rather not replace the 1.3 MB `index.html`

The change is exactly four edits, nothing else (verified by diff against `65f526b`):

1. Line 2126, add before `<script id="bmn-glass-tier">` : `<script src="/bmn-perf.js"></script>`
2. In the script block `bmn-lens-js`, replace `requestAnimationFrame(frame);if(t-last<45||document.hidden)return;last=t;` with
   `if(window.BMN_PERF&&BMN_PERF.skipHeavy()){setTimeout(function(){requestAnimationFrame(frame)},600);return}requestAnimationFrame(frame);if(t-last<45||document.hidden||(window.BMN_PERF&&BMN_PERF.scrolling()))return;last=t;`
3. In the script block `bmn-lg-refract-js`, replace `function frame(t){requestAnimationFrame(frame);if(dead||t-last<40||document.hidden)return;last=t;` with
   `function frame(t){if(window.BMN_PERF&&BMN_PERF.skipHeavy()){setTimeout(function(){requestAnimationFrame(frame)},600);return}requestAnimationFrame(frame);if(dead||t-last<40||document.hidden||(window.BMN_PERF&&BMN_PERF.scrolling()))return;last=t;`
4. Just before `</body>`, add: `<script src="/bmn-intelligence.js" defer></script>` and `<script src="/bmn-spotlight.js" defer></script>`

The complete `index.html` in this batch already contains all four.

## Database step (Spotlight) — only after you approve

1. Supabase → your project → **SQL Editor → New query**.
2. Paste the whole of `spotlight/db/003_bmn_spotlight.up.sql` and press **Run**. It is wrapped in one transaction: it either fully applies or does nothing. It can be run twice safely.
3. Open the app as the owner → Profile → **Spotlight** → **New Spotlight** → Save (a draft, invisible to users) → check it → **Publish**.
4. **Undo:** paste `003_bmn_spotlight.down.sql`. If announcements exist it refuses until you first run `SET bmn.confirm_rollback = 'yes';` in the same query, so nothing is deleted by accident.

I did **not** run any migration on production. Without step 6, the app behaves exactly as before: Spotlight finds no database function and shows nothing.

## File manifest

**NEW** — `bmn-perf.js`, `bmn-spotlight.js`, `spotlight/db/003_bmn_spotlight.up.sql`, `spotlight/db/003_bmn_spotlight.down.sql`, `spotlight/db/spotlight_tests.sql`, `spotlight/db/run_spotlight_tests.sh`, `spotlight/test/spotlight_ui.test.js`, `spotlight/test/pi_console_visible.test.js`, `docs/BMN_AUDIT_REPORT.md`, `docs/BMN_DEVICE_TEST_CHECKLIST.md`, `docs/BMN_PERF_RESULTS.md`, `docs/TEST_RESULTS_BATCH3.txt`, `README_BATCH3.md`

**MODIFIED** — `index.html` (4 edits, above), `bmn-intelligence.js` (2 small edits), `.vercelignore` (2 lines added)

**UNCHANGED but required (already in the repo — do not re-upload):** `bmn-glass/*`, `sw.js`, `manifest.webmanifest`, `vercel.json`, `server.js`, `routes/*`, `platform-intelligence/*` (Batches 1 and 2), `supabase/migrations/20261102090000_bmn_baseline.sql`, all other site files.

**DATABASE changes that need your approval:** `spotlight/db/003_bmn_spotlight.up.sql` only (additive, with rollback). Platform Intelligence migrations 001/002 are unchanged and not re-run.

## Tests: what was actually run, and what was not

Full list in `docs/TEST_RESULTS_BATCH3.txt`.

**Run here, all passed:** Spotlight DB 76/76 · Platform Intelligence DB 361/361 (+305 Batch 1 regression) · PI Node unit 38/38 · PI Node integration 15/15 · PI console UI (mock API) 25 checks · Spotlight in the real `index.html` 26/26 · Intelligence console visible in the real `index.html` (1/1).
**Run here, one failure that already existed:** `recommendation.test.js` at the repo root (missing module path); fails the same on the untouched repo; not changed.
**Measured, not pass/fail:** `docs/BMN_PERF_RESULTS.md` (sandbox, 3 runs per cell). Honest summary: idle CPU work dropped on the Android profile (6.7 % → 2.9 %) and in saver mode on iPhone (6.4 % → 4.5 %); boot time did not improve; `auto` on the iPhone profile was unchanged.
**NOT run — needs a real device or real services:** iPhone Safari and Android Chrome behaviour, real frame rate, sign-in/posting/upload/messages, the real Supabase, Render and R2. Use `docs/BMN_DEVICE_TEST_CHECKLIST.md` and send me the results.

## Known limits

- The governor's benefit on real phones is **unproven** until you test it.
- `package.json` points `main`/`start` at `src/server.js` while the API entry is the root `server.js`. I did not change it; check Render's Start Command first.
- The slide-progress animation loop in `index.html` runs at full rate even when idle (see the performance results); left alone this batch.
