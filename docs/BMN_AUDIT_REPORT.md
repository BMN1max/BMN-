# BMN Community — Product, Architecture and Performance Audit (Batch 3)

Date: 2026-11-21 · Repo: `BMN1max/BMN-` at commit `65f526b` (the starting point for Batch 3) · Live site: https://bmnng.vercel.app

**How to read this report.** Every statement is labelled:

- **MEASURED** — produced by a script in this batch, in headless Chromium inside a sandbox, with a stubbed backend and no network.
- **READ** — found by reading the code. Not executed on a device.
- **NOT TESTED** — needs a real iPhone/Safari or Android phone, real Supabase data or the real network. Nothing here is claimed for these.

The sandbox has no real Supabase, Cloudflare R2, Render or phone. Every performance number below is therefore a *relative* signal (before vs after, on the same machine, with CPU throttling), **not** a prediction of frame rate on your phone.

---

## 1. Feature inventory (READ)

All of this lives in one file, `index.html`, plus a few scripts.

| Area | What the code contains |
|---|---|
| Sign-in / accounts | Supabase auth (email + OAuth entry points), profile editor, profile architecture panels, settings sheet |
| Community feed ("BMN Reels") | Vertical full-screen video feed (`#lgtt`), Following / For You, like, comment sheet, share, mute, swipe hint |
| Discover | Search box, hashtag chips, "Creators to follow", trending grid |
| Create / upload | Create flow, media upload to Cloudflare R2 through the Render API (tus resumable uploads for large files) |
| Profiles | Profile header and actions, anchored "BMN Page", follow / followers |
| Messages / Inbox | Direct messages, Socket.IO realtime through the Render API |
| Creator features | Creator tips, payout-account SQL, creator update panels |
| Owner tools | `is_bmn_owner()` gated admin RPCs (post hide/remove), **Platform Intelligence console** (Batch 2), **Spotlight manager** (Batch 3) |
| Glass UI | Tiered "Liquid Glass" system: `lite` (CSS only), `ios` and `desktop` (React engine in `bmn-glass/`) |
| PWA | `manifest.webmanifest`, icons, `sw.js` (network-first with timeout) |
| Backend (Render) | `server.js`, `supabase.js`, `media.js`, `routes/`, `recommendation.js`, `tips.js`, `platform-intelligence/server/` |

## 2. Architecture (READ)

```
iPhone / Android / desktop browser
        │
        ├── Vercel (static):   index.html  (1.33 MB, 11,887 lines)
        │                      bmn-glass/ (pre-built React glass engine, 272 KB)
        │                      bmn-intelligence.js · bmn-spotlight.js · bmn-perf.js · sw.js
        │
        ├── Supabase:          auth + Postgres (RLS, SECURITY DEFINER RPCs)  ← source of truth
        ├── Cloudflare R2:     media (via signed uploads from the Render API)
        └── Render (Node/Express, CommonJS):
                               server.js, routes/, socket.io, workers, /api/pi/*
```

- Owner = row in `bmn_admins` with `role='owner'`, tested by `public.is_bmn_owner()`.
- `.vercelignore` keeps backend, SQL, docs and old design copies off the public site. This batch adds `spotlight/` to it.
- Globals the front end shares: `window.bmnSupabase`, `window.bmnSession` (both set **asynchronously** after the page loads), `window.BMN_API_BASE_URL`, `window.LGTT`.

**Structural risk (READ, MEASURED counts):** `index.html` is built from **85 stacked inline CSS "patch layers"** (3,023 `!important` declarations) and **62 inline `<script>` blocks** (719 KB of JS). Later layers override earlier ones. This makes any change fragile. Two real examples were hit in this batch:

1. A rule `html.bmn-community-app body > :not(#lgtt){display:none!important}` hides every full-screen element that is added directly to `<body>`. It made the **Batch 2 Intelligence console invisible** (fixed in this batch, see section 7).
2. Several document-level keyboard handlers stop key events from bubbling, so an Escape handler registered normally never fires (fixed for both owner panels).

## 3. Working vs broken features

**Verified in this batch (MEASURED/tested):** the site loads with a stubbed backend and no page errors in the harness; the Spotlight database and browser behaviour; the Intelligence console (after the fix); the Batch 2 database and server tests (see the README for the actual results).

**NOT TESTED (needs real accounts, data or a phone):** sign-in, posting, uploading, comments, messages, tips, payouts, realtime, the feed with real videos, the service worker on a real device, push, video playback on iOS Safari, Android Chrome behaviour. I did not run these and I am not claiming they work or are broken. The first real-device pass should be done by you using the checklist in `docs/BMN_DEVICE_TEST_CHECKLIST.md`.

