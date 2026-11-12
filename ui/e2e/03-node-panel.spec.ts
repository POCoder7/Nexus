import { expect, test } from '@playwright/test';
import { HIERARCHY, STEWARD, VIEWER, expectAccessible, openNodeBySearch, signInAs } from './fixtures';

/** HIE-12 property grid and SLICE-01 S1-R3: resolved properties with provenance at a chosen date (LLD §13). */
test.describe('Node panel', () => {
  test('shows stored, inherited (with its source) and default values', async ({ page }) => {
    await signInAs(page, VIEWER);
    await page.goto(`/hierarchies/${HIERARCHY}`);
    await openNodeBySearch(page, 'E2E North Leaf One');
    const grid = page.getByRole('grid', { name: 'Properties of E2E North Leaf One' });
    await expect(grid.locator('[data-property="E2E.Currency"]')).toContainText('EUR');
    await expect(grid.locator('[data-property="E2E.Currency"] [data-testid=provenance]')).toContainText('Inherited from E2E Group');
    await expect(grid.locator('[data-property="E2E.Segment"] [data-testid=provenance]')).toContainText('Default');
    await expect(grid.locator('[data-property="E2E.CostCentre"]')).toContainText('Not set');
    // the source link opens the node the value comes from
    await grid.locator('[data-property="E2E.Currency"]').getByRole('button', { name: 'E2E Group' }).click();
    await expect(page.getByTestId('node-name')).toHaveText('E2E Group');
    await expect(grid.or(page.getByRole('grid'))
      .locator('[data-property="E2E.Currency"] [data-testid=provenance]')).toContainText('Stored here');
    await expectAccessible(page);
  });

  test('a leaf says why it cannot have children; relationships show the primary path', async ({ page }) => {
    await signInAs(page, STEWARD);
    await page.goto(`/hierarchies/${HIERARCHY}`);
    await openNodeBySearch(page, 'E2E North Leaf Two');
    await expect(page.getByTestId('add-child-reason')).toHaveText("Leaf nodes can't have children.");
    await page.getByRole('tab', { name: 'Relationships' }).click();
    await expect(page.getByTestId('node-path')).toContainText('E2E Group');
    await expect(page.getByTestId('node-path')).toContainText('E2E Region North');
  });

  test('the grid can be read by keyboard', async ({ page }) => {
    await signInAs(page, VIEWER);
    await page.goto(`/hierarchies/${HIERARCHY}?node=00000000-0000-0000-0000-00000000a011`);
    await expect(page.getByTestId('node-name')).toHaveText('E2E North Leaf One');
    await page.getByRole('columnheader', { name: 'Property' }).focus();
    await page.keyboard.press('ArrowDown');   // category headings are skipped; focus lands on the first property's cell
    await expect(page.locator(':focus')).toHaveAttribute('role', 'gridcell');
    await page.keyboard.press('ArrowRight');
    await expect(page.locator(':focus')).toHaveClass(/value/);
  });
});
