import { expect, test } from '@playwright/test';
import { HIERARCHY, VIEWER, expectAccessible, openNodeBySearch, signInAs } from './fixtures';

/**
 * Phase 3 second scope extension: History tab (QRY-04), Ownership tab (NEW-02 view), before/after view, drag and drop,
 * and property edit rights by category (ADR-036). Runs after 06, whose committed request gives North Leaf Two a history.
 */
test('the History tab lists every version of a node with its request', async ({ page }) => {
  await signInAs(page, VIEWER);
  await page.goto(`/hierarchies/${HIERARCHY}`);
  await openNodeBySearch(page, 'E2E North Leaf Two');
  await page.getByRole('tab', { name: 'History' }).click();
  const history = page.getByTestId('node-history');
  await expect(history.locator('[data-kind=attribute]').first()).toContainText('Synthetic description, edited');
  await expect(history.locator('[data-kind=placement]').first()).toContainText('under E2E Region South');
  await expect(history.locator('[data-kind=property]').first()).toContainText('Segment: Synthetic retail');
  await expect(history.getByRole('link', { name: /^Request:/ }).first()).toBeVisible();
  await expect(history).toContainText('superseded');   // the earlier versions are kept, not overwritten
  await expectAccessible(page);
});

test('the Ownership tab shows direct owners and holdings as tables and a diagram', async ({ page }) => {
  await signInAs(page, VIEWER);
  await page.goto(`/hierarchies/${HIERARCHY}`);
  await openNodeBySearch(page, 'E2E North Leaf One');
  await page.getByRole('tab', { name: 'Ownership' }).click();
  const owners = page.getByTestId('ownership-owners');
  await expect(owners).toContainText('E2E Shared Services');
  await expect(owners).toContainText('60.00');
  await expect(owners).toContainText('40.00');
  await expect(page.getByTestId('ownership-holdings')).toContainText('E2E Bulk 0001');
  await expect(page.getByTestId('ownership-holdings')).toContainText('75.00');
  await expect(page.getByTestId('ownership-diagram')).toBeVisible();
  await expectAccessible(page);
  // as of a date before the edges existed there is nothing
  await page.goto(`/hierarchies/${HIERARCHY}?asOf=2019-06-30&node=00000000-0000-0000-0000-00000000a011`);
  await expect(page.getByTestId('node-name')).toHaveCount(0);   // the node itself did not exist yet either
});

test('a steward limited to Finance properties sees Edit only on Finance properties', async ({ page }) => {
  await signInAs(page, 'e2e_finance');
  await page.goto(`/hierarchies/${HIERARCHY}`);
  await openNodeBySearch(page, 'E2E North Leaf One');
  await expect(page.getByRole('button', { name: 'Edit Reporting currency' })).toBeVisible();
  await expect(page.locator('[data-property="E2E.LegalForm"]')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Edit Legal form' })).toHaveCount(0);
});

test('dragging a node onto another opens "Move to…" with that target chosen', async ({ page }) => {
  await signInAs(page, 'e2e_architect');
  await page.goto(`/hierarchies/${HIERARCHY}`);
  await page.getByRole('treeitem', { name: /^E2E Region North/ }).locator('.twisty').click();
  const source = page.getByRole('treeitem', { name: /^E2E North Leaf One/ });
  await expect(source).toHaveAttribute('draggable', 'true');
  await source.dragTo(page.getByRole('treeitem', { name: /^E2E Region South/ }));
  const dialog = page.getByRole('dialog', { name: 'Move E2E North Leaf One' });
  await expect(dialog).toContainText('Chosen: E2E Region South');
  await dialog.getByRole('button', { name: 'Cancel' }).click();
  await expect(dialog).toHaveCount(0);
});

test('a request can be compared side by side or inline', async ({ page }) => {
  await signInAs(page, 'e2e_steward');
  await page.goto('/home');
  await page.getByTestId('home-requests').getByRole('link').first().click();
  const items = page.getByTestId('item-list');
  await expect(items).toBeVisible();
  await page.getByRole('button', { name: 'Inline' }).click();
  await expect(page.getByRole('button', { name: 'Inline' })).toHaveAttribute('aria-pressed', 'true');
  await expect(page.getByTestId('item-list').locator('.line--added').first()).toBeVisible();
  await expect(page.getByTestId('item-list').locator('[data-change]').first()).toContainText(/Added|Changed|Removed|Moved/);
  await expectAccessible(page);
});
