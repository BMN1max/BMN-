# BMN Community: Liquid Glass audit and unification

## 1. What the glass system actually is

| Layer | Where | Role |
|---|---|---|
| Library engine | `bmn-glass/bmn-glass.js` (bundles `@zakisheriff/liquid-glass`) | Builds a Snell's-law displacement map and a specular rim from each element's real size and radius. |
| Dock | `GlassNav` | Bar = 6px blur + saturate + engine rim + soft shadow. Selection lens = DOM-mirror refraction with dispersion (works on every browser). |
| Bridges | `glass/src/bridges/*` | Put the library's components and engine hooks onto existing BMN elements: switches, sliders, inputs, segmented controls, and `Surfaces.tsx` for buttons, sheets and cards. |
| Legacy CSS | `index.html` (about 214 `backdrop-filter` declarations, `.lgtt-glass*`, `.bmn-quick-actions`, `.bmn-speed-hold`, ...) | The older frosted-glass layer. Still the base for everything not bridged. |

"Quick Glass" is not a class name anywhere in the upload. I took it to mean the long-press quick actions (`.bmn-quick-actions button`) and the speed pill (`.bmn-speed-hold`). They were plain `blur(10px)` + flat dark fill pills, outside the library entirely. If you meant something else, tell me which component.

## 2. The refraction problem (root causes found)

1. **Legacy `!important` rules beat the library on every bridged surface.** `.lg-glass` sets `backdrop-filter: var(--lg-filter) blur(..)`. Legacy rules such as `html.bmn-ios #lgtt .lgtt-sheet.lgtt-glass-strong` carry `!important` and ID weight. They replaced it with a plain 14–36px blur, so the engine's displacement never reached the pixels. Measured in Chromium: the dock bar had `data-lg-refract`/`--lg-refraction`; buttons, sheets and modals never did.
2. **The engine rim was overridden by the legacy `::before`.** A masked gradient replaced the computed bezel highlight. Legacy `::after` and 70–80% white gradient fills sat on top. That gives the "frosted rectangle with a glowing border" look.
3. **Safari has no backdrop refraction.** WebKit ignores `backdrop-filter: url(#svg)`. The library uses it only on Chromium, and only DOM-mirror "lens" parts (dock pill, switch and slider thumbs) refract on iOS. Surfaces there get blur + rim only. No CSS can make large iOS surfaces bend their backdrop; the honest iOS result is the Dock's bar material, consistently applied.
4. **The quality heuristic switched surface refraction off on ordinary hardware.** `<=4` cores or `<=4 GB` meant `low`, and `low` removes `--lg-filter` from surfaces. Now only `<=2` cores or `<=2 GB` starts low. The library's frame-time governor still drops to low if real frames are slow.
5. **Input bridge recursion (performance and layout bug, not visual only).** `#lgtt .lgtt-search input[type="search"]` also matched the `<input>` that GlassInput renders. Every DOM change wrapped the glass field in another glass field: 163 input wrappers on load, 158 of them nested. You can see it in the original comments sheet as a row of search icons. Fixed: 5 wrappers, 0 nested.

## 3. What changed

Modified:
- `glass/src/glass.css`: new "Unified material" block (tone tokens, per-family parameters, material, rim, press glow, offscreen and nested-glass suspension, reduced motion, reduced transparency, owner gold edge). Tokens are namespaced `--bmn-*` so a sheet's fill cannot leak into inputs inside it.
- `glass/src/bridges/Surfaces.tsx`: new families (Quick Glass, speed pill), tone chosen from the element's real text colour, one persistent root that reconciles added and removed elements.
- `glass/src/entry.tsx`: re-bridges surfaces on DOM changes and when Quick Glass nodes appear anywhere in the page.
- `glass/src/bridges/ControlBridges.tsx`: input recursion fix.
- `bmn-glass/bmn-glass.js` and `bmn-glass/bmn-glass.css`: shipped bundle, see the caveat below.
- New: `glass/patch-bundle.mjs`.

Not touched: `index.html`, layouts, dimensions, the Dock, navigation, owner red/gold identity (gold edge kept via `--bmn-edge`).

### Important caveat about the build
`bmn-glass.js` bundles the library, and the library package was not available here (no registry access, and its source is not in the repo). I could not run `npm run build`. The source files above hold the real change. I produced the shipped bundle by applying the same changes to the minified file with `glass/patch-bundle.mjs`, which anchors on exact strings and fails loudly if any anchor is missing. The TSX files parse, but they were **not compiled** here. Before relying on `src/`, run `npm install && npm run build && node patch-bundle.mjs --library-only` and re-run the tests. The library-only step applies the quality-heuristic fix, which lives in library code.

## 4. Components now on the unified material
- Round header, feed and sheet buttons (`#lgtt .lgtt-btn.lgtt-round`): tone auto (white-on-dark over video, dark-on-light inside light panels).
- Quick Glass: `.bmn-quick-actions button`, `.bmn-speed-hold` (always dark).
- Bottom sheets (`aside.lgtt-sheet`, which carries the comments panel and the other sheets) and modal cards (`.lgtt-modal-card`): tone auto.
- Already on the library material and unchanged: Dock, segmented controls, switches, sliders, inputs.

**Not yet unified:** other legacy glass in `index.html` that is outside the bridges (profile menu panel, inbox compose bar, popovers, toasts, and so on, roughly 150 remaining `backdrop-filter` declarations). Each needs its own selector added to `FAMILIES`. I did not blanket-apply it, because `.lg-glass` sets `position: relative` and would break absolutely positioned elements. Say which ones you want next.

## 5. Verification actually performed (headless Chromium only)
- Existing suites on the final build: `bridge_test` 28/28, `parity` all four modes with 0 page errors, `dock_test` 27/27 touch, 27/27 mouse, 24/24 glass-off.
- One earlier `dock_test on touch` run failed the "6 rapid alternating taps" check. I re-ran it 8 times on the patched build (1 failure) and 5 times on the original (0 failures). I could not tell whether that is timing flakiness on this 2-core sandbox or something I introduced. It passed on the final build, but treat it as unresolved.
- Striped-backdrop A/B screenshots: the Chromium-UA path now applies the real refraction filter to buttons, Quick Glass and sheets (computed `backdrop-filter` contains `url(#lg-refract-N)`). Stripes visibly bend at the rims. Originals showed a flat blur.
- Performance counts: elements with active backdrop filters 81 → 64; glass-classed DOM nodes about 500 → 137; off-screen glass paints no backdrop.
- Sheet legibility and the nested-input leak were found and fixed during testing (see screenshots in the session).

## 6. Needs real-device testing (not done)
**I did not test on iPhone Safari, the installed iOS PWA, Android Chrome or a desktop browser.** The Safari path was only exercised with an iPhone user-agent and viewport inside Chromium, which is not WebKit.
- iOS Safari and the PWA: rim, blur, dock lens, press feel, scroll smoothness in the feed with many round buttons, and whether `-webkit-backdrop-filter` flicker appears on sheets.
- Android Chrome: real refraction under load, and that the quality governor does not drop to low too eagerly.
- Tone detection (`light`/`dark` chosen from text colour) across every view, theme flip and sheet type. The shared observer watches `<body>` class, `data-bmn-theme` and `#lgttStage` `data-view`. A restyle by another path would leave the old tone until the next trigger.
- Fill and blur values (dark buttons .34, panels .66/.70 with 22px blur) are my judgement and need an eye test over real video.
- `prefers-reduced-transparency` handling is CSS only and untested; reduced-motion was only run through the existing parity mode.
