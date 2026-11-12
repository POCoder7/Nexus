import AxeBuilder from '@axe-core/playwright';
import { APIRequestContext, Page, expect, request } from '@playwright/test';
import { API_URL } from '../playwright.config';

/** Synthetic users created by e2e/seed.sql. */
export const STEWARD = 'e2e_steward';
export const APPROVER = 'e2e_approver';
export const COMMITTER = 'e2e_committer';
export const VIEWER = 'e2e_viewer';
export const POLICY = 'e2e_policy';
export const HIERARCHY = 'E2E_H';

/** Signs the page in as a synthetic user through the dev user picker's storage (local/test builds only, LLD C-7). */
export async function signInAs(page: Page, login: string): Promise<void> {
  await page.addInitScript((l) => sessionStorage.setItem('nexus.dev.user', l), login);
}

/** Direct API client for assertions and setup the UI does not offer (as the dev identity header, like the UI). */
export async function apiAs(login: string): Promise<APIRequestContext> {
  return request.newContext({ baseURL: API_URL, extraHTTPHeaders: { 'X-Nexus-User': login } });
}

export async function businessToday(): Promise<string> {
  const api = await apiAs(VIEWER);
  const me = await (await api.get('/api/v1/me')).json();
  await api.dispose();
  return me.businessToday as string;
}

export function dayBefore(iso: string): string {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() - 1);
  return d.toISOString().slice(0, 10);
}

/** WCAG 2.1 AA checks with axe on the whole page (UI_STANDARD §8). */
export async function expectAccessible(page: Page): Promise<void> {
  const results = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const summary = results.violations.map((v) => `${v.id} (${v.impact}): ${v.nodes.map((n) => n.target.join(' ')).join(', ')}`);
  expect(summary, 'axe violations').toEqual([]);
}

/** Opens a node in the tree by revealing it through the in-tree search (works however deep or paged it is). */
export async function openNodeBySearch(page: Page, name: string): Promise<void> {
  await page.getByLabel('Search in this hierarchy').fill(name);
  await page.getByRole('option', { name: new RegExp(`^${escapeRegExp(name)}`) }).first().click();
  await expect(page.getByTestId('node-name')).toHaveText(name);
}

export function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
