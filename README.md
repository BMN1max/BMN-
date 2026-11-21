# BMN Liquid Glass: Batch 1 (performance foundation)

## Upload (GitHub mobile)
1. Repo BMN1max/BMN-, open `index.html` (repo root), edit/replace it with `files/index.html` from this batch.
2. Commit. Vercel redeploys. Nothing else changes.

| Status | Path |
|---|---|
| MODIFIED | `index.html` (repo root, 54 changed lines of 1.33 MB) |
| NEW | none |
| UNTOUCHED | everything else: `bmn-glass/*`, `glass/*`, `bmn-perf.js`, `sw.js`, `manifest`, backend, Supabase, R2 code, all CSS/JS files |

No database or production config change. No fake data.

## What changed (each one found by measuring first)
1. **Ambient glow** (`.lgtt-ambient`): three 470-1000 px animated layers used `filter: blur(90px)`. That filter was re-computed whenever anything beneath repainted. Removing only this took view switches from ~12 fps to ~60 fps in my test. Same glow is now drawn with a Gaussian-shaped alpha mask (sigma 90 px). Colour still set per slide and still cross-fades. Pixel diff vs original: mean 0.8-1.2/255, max 9/255 on desktop; identical on phone viewport.
2. **Dock lens + dock refraction loops**: wrote class/style every tick even when nothing changed (~14 DOM mutations/s at idle), which woke two MutationObservers and forced style recalcs. Now writes only on change and sleeps (timer, not per-frame) when no video is showing. The live video refraction itself is unchanged.
3. **Slide progress clock**: stopped waking every frame when the feed is not the active view, nothing is playing, or the tab is hidden. The active branch is the original code.
4. **Full-screen liquid canvas**: while the Community overlay is open (it sits under a 78% scrim and drifts ~3 px/s) it now runs at ~8 fps instead of 30. Full rate otherwise.

Not removed: the Liquid Glass materials, backdrop filters, refraction, reflections, dock lens, springs.

## Measured (headless Chromium, software rendering; before -> after)
| Profile | View-switch frame time, median | Slow frames (>34 ms) |
|---|---|---|
| iPhone 14 emu, 2x CPU slowdown | 83 ms -> 17 ms | 97% -> 8% |
| Pixel 7 emu, 4x CPU slowdown | 17 ms -> 17 ms (p95 67 -> 17 ms) | 11% -> 2% |
| Desktop 1366x800 | 167 ms -> 33 ms | 94% -> 22% |

Desktop idle CPU rose 1.1% -> 2.4% for the same reason (frames now actually render).

Idle main-thread work, iPhone emu: script 45 -> 20 ms per 4 s; idle DOM writes ~15/s -> ~1/s (Profile view). Steady idle CPU is about the same as before because the original idle figure was artificially low: the page could not render frames at all. Compared with the ambient fix alone, the loop fixes halve idle CPU (11.2% -> 6.4% iPhone, 5.1% -> 2.5% desktop).

## Tests actually run
- Existing suites, patched copy: dock_test (touch) 27/27, dock_test (mouse, glass off) 24/24, bridge_test 26/26. All pass.
- init_test: 15/16 on the patched copy and 15-16/16 on the original. The one failing check (`BMNGlass.disable()` unmounts every root) is flaky on the ORIGINAL too: a glass host reappears about 2 s after `disable()` in both versions. Pre-existing, not caused by this batch, not fixed here.
- Feed with a real local WebM video (test only, not shipped): plays, dock refraction active, 4 swipes at 60 fps median vs ~15 fps before.
- No page errors in any run.

## NOT tested, needs your devices
- Real iPhone Safari, real Android Chrome, real GPU: my numbers are software-rendered emulation. Direction is reliable (a huge animated blur is costly on real GPUs too), absolute fps is not.
- Slide progress bar painting: it did not paint in my harness in either the original or the patched build, so I could not observe it live. The active code path is unchanged.
- Battery, thermal, memory.
- Real feed content from your backend.

## Please check on your phone
Open the app, switch Feed / Discover / Inbox / Profile quickly; swipe the feed; confirm the dock glass still looks the same. If anything looks different, tell me which screen.

## Next batches (not started)
Messaging, Discover, Profile, Create Studio, Stories. Messaging needs a look at the screen recording you attached; The recording is attached; I will study it at the start of that batch.
