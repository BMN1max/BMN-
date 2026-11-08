// Builds src/entry.tsx into ./bmn-glass/bmn-glass.js (+ bmn-glass.css).
//
//   npm install && npm run build
//
// Fallback (no registry access): point LG_SRC at a checkout of
// https://github.com/zakisheriff/Liquid-Glass (src/index.ts) and, if React
// is not in ./node_modules, NODE_PATH at a folder that contains react + react-dom.
import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const here = path.dirname(fileURLToPath(import.meta.url));
const alias = process.env.LG_SRC
  ? { '@zakisheriff/liquid-glass': process.env.LG_SRC }
  : {};
const nodePaths = (process.env.NODE_PATH || '')
  .split(path.delimiter)
  .filter(Boolean);
// With the npm package, use its published stylesheet.
// With LG_SRC, components import their own CSS.
const entry = process.env.LG_SRC
  ? "import './src/entry.tsx';"
  : "import '@zakisheriff/liquid-glass/styles.css';\nimport './src/entry.tsx';";
const result = await build({
  stdin: {
    contents: entry,
    resolveDir: here,
    sourcefile: 'bmn-glass-entry.js',
    loader: 'tsx',
  },
  // Keep generated bundles inside bmn-glass/ for Vercel.
  outfile: path.join(here, 'bmn-glass', 'bmn-glass.js'),
  bundle: true,
  format: 'iife',
  minify: true,
  banner: {
    js: '/*! BMN Glass layer. Bundles @zakisheriff/liquid-glass (MIT, (c) 2026 Zaki Sheriff) and React / ReactDOM (MIT, (c) Meta Platforms, Inc.). Licence texts: bmn-glass/THIRD_PARTY_LICENSES.md. Not affiliated with or endorsed by Apple Inc. */',
    css: '/*! BMN Glass layer styles. Includes @zakisheriff/liquid-glass (MIT). See THIRD_PARTY_LICENSES.md. */',
  },
  sourcemap: false,
  target: ['safari15', 'chrome92', 'firefox91'],
  jsx: 'automatic',
  loader: { '.css': 'css' },
  legalComments: 'eof',
  define: { 'process.env.NODE_ENV': '"production"' },
  alias,
  nodePaths,
  metafile: true,
  logLevel: 'info',
});
const out = Object.entries(result.metafile.outputs).map(
  ([file, output]) =>
    `${path.basename(file)} ${(output.bytes / 1024).toFixed(1)} KiB`
);
console.log(
  'built:',
  out.join(' · '),
  process.env.LG_SRC ? '(library from LG_SRC)' : '(library from npm)'
);
