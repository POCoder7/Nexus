// Production build checks (Phase 3 LLD §9, §10):
//  1. the development identity never reaches a production bundle (header name, picker selector, synthetic logins);
//  2. performance budgets as the LLD defines them, on COMPRESSED (gzip) size, which Angular's own budgets cannot measure:
//     UI_INITIAL_JS_KB 350 for the initial JavaScript, UI_ROUTE_JS_KB 150 for each lazy chunk (values to confirm, OD-10).
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { gzipSync } from 'node:zlib';

const dist = 'dist/nexus-ui/browser';
const UI_INITIAL_JS_KB = 350;
const UI_ROUTE_JS_KB = 150;
const forbidden = ['X-Nexus-User', 'nx-dev-user-picker', 'nexus.dev.user', 'e2e_steward'];
const failures = [];

const all = [];
(function walk(dir) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) walk(path);
    else all.push({ name, path });
  }
})(dist);

for (const f of all.filter((f) => /\.(js|html|css)$/.test(f.name))) {
  const text = readFileSync(f.path, 'utf8');
  for (const marker of forbidden) {
    if (text.includes(marker)) failures.push(`development identity in ${f.path}: ${marker}`);
  }
}

// initial = scripts referenced by index.html (entry and module preloads); everything else is lazy
const index = readFileSync(join(dist, 'index.html'), 'utf8');
const initial = new Set([...index.matchAll(/(?:src|href)="([^"]+\.js)"/g)].map((m) => m[1]));
const kb = (path) => gzipSync(readFileSync(path)).length / 1024;
let initialKb = 0;
for (const f of all.filter((f) => f.name.endsWith('.js'))) {
  const size = kb(f.path);
  if (initial.has(f.name)) {
    initialKb += size;
  } else if (size > UI_ROUTE_JS_KB) {
    failures.push(`lazy chunk ${f.name} is ${size.toFixed(1)} kB compressed (budget ${UI_ROUTE_JS_KB} kB)`);
  }
}
if (initialKb > UI_INITIAL_JS_KB) {
  failures.push(`initial JavaScript is ${initialKb.toFixed(1)} kB compressed (budget ${UI_INITIAL_JS_KB} kB)`);
}

if (failures.length) {
  console.error('Production build check failed:\n' + failures.join('\n'));
  process.exit(1);
}
console.log(`Production build check passed: initial JS ${initialKb.toFixed(1)} kB compressed (budget ${UI_INITIAL_JS_KB}), ` +
  `every lazy chunk under ${UI_ROUTE_JS_KB} kB, no development identity (${forbidden.length} markers).`);
