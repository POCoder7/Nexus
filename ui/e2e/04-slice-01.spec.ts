import { Page, expect, test } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import { APPROVER, COMMITTER, HIERARCHY, STEWARD, apiAs, businessToday, dayBefore, expectAccessible, openNodeBySearch, signInAs } from './fixtures';

/**
 * SLICE-01 end to end on synthetic data (S1-R4 … S1-R7; Phase 3 LLD §6.1, §13): a steward adds a leaf with its required
 * property and submits; it reaches the approver's and then the committer's worklist; the requester cannot decide it;
 * the shadow policy evaluation shows on the timeline; after commit the leaf exists today and not the day before, and
 * the audit log has the rows. The steps share one request, so they run in order.
 */
test.describe.configure({ mode: 'serial' });

const LEAF = `E2E New Leaf ${Date.now().toString(36)}`;
let requestId = '';

async function openNorth(page: Page) {
  await page.goto(`/hierarchies/${HIERARCHY}`);
  await openNodeBySearch(page, 'E2E Region North');
}

function psql(sql: string): string {
  return execFileSync('docker', ['compose', 'exec', '-T', 'db', 'psql', '-At', '-U', 'nexus', '-d', 'nexus_e2e', '-c', sql],
    { cwd: '..', encoding: 'utf8' }).trim();
}

test('S1-R4: a missing required property blocks "Add to request" at the field', async ({ page }) => {
  await signInAs(page, STEWARD);
  await openNorth(page);
  await page.getByRole('button', { name: 'Add child' }).click();
  const dialog = page.getByRole('dialog', { name: 'Add a child under E2E Region North' });
  await dialog.getByLabel('Name').fill(LEAF);
  await dialog.getByRole('button', { name: 'Add to request' }).click();
  await expect(dialog.getByTestId('add-leaf-summary')).toContainText('Cost centre: Required');
  await expect(dialog.getByLabel('Cost centre')).toHaveAttribute('aria-invalid', 'true');
  await expectAccessible(page);
  // the summary links to the field
  await dialog.getByRole('link', { name: 'Cost centre: Required' }).click();
  await expect(dialog.getByLabel('Cost centre')).toBeFocused();
  await dialog.getByRole('button', { name: 'Cancel' }).click();
  await expect(dialog).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Add child' })).toBeFocused();   // focus returns to the trigger
});

test('S1-R4: the steward adds the leaf to a draft and submits it after validation', async ({ page }) => {
  await signInAs(page, STEWARD);
  await openNorth(page);
  await page.getByRole('button', { name: 'Add child' }).click();
  const dialog = page.getByRole('dialog');
  await dialog.getByLabel('Name').fill(LEAF);
  await dialog.getByLabel('Description').fill('Synthetic leaf added by the end-to-end suite');
  await dialog.getByLabel('Cost centre').fill('CC-E2E-01');
  await dialog.getByRole('button', { name: 'Add to request' }).click();
  await expect(dialog).toHaveCount(0);
  await expect(page.getByRole('status').filter({ hasText: 'Added to your draft request' })).toBeVisible();
  const tray = page.getByRole('complementary', { name: 'Your draft request' });
  await expect(tray).toContainText('Nothing changes until governance approves.');
  await expect(tray.getByTestId('tray-count')).toHaveText('2 changes');   // add_node + set_property

  await tray.getByRole('button', { name: 'Review and submit' }).click();
  await expect(page.getByRole('heading', { name: 'Review and submit' })).toBeVisible();
  await expect(page.getByTestId('item-list')).toContainText(`Add ${LEAF} (leaf)`);
  await expect(page.getByTestId('item-list')).toContainText('CC-E2E-01');
  await expect(page.getByTestId('validation-ok')).toBeVisible();
  await expectAccessible(page);
  requestId = page.url().split('/requests/')[1].split('/')[0];
  await page.getByRole('button', { name: 'Submit request' }).click();
  await expect(page).toHaveURL(new RegExp(`/requests/${requestId}$`));
  await expect(page.getByTestId('request-status')).toContainText(/Submitted|In review/);
  await expect(page.getByTestId('workflow-timeline')).toContainText('2. Approve');
  await expect(page.getByTestId('workflow-timeline').locator('[data-stage-type=approve]')).toContainText('In progress', { timeout: 20_000 });
  // the requester cannot approve their own request: the reason is the server's sentence
  await page.reload();
  await expect(page.getByTestId('decision-reason')).toContainText('You requested or submitted this change');
  await expect(page.getByRole('button', { name: 'Approve' })).toHaveCount(0);
});

