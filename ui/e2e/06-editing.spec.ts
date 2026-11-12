import { Page, expect, test } from '@playwright/test';
import { APPROVER, COMMITTER, HIERARCHY, expectAccessible, openNodeBySearch, signInAs } from './fixtures';

/**
 * Phase 3 scope extension: every other steward change through the tray (HIE-01, HIE-02, PRP-01). One draft request holds a
 * property value, a details edit, a move and a new hierarchy; it goes through Approve and Commit like any request, and
 * afterwards the hierarchy shows every change. A remove is previewed and cancelled. Synthetic data only.
 */
test.describe.configure({ mode: 'serial' });

const ARCHITECT = 'e2e_architect';
const NEW_CODE = `E2E_NEW_${Date.now().toString(36).toUpperCase()}`;
let requestId = '';

async function addedToDraft(page: Page, changes: string) {
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await expect(page.getByRole('complementary', { name: 'Your draft request' }).getByTestId('tray-count')).toHaveText(changes);
}

test('a property value is edited from the property grid', async ({ page }) => {
  await signInAs(page, ARCHITECT);
  await page.goto(`/hierarchies/${HIERARCHY}`);
  await openNodeBySearch(page, 'E2E North Leaf Two');
  await page.getByRole('button', { name: 'Edit Segment' }).click();
  const dialog = page.getByRole('dialog', { name: 'Segment on E2E North Leaf Two' });
  await expect(dialog).toContainText('default');
  await dialog.getByLabel('New value').fill('Synthetic retail');
  await expectAccessible(page);
  await dialog.getByRole('button', { name: 'Add to request' }).click();
  await addedToDraft(page, '1 change');
});

test('details are edited and the node is moved with the target picker', async ({ page }) => {
  await signInAs(page, ARCHITECT);
  await page.goto(`/hierarchies/${HIERARCHY}`);
  await openNodeBySearch(page, 'E2E North Leaf Two');
  await page.getByRole('button', { name: 'Edit details' }).click();
  let dialog = page.getByRole('dialog');
  await dialog.getByLabel('Description').fill('Synthetic description, edited');
  await dialog.getByRole('button', { name: 'Add to request' }).click();
  await addedToDraft(page, '2 changes');

  await page.getByRole('button', { name: 'Move to…' }).click();
  dialog = page.getByRole('dialog', { name: 'Move E2E North Leaf Two' });
  await expect(dialog.getByTestId('impact')).toContainText('0 nodes below it');
  await dialog.getByLabel('New parent').fill('Region South');
  await dialog.getByRole('option', { name: /E2E Region South/ }).click();
  await expect(dialog).toContainText('Chosen: E2E Region South');
  await dialog.getByRole('button', { name: 'Add to request' }).click();
  await addedToDraft(page, '3 changes');
});

test('a node is placed under a second parent (shared placement)', async ({ page }) => {
  await signInAs(page, ARCHITECT);
  await page.goto(`/hierarchies/${HIERARCHY}`);
  await openNodeBySearch(page, 'E2E North Leaf One');
  await page.getByRole('button', { name: 'Place under another parent' }).click();
  const dialog = page.getByRole('dialog', { name: 'Place E2E North Leaf One under another parent' });
  await dialog.getByLabel('New parent').fill('Region South');
  await dialog.getByRole('option', { name: /E2E Region South/ }).click();
  await dialog.getByRole('button', { name: 'Add to request' }).click();
  await addedToDraft(page, '4 changes');
});

test('a delete shows its impact and needs confirmation; cancelling adds nothing', async ({ page }) => {
  await signInAs(page, ARCHITECT);
  await page.goto(`/hierarchies/${HIERARCHY}`);
  await openNodeBySearch(page, 'E2E Deep Target');
  await page.getByRole('button', { name: 'Delete node' }).click();
  const dialog = page.getByRole('dialog', { name: 'Delete E2E Deep Target' });
  await expect(dialog.getByTestId('impact')).toContainText('0 nodes below it');
  await dialog.getByRole('button', { name: 'Add to request' }).click();
  await expect(dialog.getByTestId('change-error')).toContainText('Confirm to continue.');
  await expect(dialog.getByLabel(/I understand this deletes E2E Deep Target everywhere/)).toBeVisible();
  await dialog.getByRole('button', { name: 'Cancel' }).click();
  await addedToDraft(page, '4 changes');
});

