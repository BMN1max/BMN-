# BMN Glass: test report (honest)

Environment: headless Chromium (Playwright), iPhone 14 emulation, touch via CDP `Input.dispatchTouchEvent`, mouse
via Playwright, `file://` page with all network requests aborted (no real Supabase / R2 / Render API).

## Run results (last run of each)
| Suite | Result |
|---|---|
| `dock_test.js on touch` / `on mouse` | 27/27, 27/27 |
| `dock_test.js off touch` / `off mouse` | 24/24, 24/24 (original behaviour intact with the engine off) |
| `bridge_test.js` (segmented, switch, slider, input, comments, menu, sheet) | 28/28 on three consecutive runs |
| `parity.js` | `?glass=off`: no glass class and no glass hosts mounted, 0 JS errors; on / reduced-motion: 0 JS errors |

## Fixed (each reproduced, fixed, re-tested)
1. **Dock drag leaves an invisible `bmn-sh-scrim` / opens a sheet.** A drag that ended over a sign-in-gated tab
   produced a synthesized click on it (sign-in sheet), and the install-offer timer could fire mid-gesture. Both
   lens-drag handlers now refuse gated targets, the install offer waits until the user is idle, and clicks on
   `[data-close]` within 400 ms of a sheet opening are ignored (ghost click).
2. **Escape never closed the shared sheet** (also on the original site): the feed viewer's capture-phase key handler
   swallowed Escape. It now leaves Escape alone while `#bmnSheetHost` is open.
3. **Glass scrim ghost-click** closed a just-opened glass sheet; **a closing glass sheet caught the next tap**.
   Both fixed in `SheetBridge.tsx` / `glass.css`.
4. **GlassMenu overflowed the screen** when opened from a long-press near the right/bottom edge; now clamped.
5. `feTurbulence` was used only to generate a displacement map for the old CSS lens; replaced by a pre-baked
   `feImage` map (no `feTurbulence` remains in `index.html` or the bundle). Checked visually in Chromium only.

## Not tested / limitations
- **No Safari, WebKit, real iOS, Android or Windows testing.** Safari/iOS 18 behaviour (mirror renderer, haptics,
  safe-area, backdrop blur) is unverified; target is `safari15`.
- Two test-setup issues were fixed in the suite itself (install offer appearing mid-test; sheet still rising when
  touched). They were not product bugs, but timing-sensitive tests can still flake on a slow machine.
- No end-to-end test against real Supabase auth, Cloudflare R2 uploads or the Render API; those code paths are
  untouched but unexercised.
- Reduced-motion / reduced-transparency: runs without errors; behaviour was not visually verified.
- No `package-lock.json` (no registry in the build environment).
- Not deployed. Nothing was pushed to GitHub or Vercel from this session.

## Remaining work
GlassButton variants and GlassCard on feed cards; Create / DM composer styling; visual QA of every material on a
real iPhone; lockfile; deploy preview check on Vercel.