**Defects found by reading/measuring:**

| # | Defect | Status |
|---|---|---|
| 1 | Intelligence console hidden by the site's own CSS (Batch 2 bug, mine) | **Fixed + tested** |
| 2 | Escape key did not close the Intelligence console (same cause as above) | **Fixed + tested** |
| 3 | `package.json` says `main`/`start` = `src/server.js`, but the Render API entry is the root `server.js` | **Open — not changed.** Check what Render's *Start Command* is set to before changing anything. |
| 4 | 455 `addEventListener` vs 5 `removeEventListener` | Open. Probably harmless in a single page that never unmounts; a leak risk only if views are re-created. |
| 5 | One unidentified `pageerror` appeared in an early baseline run | Open. It did not reproduce in the later Spotlight browser runs (0 page errors). |

## 4. Performance problems (MEASURED + READ)

Counted from the page in headless Chromium after boot and from the code:

| Finding | Count |
|---|---|
| `setInterval` timers | **23** (17 of them fire faster than once per second) |
| `requestAnimationFrame` callbacks per second at idle | **~140** combined, from ~9 separate loops |
| Broad `MutationObserver`s watching `body`/`html` subtrees | **19** |
| `backdrop-filter` declarations | **572** (313 blur values, up to 90 px) |
| Per-pixel video refraction: `getImageData` every 40 ms (iOS tier only) | 1 loop |
| Lens canvas: `drawImage` every 45 ms | 1 loop |
| Full-screen animated background canvas | 1 |

## 5. Why phones lag (READ — a hypothesis, NOT confirmed on a device)

In order of my confidence:

1. **Many always-on loops** (timers + rAF + observers) keep the main thread and the compositor busy even when nothing is happening. On a mid-range Android this directly costs battery and frames.
2. **Backdrop blur is the most expensive thing a mobile GPU does**, and the page declares 572 of them. Each blurred layer re-samples what is behind it every frame while anything underneath moves (the video feed always moves).
3. **iOS tier only:** reading pixels back from video (`getImageData`) forces a GPU→CPU copy every 40 ms.
4. **Android is already on the lite tier** (no React engine, CSS only), so Android lag is more likely items 1 and 2 plus video decode, not the glass engine.
5. Layout cost from the very large DOM and the 3,023 `!important` rules.

I could not run a profiler on a real phone, so items 2–3 are reasoned from how the browsers work, not measured on your hardware.

## 6. Liquid Glass performance assessment

- The glass is **a good visual identity and is kept.** Nothing was removed.
- The cost comes from *how many* blurred surfaces are on screen at once and from the iOS pixel-readback loops, not from glass as an idea.
- Batch 3 adds a **performance governor** (`bmn-perf.js`) that watches real frame times on the device and, only if the device is struggling, steps effects down in two levels:
  - Level 1: hides the three decorative canvases (animated liquid background, video refraction, lens), pauses the background animation and makes the two heavy iOS loops idle. Blur and layout stay.
  - Level 2 ("saver"): additionally replaces backdrop blur with solid translucent panels. Colours and layout stay.
  - In `auto` mode it starts at level 1 only on Android phones that report ≤3 GB memory or ≤4 CPU cores, or on devices with "reduce motion/transparency" switched on; otherwise it starts at level 0 and steps down only when the 75th-percentile frame time stays above 28 ms (under ~35 fps) for two sampling windows in a row (ignores the first 8 s and hidden tabs). A step-down is remembered for 24 hours.
- It can be forced with the address `?perf=full` (never degrade), `?perf=saver` (always level 2) or `?perf=auto` (default). The choice is remembered on that device until you open `?perf=auto`.
- **Whether this feels smoother on a real phone is NOT TESTED.** The numbers are in `docs/BMN_PERF_RESULTS.md`.

## 7. Changes made to existing behaviour in this batch

- `index.html`: four targeted edits (diffed): load `bmn-perf.js`; gate the two iOS refraction/lens loops with `BMN_PERF.skipHeavy()`; load `bmn-intelligence.js` and `bmn-spotlight.js`. **The file was not rewritten.**
- `bmn-intelligence.js`: visibility rule for the console + capture-phase Escape handler (2 small edits).
- `.vercelignore`: adds `spotlight/`.

## 8. Platform Intelligence integration status

