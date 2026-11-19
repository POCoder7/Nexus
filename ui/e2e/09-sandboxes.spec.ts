import { Page, expect, test } from '@playwright/test';
import { APPROVER, COMMITTER, HIERARCHY, expectAccessible, openNodeBySearch, signInAs } from './fixtures';

/**
 * NEW-08 sandboxes (Phase 5 LLD §12, PLAN 5-3): a sandbox is created, three kinds of change are made in it, the tree
 * shows them marked while live data does not, the sandbox page lists them, and Submit as request sends it through
 * Approve and Commit like any request; afterwards the live data shows every change. A second sandbox is discarded.
 * Synthetic data only.
 */
test.describe.configure({ mode: 'serial' });

const ARCHITECT = 'e2e_architect';
const SUFFIX = Date.now().toString(36).toUpperCase().slice(-5);
const NAME = `E2E plan ${SUFFIX}`;
const RENAMED = `E2E Bulk Seven ${SUFFIX}`;
let sandboxId = '';
let requestId = '';

async function inTray(page: Page, changes: string) {
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await expect(page.getByRole('complementary', { name: `Sandbox ${NAME}` }).getByTestId('tray-count')).toHaveText(changes);
}

test('a sandbox is created and opens the workspace in sandbox mode', async ({ page }) => {
  await signInAs(page, ARCHITECT);
  await page.goto('/sandboxes');
  await expectAccessible(page);
  await page.getByTestId('sandbox-name').fill(NAME);
  await page.getByTestId('sandbox-create').click();
  await expect(page).toHaveURL(/\/hierarchies\/[^?]+\?.*sandbox=/);
  sandboxId = new URL(page.url()).searchParams.get('sandbox')!;
  await page.goto(`/hierarchies/${HIERARCHY}?sandbox=${sandboxId}`);
  await expect(page.getByTestId('sandbox-banner')).toContainText(NAME);
  await expect(page.getByTestId('sandbox-banner')).toContainText('Nothing here is live');
  await expect(page.getByTestId('sandbox-switcher')).toHaveValue(sandboxId);
  await expectAccessible(page);
});

test('three kinds of change become the sandbox\'s items', async ({ page }) => {
  await signInAs(page, ARCHITECT);
  await page.goto(`/hierarchies/${HIERARCHY}?sandbox=${sandboxId}`);

  await openNodeBySearch(page, 'E2E Bulk 0007');
  await page.getByRole('button', { name: 'Edit details' }).click();
  let dialog = page.getByRole('dialog');
  await dialog.getByRole('textbox', { name: /^Name/ }).fill(RENAMED);
  await dialog.getByRole('button', { name: 'Add to request' }).click();
  await inTray(page, '1 change');
  await expect(page.getByTestId('node-name')).toHaveText(RENAMED);
  await expect(page.getByTestId('node-changed')).toBeVisible();

  await openNodeBySearch(page, 'E2E Bulk 0009');
  await page.getByRole('button', { name: 'Edit Cost centre' }).click();
  dialog = page.getByRole('dialog', { name: 'Cost centre on E2E Bulk 0009' });
  await dialog.getByLabel('New value').fill('CC-SBX');
  await dialog.getByRole('button', { name: 'Add to request' }).click();
  await inTray(page, '2 changes');
  await expect(page.locator('[data-property="E2E.CostCentre"]')).toContainText('CC-SBX');
  await expect(page.locator('[data-property="E2E.CostCentre"] [data-testid=value-changed]')).toBeVisible();

  await openNodeBySearch(page, 'E2E Bulk 0008');
  await page.getByRole('button', { name: 'Move to…' }).click();
  dialog = page.getByRole('dialog', { name: 'Move E2E Bulk 0008' });
  await dialog.getByLabel('New parent').fill('Region North');
  await dialog.getByRole('option', { name: /E2E Region North/ }).click();
  await dialog.getByRole('button', { name: 'Add to request' }).click();
  await inTray(page, '3 changes');
});

test('the tree shows the changes in the sandbox, and live data does not', async ({ page }) => {
  await signInAs(page, ARCHITECT);
  await page.goto(`/hierarchies/${HIERARCHY}?sandbox=${sandboxId}`);
  await page.getByRole('treeitem', { name: /^E2E Region North/ }).locator('.twisty').click();
  await expect(page.getByRole('treeitem', { name: /E2E Bulk 0008.*Changed in sandbox/ })).toBeVisible();
  await expectAccessible(page);

  await page.getByTestId('sandbox-banner').getByRole('button', { name: 'Back to live data' }).click();
  await expect(page.getByTestId('sandbox-banner')).toHaveCount(0);
  await expect(page.getByTestId('sandbox-switcher')).toHaveValue('');
  await page.getByRole('treeitem', { name: /^E2E Region North/ }).locator('.twisty').click();
  await expect(page.getByRole('treeitem', { name: /E2E North Leaf One/ })).toBeVisible();
  await expect(page.getByRole('treeitem', { name: /E2E Bulk 0008/ })).toHaveCount(0);
  await expect(page.getByTestId('tree-changed')).toHaveCount(0);
});

