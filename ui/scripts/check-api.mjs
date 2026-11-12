// Contract drift check (P-27): regenerates the client from docs/api/openapi.json into a temporary folder and fails if it
// differs from the committed src/app/api/generated. Fix with `npm run api:generate` and commit the result.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, relative } from 'node:path';

const committed = 'src/app/api/generated';
const temp = mkdtempSync(join(tmpdir(), 'nexus-api-'));

function files(dir) {
  return readdirSync(dir).flatMap((n) => (statSync(join(dir, n)).isDirectory() ? files(join(dir, n)) : [join(dir, n)]));
}

try {
  execFileSync(process.execPath, ['node_modules/ng-openapi-gen/lib/index.js', '--config', 'ng-openapi-gen.json', '--output', temp],
    { stdio: 'ignore' });
  const a = new Map(files(committed).map((f) => [relative(committed, f), readFileSync(f, 'utf8').replace(/\r\n/g, '\n')]));
  const b = new Map(files(temp).map((f) => [relative(temp, f), readFileSync(f, 'utf8').replace(/\r\n/g, '\n')]));
  const diff = [...new Set([...a.keys(), ...b.keys()])].filter((k) => a.get(k) !== b.get(k));
  if (diff.length) {
    console.error(`Generated client is out of date (${diff.length} files): ${diff.slice(0, 10).join(', ')}\nRun npm run api:generate.`);
    process.exit(1);
  }
  console.log(`Generated client matches docs/api/openapi.json (${a.size} files).`);
} finally {
  rmSync(temp, { recursive: true, force: true });
}
