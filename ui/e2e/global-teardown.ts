import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, rmSync } from 'node:fs';
import { STATE } from './global-setup';

/** Stops the API started by global-setup. The database stays until the next run drops it (it holds synthetic data only). */
export default async function globalTeardown(): Promise<void> {
  if (!existsSync(STATE)) return;
  const { apiPid } = JSON.parse(readFileSync(STATE, 'utf8')) as { apiPid?: number };
  if (apiPid) {
    try {
      if (process.platform === 'win32') {
        execFileSync('taskkill', ['/pid', String(apiPid), '/T', '/F'], { stdio: 'ignore' });
      } else {
        process.kill(-apiPid);
      }
    } catch {
      /* already stopped */
    }
  }
  rmSync(STATE, { force: true });
}
