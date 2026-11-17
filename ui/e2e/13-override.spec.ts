import { expect, test } from '@playwright/test';
import { STEWARD, apiAs, expectAccessible, signInAs } from './fixtures';

/** Synthetic ADMIN from e2e/seed.sql (group ADMIN_ALL); in none of the workflow's stage groups. */
const ADMIN = 'e2e_admin2';
const LEAF_TWO = '00000000-0000-0000-0000-00000000a012';

/** ADR-042 D4 workflow override (Phase 5 LLD §19.5, §19.7): an ADMIN decides a stage in place of its approvers. */
test.describe('Workflow override', () => {
  test('an ADMIN overrides the Approve stage with a reason, and the timeline says so', async ({ page }) => {
    const api = await apiAs(STEWARD);
    const created = await (await api.post('/api/v1/change-requests', {
      data: { versionName: 'E2E working', title: 'E2E override journey', workflowModelCode: 'MAINTAIN' },
    })).json();
    const etag = async () => (await api.get(`/api/v1/change-requests/${created.id}`)).headers()['etag'];
    expect((await api.post(`/api/v1/change-requests/${created.id}/items`, {
      headers: { 'If-Match': await etag() },
      data: { action: 'update_node', hierarchyCode: 'E2E_H', nodeId: LEAF_TWO, payload: { description: 'Changed by an override journey' } },
    })).status()).toBe(201);
    expect((await api.post(`/api/v1/change-requests/${created.id}/submit`, { headers: { 'If-Match': await etag() } })).status()).toBe(200);
    await api.dispose();

    // the requester is never offered the override
    await signInAs(page, STEWARD);
    await page.goto(`/requests/${created.id}`);
    await expect(page.getByTestId('decision-panel')).toBeVisible();
    await expect(page.getByTestId('override-offer')).toHaveCount(0);

    await signInAs(page, ADMIN);   // runs after the first init script, so the next load signs in as the ADMIN
    await page.goto(`/requests/${created.id}`);
    await expect(page.getByTestId('override-offer')).toBeVisible();
    await page.getByTestId('override-open').click();
    await expect(page.getByTestId('override-warning')).toContainText('logged on the request');
    await expectAccessible(page);

    await page.getByTestId('override-approve').click();   // no reason yet: refused in words, nothing sent
    await expect(page.getByText('Say why the stage is overridden, in at least 10 characters.')).toBeVisible();
    await page.getByTestId('override-reason').fill('Approvers are away for the quarter-end close');
    await page.getByTestId('override-approve').click();

    await expect(page.getByTestId('workflow-timeline').locator('[data-override=true]'))
      .toContainText('Approvers are away for the quarter-end close');
    await expect(page.getByTestId('workflow-timeline').locator('[data-override=true]')).toContainText('Overridden by');
  });
});
