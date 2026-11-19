import { APIRequestContext, expect, test } from '@playwright/test';
import { apiAs, expectAccessible, signInAs } from './fixtures';

/** Synthetic legal entity in ORGTL (e2e/seed.sql). */
const ENTITY_A2 = '00000000-0000-0000-0000-00000000d103';

/** QRY-02 and VER-04 (Phase 5 LLD §17.4, §17.13): "Compare with a baseline". */
test.describe('Compare', () => {
  const baseline = `E2E baseline ${Date.now()}`;

  test.beforeAll(async () => {
    // a baseline, finalized by two version administrators (four eyes, ADR-037), so its picture is frozen
    const admin = await apiAs('e2e_vadmin');
    const today = (await (await admin.get('/api/v1/me')).json()).businessToday as string;
    const created = await admin.post('/api/v1/versions', { data: { name: baseline, businessAsOf: today, versionType: 'baseline' } });
    expect(created.status()).toBe(201);
    await move(admin, baseline, 'submitted');
    const admin2 = await apiAs('e2e_vadmin2');
    await move(admin2, baseline, 'finalized');

    // then a change in ORGTL: a rename, requested and approved by the demo users
    const editor = await apiAs('u_editor1');
    const cr = await (await editor.post('/api/v1/change-requests', { data: { versionName: 'E2E working', title: 'E2E compare rename' } })).json();
    const etag = async (api: APIRequestContext) => (await api.get(`/api/v1/change-requests/${cr.id}`)).headers()['etag'];
    expect((await editor.post(`/api/v1/change-requests/${cr.id}/items`, { headers: { 'If-Match': await etag(editor) },
      data: { action: 'update_node', hierarchyCode: 'ORGTL', nodeId: ENTITY_A2, payload: { name: 'Demo Legal Entity A2 renamed' } } })).status()).toBe(201);
    expect((await editor.post(`/api/v1/change-requests/${cr.id}/submit`, { headers: { 'If-Match': await etag(editor) } })).status()).toBe(200);
    const approver = await apiAs('u_approver1');
    const decided = await approver.post(`/api/v1/change-requests/${cr.id}/decision`,
      { headers: { 'If-Match': await etag(approver) }, data: { decision: 'approve' } });
    expect((await decided.json()).status).toBe('applied');
    for (const a of [admin, admin2, editor, approver]) await a.dispose();
  });

  test('Compare with baseline shows the rename made after the baseline was frozen', async ({ page }) => {
    await signInAs(page, 'u_viewer');
    await page.goto('/versions');
    await page.getByTestId('compare-baseline').click();
    await expect(page).toHaveURL(/\/compare\?.*lv=/);
    const left = page.locator('[data-side=left]');
    const right = page.locator('[data-side=right]');
    await expect(left.getByLabel('Version')).toHaveValue(baseline);
    await expect(right.getByLabel('Version')).toHaveValue('E2E working');
    await left.getByLabel('Hierarchy').selectOption('ORGTL');
    await right.getByLabel('Hierarchy').selectOption('ORGTL');
    await page.getByTestId('compare-run').click();

    await expect(page).toHaveURL(/run=/);
    await page.getByRole('tab', { name: /^Names \(1\)/ }).click();
    const row = page.getByTestId('compare-table').locator('tbody tr').filter({ hasText: 'Demo Legal Entity A2' });
    await expect(row).toContainText('Renamed');
    await expect(row.locator('.side--left')).toContainText('Demo Legal Entity A2');
    await expect(row.locator('.side--right')).toContainText('Demo Legal Entity A2 renamed');
    await expectAccessible(page);
  });
});

async function move(api: APIRequestContext, name: string, to: string): Promise<void> {
  const etag = (await api.get(`/api/v1/versions/${encodeURIComponent(name)}`)).headers()['etag'];
  const r = await api.post(`/api/v1/versions/${encodeURIComponent(name)}/transitions`, { headers: { 'If-Match': etag }, data: { to } });
  expect(r.status(), await r.text()).toBe(200);
}