test('the sandbox page lists the changes, and Submit as request sends it for review', async ({ page }) => {
  await signInAs(page, ARCHITECT);
  await page.goto(`/hierarchies/${HIERARCHY}?sandbox=${sandboxId}`);
  await page.getByRole('complementary', { name: `Sandbox ${NAME}` }).getByRole('button', { name: 'Open sandbox' }).click();
  await expect(page.getByTestId('sandbox-title')).toHaveText(`Sandbox ${NAME}`);
  await expect(page.getByTestId('sandbox-item-count')).toHaveText('3');
  await expect(page.getByTestId('item-list')).toContainText('Edit details');
  await expect(page.getByTestId('item-list')).toContainText('Set E2E.CostCentre');
  await expect(page.getByTestId('item-list')).toContainText('Move');
  await expect(page.getByTestId('no-conflicts')).toBeVisible();
  await expectAccessible(page);

  await page.getByTestId('sandbox-submit').click();
  await expect(page).toHaveURL(/\/requests\/[0-9a-f-]+$/);
  requestId = page.url().split('/requests/')[1];
  expect(requestId).toBe(sandboxId);   // the sandbox became this request
  await expect(page.getByTestId('workflow-timeline').locator('[data-stage-type=approve]')).toContainText('In progress', { timeout: 20_000 });
  await page.goto('/sandboxes');
  await expect(page.getByRole('link', { name: NAME })).toHaveCount(0);
});

test('the request is approved and committed, and the live data shows every change', async ({ page }) => {
  await signInAs(page, APPROVER);
  await page.goto(`/requests/${requestId}`);
  await page.getByRole('button', { name: 'Approve', exact: true }).click();
  await expect(page.getByTestId('workflow-timeline').locator('[data-stage-type=commit]')).toContainText('In progress', { timeout: 20_000 });

  await signInAs(page, COMMITTER);
  await page.goto(`/requests/${requestId}`);
  await page.getByRole('button', { name: 'Commit', exact: true }).click();
  await expect(page.getByTestId('request-status')).toContainText('Applied', { timeout: 25_000 });

  await signInAs(page, ARCHITECT);
  await page.goto(`/hierarchies/${HIERARCHY}`);
  await openNodeBySearch(page, RENAMED);
  await openNodeBySearch(page, 'E2E Bulk 0009');
  await expect(page.locator('[data-property="E2E.CostCentre"]')).toContainText('CC-SBX');
  await page.goto(`/hierarchies/${HIERARCHY}`);
  await page.getByRole('treeitem', { name: /^E2E Region North/ }).locator('.twisty').click();
  await expect(page.getByRole('treeitem', { name: /E2E Bulk 0008/ })).toBeVisible();
});

test('a sandbox is discarded, and nothing in it reaches live data', async ({ page }) => {
  const name = `E2E throwaway ${SUFFIX}`;
  await signInAs(page, ARCHITECT);
  await page.goto('/sandboxes');
  await page.getByTestId('sandbox-name').fill(name);
  await page.getByTestId('sandbox-create').click();
  await expect(page).toHaveURL(/sandbox=/);
  const id = new URL(page.url()).searchParams.get('sandbox')!;
  await page.goto(`/hierarchies/${HIERARCHY}?sandbox=${id}`);
  await openNodeBySearch(page, 'E2E Bulk 0010');
  await page.getByRole('button', { name: 'Edit details' }).click();
  const dialog = page.getByRole('dialog');
  await dialog.getByLabel('Description').fill('Thrown away');
  await dialog.getByRole('button', { name: 'Add to request' }).click();
  await expect(page.getByRole('complementary', { name: `Sandbox ${name}` }).getByTestId('tray-count')).toHaveText('1 change');

  await page.goto(`/sandboxes/${id}`);
  await page.getByTestId('sandbox-discard').click();
  await page.getByTestId('sandbox-discard-confirm').click();
  await expect(page).toHaveURL(/\/sandboxes$/);
  await expect(page.getByRole('link', { name })).toHaveCount(0);

  await page.goto(`/hierarchies/${HIERARCHY}`);
  await openNodeBySearch(page, 'E2E Bulk 0010');
  await expect(page.getByText('Thrown away')).toHaveCount(0);
});
