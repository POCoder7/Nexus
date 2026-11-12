// Serves the built Storybook (storybook-static/) on a local port and runs the Storybook test runner (with axe) against
// it, then stops. No extra server dependency: Node's http module serves the static files.
import { spawn } from 'node:child_process';
import { createReadStream, existsSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { extname, join, normalize } from 'node:path';

const root = 'storybook-static';
const port = Number(process.env.STORYBOOK_TEST_PORT || 6106);
if (!existsSync(join(root, 'index.html'))) {
  console.error('storybook-static/ is missing: run npm run build-storybook first.');
  process.exit(1);
}
const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.woff2': 'font/woff2', '.ico': 'image/x-icon' };

const server = createServer((req, res) => {
  const path = normalize(decodeURIComponent((req.url || '/').split('?')[0])).replace(/^([/\\])+/, '');
  let file = join(root, path || 'index.html');
  if (!file.startsWith(root) || !existsSync(file) || statSync(file).isDirectory()) {
    file = existsSync(join(file, 'index.html')) ? join(file, 'index.html') : join(root, 'index.html');
  }
  res.setHeader('Content-Type', types[extname(file)] || 'application/octet-stream');
  createReadStream(file).pipe(res);
});

server.listen(port, '127.0.0.1', () => {
  const runner = spawn(process.execPath, ['node_modules/@storybook/test-runner/dist/test-storybook.js', '--url', `http://127.0.0.1:${port}`,
    '--maxWorkers=2'], { stdio: 'inherit' });
  runner.on('exit', (code) => {
    server.close();
    process.exit(code ?? 1);
  });
});
