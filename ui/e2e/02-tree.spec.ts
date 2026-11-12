import { expect, test } from '@playwright/test';
import { HIERARCHY, VIEWER, expectAccessible, signInAs } from './fixtures';

/** HIE-12 and SLICE-01 S1-R2: lazy tree, paged siblings, in-tree search, keyboard (Phase 3 LLD §7, §13). */
test.describe('Hierarchy tree', () => {
  test.beforeEach(async ({ page }) => {
    await signInAs(page, VIEWER);
    await page.goto(`/hierarchies/${HIERARCHY}`);
    await expect(page.getByRole('treeitem', { name: /E2E Region North/ })).toBeVisible();
  });

  test('pages a large sibling set with "Show next 200" to the last page', async ({ page }) => {
    const tree = page.getByRole('tree');
    await page.getByRole('treeitem', { name: /E2E Bulk Parent/ }).locator('.twisty').click();
    await expect(tree.getByText('E2E Bulk 0001')).toBeVisible();
    // virtual scrolling renders only rows in view, so scroll the viewport (as a person would) until a row appears
    const scrollUntil = async (locator: ReturnType<typeof tree.getByText>) => {
      for (let step = 0; step < 60 && (await locator.count()) === 0; step++) {
        await tree.evaluate((el) => el.scrollBy(0, 600));
        await page.waitForTimeout(50);
      }
      await expect(locator.first()).toBeVisible();
    };
    for (const lastOnPage of ['E2E Bulk 0200', 'E2E Bulk 0400']) {
      const more = tree.getByTestId('tree-show-next');
      await scrollUntil(more);
      await expect(more).toHaveText('Show next 200');
      await more.click();
      await scrollUntil(tree.getByText(lastOnPage));
    }
    // after the third page (450 children) there is no "show next" row: page boundary
    await scrollUntil(tree.getByText('E2E Bulk 0450'));
    await tree.evaluate((el) => el.scrollBy(0, 2000));
    await expect(tree.getByTestId('tree-show-next')).toHaveCount(0);
    await expect(tree.getByText('E2E Level 1')).toBeVisible();   // the next sibling of the bulk parent follows directly
    // virtual scrolling: far fewer DOM rows than loaded rows
    expect(await page.locator('[role=treeitem]').count()).toBeLessThan(120);
  });

  test('search reveals a node nine levels down and selects it', async ({ page }) => {
    await page.getByLabel('Search in this hierarchy').fill('Deep Target');
    const option = page.getByRole('option', { name: /E2E Deep Target/ });
    await expect(option).toContainText('E2E Level 8');   // the path is shown with the hit
    await option.click();
    await expect(page.getByTestId('node-name')).toHaveText('E2E Deep Target');
    const item = page.getByRole('treeitem', { name: /E2E Deep Target/ });
    await expect(item).toHaveAttribute('aria-selected', 'true');
    await expect(item).toHaveAttribute('aria-level', '10');
    await expect(page).toHaveURL(/node=00000000-0000-0000-0000-0000000c0009/);
  });

  test('a one-character search is refused with a message', async ({ page }) => {
    await page.getByLabel('Search in this hierarchy').fill('E');
    await expect(page.getByTestId('search-message')).toHaveText('Type at least 2 characters to search.');
    await expect(page.getByRole('listbox')).toHaveCount(0);
  });

  test('works by keyboard alone: move, expand, type ahead, select', async ({ page }) => {
    const tree = page.getByRole('tree');
    await tree.focus();
    await page.keyboard.press('ArrowDown');                 // E2E Region North
    await page.keyboard.press('ArrowRight');                // expand it
    await expect(page.getByRole('treeitem', { name: /E2E North Leaf One/ })).toBeVisible();
    await page.keyboard.press('ArrowRight');                // first child
    await expect(tree).toHaveAttribute('aria-activedescendant', /a011/);
    await page.keyboard.press('ArrowLeft');                 // back to the parent
    await expect(tree).toHaveAttribute('aria-activedescendant', /a001$/);
    await page.keyboard.type('E2E Region S');               // type-ahead over visible rows
    await expect(tree).toHaveAttribute('aria-activedescendant', /a002$/);
    await page.keyboard.press('Enter');
    await expect(page.getByTestId('node-name')).toHaveText('E2E Region South');
    // the shared node shows under South with the shared indicator
    await page.keyboard.press('ArrowRight');
    await expect(page.getByRole('treeitem', { name: /E2E Shared Services.*Shared/ })).toBeVisible();
    await expectAccessible(page);
  });

  test('@perf expand trace on a large parent (deferred: performance testing at the end of the build)', async ({ page }) => {
    await page.getByRole('treeitem', { name: /E2E Bulk Parent/ }).locator('.twisty').click();
    await expect(page.getByRole('tree').getByText('E2E Bulk 0001')).toBeVisible();
  });
});