test('S1-R5: the request is in the approver\'s Assigned view and the approver approves', async ({ page }) => {
  await signInAs(page, APPROVER);
  await page.goto('/worklist?view=assigned');
  const row = page.locator(`[data-request-id="${requestId}"]`);
  await expect(row).toContainText(`Add ${LEAF} under E2E Region North`);
  await expect(row).toContainText('Approve');
  await expectAccessible(page);
  await row.getByRole('link').click();
  await expect(page).toHaveURL(new RegExp(`/requests/${requestId}$`));
  await page.getByRole('button', { name: 'Approve' }).click();
  await expect(page.getByTestId('workflow-timeline').locator('[data-stage-type=commit]')).toContainText('In progress', { timeout: 20_000 });
  // S1-R6: the shadow policy was evaluated before Commit and says it had no effect
  await expect(page.getByTestId('policy-evaluations')).toContainText(/E2E_SHADOW: would (commit|route to a person) \(shadow mode, no effect\)/);
  // separation of duties: the approver cannot also commit
  await expect(page.getByTestId('decision-reason')).toBeVisible();
});

test('S1-R5: the steward without commit rights sees why they cannot commit', async ({ page }) => {
  await signInAs(page, STEWARD);
  await page.goto(`/requests/${requestId}`);
  await expect(page.getByTestId('decision-reason')).toContainText('You requested or submitted this change, so you cannot approve or commit it.');
  await expect(page.getByRole('button', { name: 'Commit' })).toHaveCount(0);
});

test('S1-R5: the committer commits from the worklist and the change is applied', async ({ page }) => {
  await signInAs(page, COMMITTER);
  await page.goto('/worklist');
  await page.locator(`[data-request-id="${requestId}"]`).getByRole('link').click();
  await page.getByRole('button', { name: 'Commit' }).click();
  await expect(page.getByTestId('request-status')).toContainText('Applied', { timeout: 25_000 });
  await expectAccessible(page);
});

test('S1-R7: the leaf is in the hierarchy today and absent the day before; audit rows exist', async ({ page }) => {
  await signInAs(page, STEWARD);
  const today = await businessToday();
  await page.goto(`/hierarchies/${HIERARCHY}`);
  await openNodeBySearch(page, LEAF);
  await expect(page.getByRole('grid').locator('[data-property="E2E.CostCentre"]')).toContainText('CC-E2E-01');
  await expect(page.getByRole('grid').locator('[data-property="E2E.CostCentre"] [data-testid=provenance]')).toContainText('Stored here');

  // acceptance criterion 3: as of the day before, the parent is there without the new leaf
  await page.goto(`/hierarchies/${HIERARCHY}?asOf=${dayBefore(today)}`);
  await page.getByRole('treeitem', { name: /E2E Region North/ }).locator('.twisty').click();
  await expect(page.getByRole('treeitem', { name: /E2E North Leaf One/ })).toBeVisible();
  await expect(page.getByRole('treeitem', { name: new RegExp(LEAF) })).toHaveCount(0);
  await page.getByLabel('Search in this hierarchy').fill(LEAF);
  await expect(page.getByTestId('search-message')).toHaveText('No nodes match.');

  // audit and request state (API and database checks; history views wait for QRY-04)
  const api = await apiAs(STEWARD);
  const cr = await (await api.get(`/api/v1/change-requests/${requestId}`)).json();
  expect(cr.status).toBe('applied');
  expect(cr.decisionBasis).toBe('human_review');
  await api.dispose();
  expect(Number(psql(`SELECT count(*) FROM mdm.audit_log WHERE change_request_id = '${requestId}'`))).toBeGreaterThan(0);
});

test('S1-R4: a duplicate name is reported at the item and blocks submission', async ({ page }) => {
  await signInAs(page, STEWARD);
  await openNorth(page);
  await page.getByRole('button', { name: 'Add child' }).click();
  const dialog = page.getByRole('dialog');
  await dialog.getByLabel('Name').fill('E2E North Leaf One');   // already exists
  await dialog.getByLabel('Cost centre').fill('CC-E2E-02');
  await dialog.getByRole('button', { name: 'Add to request' }).click();
  await expect(dialog).toHaveCount(0);
  await page.getByRole('complementary', { name: 'Your draft request' }).getByRole('button', { name: 'Review and submit' }).click();
  await expect(page.getByTestId('validation-errors')).toBeVisible();
  await expect(page.getByTestId('item-list').locator('.finding').first()).toBeVisible();
  await expect(page.getByRole('button', { name: 'Submit request' })).toBeDisabled();
});
