# BMN performance measurements (Batch 3)

**What this is:** headless Chromium in a sandbox, CPU throttled (Android profile 4x, iPhone profile 2x), a stubbed Supabase, empty feed, no network. Median of the runs shown (n per cell in brackets, range after the slash). **Relative before/after signal only. NOT real-phone performance.**

"baseline" = the live repo at commit 65f526b. "auto" and "saver" = this batch, with the governor in `?perf=auto` and `?perf=saver`.

Scroll FPS is deliberately **not reported**: the harness has an empty feed and could not drive a real scroll, so those numbers would mean nothing.

## android-mid (4x CPU, lite tier)

| Metric | baseline | auto | saver |
|---|---|---|---|
| Script time during boot (s) | 0.42 (n=3, 0.42–0.43) | 0.33 (n=3, 0.33–0.34) | 0.32 (n=3, 0.31–0.35) |
| Long-task time during boot (ms) | 486 (n=3, 460–604) | 496 (n=3, 366–497) | 544 (n=3, 451–570) |
| Idle main-thread busy (%) | 6.7 (n=3, 6.7–6.8) | 2.9 (n=3, 2.7–3) | 2.8 (n=3, 2.3–3.1) |
| Idle animation callbacks / s | 15.2 (n=3, 14.8–16.4) | 60.2 (n=3, 60–60.4) | 60.2 (n=3, 60.2–60.2) |
| Style recalcs by 6 s | 141 (n=3, 136–146) | 73 (n=3, 72–73) | 72 (n=3, 69–72) |
| Page errors | 1 (n=3, 1–1) | 0 (n=3, 0–0) | 0 (n=3, 0–0) |

## desktop (no throttle)

| Metric | baseline | auto | saver |
|---|---|---|---|
| Script time during boot (s) | 0.47 (n=3, 0.45–0.5) | 0.46 (n=3, 0.46–0.48) | 0.44 (n=3, 0.41–0.48) |
| Long-task time during boot (ms) | 124 (n=3, 68–170) | 132 (n=3, 125–133) | 86 (n=3, 82–129) |
| Idle main-thread busy (%) | 2.1 (n=3, 1.9–2.8) | 2.7 (n=3, 2.3–2.7) | 2.2 (n=3, 2.1–2.4) |
| Idle animation callbacks / s | 22 (n=3, 21.2–22) | 21.6 (n=3, 21.2–23.2) | 47.8 (n=3, 47.2–49.2) |
| Style recalcs by 6 s | 375 (n=3, 375–377) | 380 (n=3, 378–383) | 347 (n=3, 346–357) |
| Page errors | 0 (n=3, 0–0) | 0 (n=3, 0–0) | 0 (n=3, 0–0) |

## iphone (2x CPU, full tier)

| Metric | baseline | auto | saver |
|---|---|---|---|
| Script time during boot (s) | 1.56 (n=3, 1.39–1.78) | 1.38 (n=3, 1.35–1.4) | 1.48 (n=3, 1.32–1.52) |
| Long-task time during boot (ms) | 1204 (n=3, 1083–1542) | 1080 (n=3, 1008–1161) | 1029 (n=3, 893–1208) |
| Idle main-thread busy (%) | 6.4 (n=3, 6.1–7.3) | 6.4 (n=3, 5.3–6.9) | 4.5 (n=3, 4.3–4.6) |
| Idle animation callbacks / s | 81.2 (n=3, 80.4–83.6) | 83.6 (n=3, 81.6–84.4) | 57.8 (n=3, 54.8–58.2) |
| Style recalcs by 6 s | 408 (n=3, 406–414) | 416 (n=3, 406–419) | 360 (n=3, 358–363) |
| Page errors | 0 (n=3, 0–0) | 0 (n=3, 0–0) | 0 (n=3, 0–0) |

## How to read these numbers (honest interpretation)

- **Reliable signals** (consistent across the 3 runs): *idle main-thread busy* and *style recalculations*. They measure work the page does when you are doing nothing.
- **Android profile, `auto`:** this sandbox's emulated Android reports few CPU cores, so the governor correctly started at level 1. Idle main-thread work fell from **6.7 % to 2.9 %**, style recalcs from **141 to 73**, script time during boot from **0.42 s to 0.33 s**. Long-task time during boot did **not** improve (486 → 496 ms).
- **iPhone profile, `auto`:** the same as baseline (within noise). That is expected: the governor only steps down when frames are actually slow, and in this harness they are not. **I have no evidence that `auto` changes anything on a real iPhone until it is tried on one.**
- **iPhone / desktop, `saver`:** idle main-thread work **6.4 % → 4.5 %** (iPhone), style recalcs **408 → 360**, animation callbacks 81 → 58 per second.
- **"Idle animation callbacks / s" went UP on Android and on desktop `saver`** (15 → 60, 22 → 48). That is not an improvement and I am not counting it as one. Cause (measured by listing which loop registers the callbacks): the slide-progress clock (`tick`, a `requestAnimationFrame` loop in `index.html`) runs at full display rate once the heavy background loop stops starving the main thread. In the baseline it was throttled only because the main thread was busy. This loop does nothing when the feed is empty or paused; stopping it when there is nothing to animate is a safe future fix, **not done in this batch.**
- **Boot cost is essentially unchanged** everywhere. Batch 3 does not make the first load faster. Load speed needs the structural work in the audit (phases 5–6), not a governor.
- **What the harness cannot show:** real video decoding, the GPU cost of backdrop blur on a phone, scroll smoothness with a real feed, memory pressure, network latency. Those need your phone (see `BMN_DEVICE_TEST_CHECKLIST.md`).
- An earlier set of measurements was thrown away: the harness had a bug (a catch-all network block registered before the Supabase stub, so the stub never loaded). These numbers are from the fixed harness, 3 runs per cell.
