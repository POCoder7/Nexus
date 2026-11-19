import { expect, test } from '@playwright/test';
import { apiAs, expectAccessible, signInAs } from './fixtures';

/** Synthetic legal entity in ORGTL (e2e/seed.sql). */
const ENTITY_A1 = '00000000-0000-0000-0000-00000000d102';

/** AUD-01 and AUD-02 (Phase 5 LLD §18.7, §18.8): a change shows in the transaction history and in its request's history. */
test.describe('Audit', () => {
  let requestId = '';

  test.beforeAll(async () => {
    const editor = await apiAs('u_editor1');
    const created = await (await editor.post('/api/v1/change-requests', { data: { versionName: 'E2E working', title: 'E2E audit journey' } })).json();
    requestId = created.id;
    const etag = async () => (await editor.get(`/api/v1/change-requests/${requestId}`)).headers()['etag'];
    expect((await editor.post(`/api/v1/change-requests/${requestId}/items`, {
      headers: { 'If-Match': await etag() },
      data: { action: 'set_property', hierarchyCode: 'ORGTL', nodeId: ENTITY_A1, propertyCode: 'E2E.CostCentre', payload: { value: 'CC-AUDIT-1' } },
    })).status()).toBe(201);
    expect((await editor.post(`/api/v1/change-requests/${requestId}/submit`, { headers: { 'If-Match': await etag() } })).status()).toBe(200);
    const approver = await apiAs('u_approver1');
    const decided = await approver.post(`/api/v1/change-requests/${requestId}/decision`, {
      headers: { 'If-Match': (await approver.get(`/api/v1/change-requests/${requestId}`)).headers()['etag'] },
      data: { decision: 'approve', note: 'Synthetic audit check' },
    });
    expect((await decided.json()).status).toBe('applied');
    await editor.dispose();
    await approver.dispose();
  });

  test('the Audit page shows the change in words, with who requested and approved it', async ({ page }) => {
    await signInAs(page, 'u_viewer');
    await page.goto('/audit');
    await page.getByLabel('Property (code)').fill('E2E.CostCentre');
    await page.getByLabel('Hierarchy (code)').fill('ORGTL');
    await page.getByTestId('audit-search').click();
    await expect(page).toHaveURL(/property=E2E.CostCentre/);
    const row = page.getByTestId('audit-table').locator('tbody tr').filter({ hasText: 'E2E audit journey' });
    await expect(row).toContainText('Cost centre');
    await expect(row.getByTestId('audit-change')).toContainText('CC-AUDIT-1');
    await expect(row).toContainText('Demo Editor One');
    await expect(row).toContainText('Demo Approver One');
    await expectAccessible(page);

    await row.getByRole('link', { name: 'E2E audit journey' }).click();
    const history = page.getByTestId('request-history');
    await expect(history).toContainText('Request created: E2E audit journey');
    await expect(history).toContainText('Change 1 added: Set E2E.CostCentre');
    await expect(history).toContainText('Approved');
    await expect(history).toContainText('Synthetic audit check');
    await expect(history).toContainText('Applied');
  });

  test('a user who cannot read the hierarchy does not see the change', async ({ page }) => {
    await signInAs(page, 'u_editor2');   // AMBUS only
    await page.goto('/audit?property=E2E.CostCentre');
    await expect(page.getByTestId('audit-empty')).toBeVisible();
  });
});
