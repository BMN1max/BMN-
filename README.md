# BMN Liquid Chrome — GitHub/Vercel package

## Deploy
1. Extract this ZIP.
2. Import/merge the contents into the root of the existing BMN GitHub repository.
3. Replace files with matching names and merge the `assets` directory.
4. Commit and push. Vercel should deploy automatically if linked to this repository.

## Features
- Liquid-chrome-inspired animated background and clear optical glass surfaces.
- Blue, violet, cyan, silver and restrained gold accent.
- Dark/light theme switch with saved preference.
- Responsive mobile navigation and floating dock.
- Creator biography, official links, contact section, portfolio search/filter, project details/share, command palette, glass controls, reduced-motion and low-data settings.
- BMN LIVE editor stores changes locally in the visitor's browser. It is not a public multi-user publishing backend.

## Notes
- `index.html` must remain at the repository root for a root-based static Vercel deployment.
- `bmn_api.py`, `bmn_engine.cpp`, and `bmn-types.ts` are optional extension/source files; a static Vercel frontend does not execute Python or C++ directly.
- Check the live site after deployment. Browser-specific appearance can differ depending on support for `backdrop-filter`.

## Optical glass note
The design includes an optional SVG turbulence/displacement filter for backdrop refraction where browser support permits it. Safari/iOS and other browsers may ignore SVG URL filters on `backdrop-filter`; the design intentionally falls back to transparent blur, saturation, edge reflections, and animated liquid-chrome layers without breaking the layout.