test('a remove shows its impact in numbers and needs confirmation', async ({ page }) => {
  await signInAs(page, ARCHITECT);
  await page.goto(`/hierarchies/${HIERARCHY}`);
  await openNodeBySearch(page, 'E2E Bulk Parent');
  await page.getByRole('button', { name: 'Remove from hierarchy' }).click();
  const dialog = page.getByRole('dialog', { name: 'Remove E2E Bulk Parent from the hierarchy' });
  await expect(dialog.getByTestId('impact')).toContainText('450 nodes below it');
  await dialog.getByRole('button', { name: 'Add to request' }).click();
  await expect(dialog.getByTestId('change-error')).toContainText('Confirm to continue.');
  await expect(dialog.getByLabel(/I understand this removes E2E Bulk Parent and 450 nodes below it/)).toBeVisible();
  await expectAccessible(page);
  await dialog.getByRole('button', { name: 'Cancel' }).click();
  await addedToDraft(page, '4 changes');   // nothing added
});

test('a new hierarchy joins the draft from Home, and the request is submitted', async ({ page }) => {
  await signInAs(page, ARCHITECT);
  await page.goto('/home');
  await page.getByRole('button', { name: 'New hierarchy' }).click();
  const dialog = page.getByRole('dialog', { name: 'Create a hierarchy' });
  await dialog.getByLabel('Code').fill(NEW_CODE);
  await dialog.getByRole('textbox', { name: /^Name/ }).fill('E2E New Hierarchy');   // accessible name is "Name (Required)"
  await dialog.getByLabel('Top node name').fill(`E2E New Top ${NEW_CODE.slice(-6)}`);
  await dialog.getByRole('button', { name: 'Add to request' }).click();
  await addedToDraft(page, '5 changes');

  await page.getByRole('button', { name: 'Review and submit' }).click();
  await expect(page.getByTestId('item-list')).toContainText('Set E2E.Segment');
  await expect(page.getByTestId('item-list')).toContainText('Edit details');
  await expect(page.getByTestId('item-list')).toContainText('Move');
  await expect(page.getByTestId('item-list')).toContainText(`Create hierarchy ${NEW_CODE}`);
  await expect(page.getByTestId('validation-ok')).toBeVisible();
  requestId = page.url().split('/requests/')[1].split('/')[0];
  await page.getByRole('button', { name: 'Submit request' }).click();
  await expect(page.getByTestId('workflow-timeline').locator('[data-stage-type=approve]')).toContainText('In progress', { timeout: 20_000 });
});

test('the request is approved and committed, and every change is in the data', async ({ page }) => {
  await signInAs(page, APPROVER);
  await page.goto(`/requests/${requestId}`);
  await page.getByRole('button', { name: 'Approve' }).click();
  await expect(page.getByTestId('workflow-timeline').locator('[data-stage-type=commit]')).toContainText('In progress', { timeout: 20_000 });

  await signInAs(page, COMMITTER);
  await page.goto(`/requests/${requestId}`);
  await page.getByRole('button', { name: 'Commit' }).click();
  await expect(page.getByTestId('request-status')).toContainText('Applied', { timeout: 25_000 });

  await signInAs(page, ARCHITECT);
  await page.goto(`/hierarchies/${HIERARCHY}`);
  await openNodeBySearch(page, 'E2E North Leaf Two');
  await expect(page.locator('[data-property="E2E.Segment"]')).toContainText('Synthetic retail');
  await expect(page.locator('[data-property="E2E.Segment"] [data-testid=provenance]')).toContainText('Stored here');
  await expect(page.getByText('Synthetic description, edited')).toBeVisible();
  await page.getByRole('tab', { name: 'Relationships' }).click();
  await expect(page.getByTestId('node-path')).toContainText('E2E Region South');
  // the shared placement: North Leaf One now also appears under South, marked "Shared"
  await page.goto(`/hierarchies/${HIERARCHY}`);
  await page.getByRole('treeitem', { name: /^E2E Region South/ }).locator('.twisty').click();
  await expect(page.getByRole('treeitem', { name: /E2E North Leaf One.*Shared/ })).toBeVisible();
  await page.goto('/home');
  await expect(page.getByTestId('home-hierarchies')).toContainText('E2E New Hierarchy');
});
