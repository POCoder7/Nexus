import { execFileSync, spawn } from 'node:child_process';
import { existsSync, openSync, readdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

/**
 * Throw-away environment for the end-to-end journeys (synthetic data only):
 *  1. the docker-compose PostgreSQL, with a fresh database `nexus_e2e`;
 *  2. the API (profile `local`, port 8180) with the in-process workflow worker in the same JVM; Flyway migrates the
 *     database on start-up. Locally the API uses the docker-compose owner account (DEVELOPER_SETUP; least privilege is
 *     proven by the JUnit suite as `nexus_api_test`);
 *  3. the synthetic seed `e2e/seed.sql`, run as the owner on the new database.
 * Set E2E_SKIP_BUILD=1 to reuse services/mdm-api/target/*.jar.
 */
export const REPO = resolve(__dirname, '..', '..');
export const STATE = join(__dirname, '.state.json');
const API_DIR = join(REPO, 'services', 'mdm-api');
const DB = 'nexus_e2e';

function sh(cmd: string, args: string[], cwd = REPO): string {
  // only Windows .cmd scripts need a shell; docker is called directly so its arguments are never re-parsed
  return execFileSync(cmd, args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], shell: cmd.endsWith('.cmd') });
}

export function psql(sql: string): string {
  return sh('docker', ['compose', 'exec', '-T', 'db', 'psql', '-At', '-U', 'nexus', '-d', DB, '-c', sql]).trim();
}

async function waitFor(url: string, ms: number): Promise<void> {
  const until = Date.now() + ms;
  while (Date.now() < until) {
    try {
      const r = await fetch(url);
      if (r.ok) return;
    } catch {
      /* not up yet */
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error(`Timed out waiting for ${url}`);
}

export default async function globalSetup(): Promise<void> {
  sh('docker', ['compose', 'up', '-d', '--build', 'db']);
  for (let i = 0; i < 60; i++) {
    try {
      sh('docker', ['compose', 'exec', '-T', 'db', 'pg_isready', '-U', 'nexus', '-d', 'postgres']);
      break;
    } catch {
      await new Promise((r) => setTimeout(r, 1000));
    }
  }
  sh('docker', ['compose', 'exec', '-T', 'db', 'psql', '-U', 'nexus', '-d', 'postgres', '-c', `DROP DATABASE IF EXISTS ${DB} WITH (FORCE)`]);
  sh('docker', ['compose', 'exec', '-T', 'db', 'psql', '-U', 'nexus', '-d', 'postgres', '-c', `CREATE DATABASE ${DB}`]);

  if (!process.env.E2E_SKIP_BUILD) {
    sh(process.platform === 'win32' ? join(API_DIR, 'mvnw.cmd') : './mvnw', ['-B', '-q', '-DskipTests', 'package'], API_DIR);
  }
  const jar = readdirSync(join(API_DIR, 'target')).find((f) => /^mdm-api-.*\.jar$/.test(f));
  if (!jar) throw new Error('API jar not found: build services/mdm-api first');
  const java = process.env.JAVA_HOME ? join(process.env.JAVA_HOME, 'bin', 'java') : 'java';
  const log = openSync(join(__dirname, 'api.log'), 'w');
  // UTC JVM: recorded time is UTC everywhere (ADR-018), and the JDBC driver would otherwise send the machine's zone
  // (e.g. the legacy alias "Asia/Calcutta", which PostgreSQL refuses) on Flyway's first connection.
  const api = spawn(java, ['-Duser.timezone=UTC', '-jar', join(API_DIR, 'target', jar),
    '--spring.profiles.active=local', '--server.port=8180',
    `--spring.datasource.url=jdbc:postgresql://localhost:5432/${DB}`,
    '--mdm.workflow.worker.enabled=true'], { cwd: API_DIR, detached: true, stdio: ['ignore', log, log] });
  api.unref();
  writeFileSync(STATE, JSON.stringify({ apiPid: api.pid }));
  await waitFor('http://localhost:8180/actuator/health', 120_000);

  if (!existsSync(join(__dirname, 'seed.sql'))) throw new Error('e2e/seed.sql missing');
  sh('docker', ['compose', 'exec', '-T', 'db', 'psql', '-q', '-v', 'ON_ERROR_STOP=1', '-U', 'nexus', '-d', DB, '-f', '/workspace/ui/e2e/seed.sql']);
}
