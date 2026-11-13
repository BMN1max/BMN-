// Root forwarder: `npm run build:glass` builds the Liquid Glass layer from its ONE source of truth, glass/src.
// Output: bmn-glass/bmn-glass.js, bmn-glass/bmn-glass.css, bmn-glass/bmn-glass-lite.css (commit these; Vercel does not build).
// Needs the root devDependencies (@zakisheriff/liquid-glass, react, react-dom, esbuild): `npm install` first.
import './glass/build.mjs';
