import { defineConfig, devices } from '@playwright/test';

/**
 * End-to-end journeys (ADR-025; Phase 3 LLD §13): SLICE-01 S1-R2 … S1-R7, NEW-10, GOV-13, accessibility on every page.
 *
 * global-setup builds a throw-away database `nexus_e2e` (all migrations via the API's Flyway, then the synthetic seed
 * e2e/seed.sql), starts the API with the in-process workflow worker on port 8180, and the dev server here proxies /api
 * to it. Synthetic data only. Tests share one database, so they run in one worker, in file order.
 * Performance traces (tag @perf) are written but excluded: performance testing is deferred to the end of the build.
 */
export const API_URL = 'http://localhost:8180';
const UI_PORT = 4300;

export default defineConfig({
  testDir: './e2e',
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 60_000,
  expect: { timeout: 10_000 },
  grepInvert: process.env.E2E_PERF ? undefined : /@perf/,
  reporter: [['list'], ['html', { open: 'never', outputFolder: 'e2e-report' }]],
  globalSetup: './e2e/global-setup.ts',
  globalTeardown: './e2e/global-teardown.ts',
  use: {
    baseURL: `http://localhost:${UI_PORT}`,
    trace: 'retain-on-failure',
    timezoneId: 'Asia/Kolkata',   // deliberately not the business zone: "today" must come from the server (ADR-018)
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'], viewport: { width: 1440, height: 900 } } },
    ...(process.env.E2E_EDGE ? [{ name: 'edge', use: { ...devices['Desktop Edge'], channel: 'msedge', viewport: { width: 1440, height: 900 } } }] : []),
  ],
  webServer: {
    command: `npx ng serve --port ${UI_PORT}`,
    url: `http://localhost:${UI_PORT}`,
    reuseExistingServer: !process.env.CI,
    timeout: 180_000,
    // no interactive analytics prompt, no usage data sent anywhere (also "cli.analytics": false in angular.json)
    env: { NEXUS_API_URL: API_URL, NG_CLI_ANALYTICS: 'false' },
  },
});
