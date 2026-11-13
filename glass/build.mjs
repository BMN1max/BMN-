// Builds src/entry.tsx into ../bmn-glass/bmn-glass.js (+ bmn-glass.css).
//
//   cd glass && npm install && npm run build
//
// Fallback (no registry access): point LG_SRC at a checkout of
// https://github.com/zakisheriff/Liquid-Glass (src/index.ts) and, if React is
// not in ./node_modules, NODE_PATH at a folder that contains react + react-dom.
import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import fs from 'node:fs';
import { transform } from 'esbuild';

const here = path.dirname(fileURLToPath(import.meta.url));
const alias = process.env.LG_SRC ? { '@zakisheriff/liquid-glass': process.env.LG_SRC } : {};
const nodePaths = (process.env.NODE_PATH || '').split(path.delimiter).filter(Boolean);

// With the npm package the stylesheet is its published `styles.css`; with LG_SRC
// (library source) every component imports its own CSS, so nothing to add.
const entry = process.env.LG_SRC
  ? "import './src/entry.tsx';"
  : "import '@zakisheriff/liquid-glass/styles.css';\nimport './src/entry.tsx';";

const result = await build({
  stdin: { contents: entry, resolveDir: here, sourcefile: 'bmn-glass-entry.js', loader: 'tsx' },
  outfile: path.join(here, '../bmn-glass/bmn-glass.js'),
  bundle: true,
  format: 'iife',
  minify: true,
  banner: { js: '/*! BMN Glass layer. Bundles @zakisheriff/liquid-glass (MIT, (c) 2026 Zaki Sheriff) and React / ReactDOM (MIT, (c) Meta Platforms, Inc.). Licence texts: bmn-glass/THIRD_PARTY_LICENSES.md. Not affiliated with or endorsed by Apple Inc. */', css: '/*! BMN Glass layer styles. Includes @zakisheriff/liquid-glass (MIT). See THIRD_PARTY_LICENSES.md. */' },
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
const out = Object.entries(result.metafile.outputs).map(([f, o]) => `${path.basename(f)} ${(o.bytes / 1024).toFixed(1)} KiB`);
console.log('built:', out.join(' · '), process.env.LG_SRC ? '(library from LG_SRC)' : '(library from npm)');

// Android profile: a separate, tiny, CSS-only stylesheet. The engine bundle is never loaded there.
const lite = await transform(fs.readFileSync(path.join(here, 'src/lite.css'), 'utf8'), { loader: 'css', minify: true, target: ['chrome92'] });
fs.writeFileSync(path.join(here, '../bmn-glass/bmn-glass-lite.css'), '/*! BMN Glass lite (Android, CSS only). Built from glass/src/lite.css. */\n' + lite.code);
console.log('built: bmn-glass-lite.css', (lite.code.length / 1024).toFixed(1), 'KiB');