- Batch 1 (schema 001) and Batch 2 (engine 002, Node backend `/api/pi/*`, owner console) are in the repo. The engine runs in **shadow mode only**: it records decisions and recommendations but takes **no automatic action** on any user, post or message.
- All feature flags are **off**. Workers are **not activated**. No AI provider is connected.
- Moderation enforcement (hide/limit, using these decisions) needs a future migration, a separate optional **PI migration 003 "hooks"** that is **not** part of this batch. To avoid confusion, the Spotlight migration is stored separately as `spotlight/db/003_bmn_spotlight.*.sql` and is **independent** of Platform Intelligence. It does not touch any `pi_` object.

## 9. Required database changes (need your approval; none applied)

Only one, and it is additive: `spotlight/db/003_bmn_spotlight.up.sql`.

- Adds 2 tables (`bmn_spotlights`, `bmn_spotlight_audit`) and 8 functions.
- **Changes no existing table, column, row, policy or function** (tested: schema and row data identical before/after).
- Tables are locked: no direct read or write from the app. Everyone may call only `bmn_spotlight_active()` (published items inside their time window). Only the owner may manage.
- Has a tested rollback (`003_bmn_spotlight.down.sql`) that refuses to delete announcements unless you explicitly confirm.
- **Without this migration the app behaves exactly as before** (the Spotlight script finds no function and shows nothing).

## 10. Proposed application structure (for later batches)

Keep the single-page shell, but stop adding patch layers. Recommended direction, in order of risk:

1. Freeze `index.html` as the shell. New features ship as separate files loaded after it (as Spotlight does).
2. Move CSS layers into a few real files, one per area (shell, feed, discover, profile, glass), then delete overridden rules *only after* a visual diff proves they are dead.
3. Replace the many timers/observers with one scheduler and per-view mount/unmount.
4. Introduce the redesigned screens behind a `?ui=v2` switch so the current UI remains the default until you approve.

## 11. Phased plan — what each phase touches

| Phase | Goal | Files / systems affected | DB change? |
|---|---|---|---|
| **3 (this batch)** | Audit, performance governor, BMN Global Spotlight, 2 bug fixes | `index.html` (4 edits), `bmn-perf.js` (new), `bmn-spotlight.js` (new), `bmn-intelligence.js` (2 edits), `.vercelignore`, `spotlight/*`, `docs/*` | Spotlight 003 — **needs approval** |
| 4 | Real-device measurement pass and fixes from it | `bmn-perf.js` thresholds, possibly `index.html` loops | none |
| 5 | Redesign of Discover, Profile, Create pages behind `?ui=v2` | new `ui-v2/*.css/js`, small hooks in `index.html` | none |
| 6 | Liquid Glass 2.0 (iOS refined, Android optimised, desktop restrained) | `bmn-glass/*`, glass CSS layers | none |
| 7 | Creator Studio, stories, collections, messaging improvements | new files + `routes/` on Render | yes, each separately approved |
| 8 | Interactive BMN AI | Render API only (provider keys in Render env vars, never in the browser); PI hooks migration | yes, approval-gated |
| 9 | Platform Intelligence enforcement (optional) | PI migration "hooks" + server | yes, approval-gated; flags stay off until you switch them on |

## 12. Risks

| Risk | Mitigation |
|---|---|
| Real-device behaviour differs from the sandbox | Phase 4 device pass; `?perf=full` and `?perf=saver` let you compare on your phone in seconds |
| The governor degrades a device that is actually fine | It only steps down after sustained slow frames and can be pinned with `?perf=full` |
| Patch-layer CSS overrides new UI (this already happened twice) | Every new overlay is tested inside the real `index.html` with `html.bmn-community-app` active |
| Spotlight migration | Additive, tested up/down, applied only when you say so |
| Wrong owner link/text shown to everyone | Links limited to `https://` or an in-app `/path`; enforced in the database and the browser; text is always rendered as text |

## 13. Testing and release strategy

1. Upload the files in the order in `README_BATCH3.md`. **Nothing user-visible changes** until the governor is judged on your phone: it is on `auto` by default.
2. Open the site on your iPhone, then on an Android phone. Run the checklist in `docs/BMN_DEVICE_TEST_CHECKLIST.md`.
3. Only after that, approve and run the Spotlight migration in the Supabase SQL editor (instructions in the README), create a **draft**, look at it, then publish.
4. If anything looks wrong: `?perf=full` turns the governor off for you; removing the `<script src="/bmn-spotlight.js">` line removes Spotlight; the DOWN migration removes its tables.
