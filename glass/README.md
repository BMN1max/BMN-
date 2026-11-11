
# BMN Glass layer (Liquid Glass integration)

An isolated React 19 layer that mounts components from
[`@zakisheriff/liquid-glass`](https://github.com/zakisheriff/Liquid-Glass) 0.3.20 (MIT) over the existing,
unmodified BMN Community DOM. The original elements stay the source of truth: they are hidden while the glass
control is active and are driven through their own `.click()` / value setters / events, so every existing
handler (auth, Supabase, R2, Render API, feeds, search, comments, messaging, profiles, PWA) keeps running.

Not affiliated with or endorsed by Apple Inc. Licence notices: `../bmn-glass/THIRD_PARTY_LICENSES.md`.

## What is wired

| Library component | Where it appears in BMN | Bridge |
|---|---|---|
| GlassNav | bottom dock (`#lgttDock`) and `.app-dock` | `src/bridges/NavBridge.tsx` |
| GlassSegmented | feed tabs, comment sort | `src/bridges/ControlBridges.tsx` |
| GlassSwitch | every `.lgtt-switch` in Settings | `ControlBridges.tsx` |
| GlassSlider | native `input[type=range]` | `ControlBridges.tsx` |
| GlassInput | comment composer and search inputs | `ControlBridges.tsx` |
| GlassSheet | shared sheet host `#bmnSheetHost` (sign-in, install offer, report) | `src/bridges/SheetBridge.tsx` |
| GlassMenu | long-press / "more" menu `#lgttMenu` | `src/bridges/MenuBridge.tsx` |
| Engine materials (`lg-glass`, `useRefraction`, `usePress`) | existing cards / panels | `src/bridges/Surfaces.tsx` |

Not done: GlassButton variants on arbitrary buttons and GlassCard on feed cards (only the surface adapter exists),
restyling of the Create / DM composers. See "Remaining work" in `TEST_REPORT.md`.

## Build

The site is a static Vercel deploy with no build step, so the built output is committed:
`bmn-glass/bmn-glass.js` + `bmn-glass/bmn-glass.css` (referenced from `index.html`).

```bash
cd glass
npm install
npm run build
```

Offline fallback: clone the library next to the repo and run
`LG_SRC=/path/to/Liquid-Glass/src/index.ts node build.mjs`.

No `package-lock.json` is included. Run `npm install` once and commit the lockfile it creates.

## Kill switch / debugging

- `?glass=off` or `?glass=on`
- `BMNGlass.disable()` / `BMNGlass.enable()` in the console.
- `?glassq=` controls glass quality (default `auto`).

## Tests

The tests use Playwright with Chromium:

```bash
cd glass/tests
node dock_test.js on touch
node bridge_test.js
node parity.js
```

Chromium only. No Safari / WebKit / real iOS testing was possible.
