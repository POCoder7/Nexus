import { expect, test } from '@playwright/test';
import { expectAccessible, signInAs } from './fixtures';

/** Phase 5 LLD §20 (HIE-12, VER-01): every hierarchy the user may read in one tree, under the version. */
test.describe('All hierarchies', () => {
  test('the version is the root, readable hierarchies are below it, and a node opens read-only with a link to edit', async ({ page }) => {
    await signInAs(page, 'u_viewer');
    await page.goto('/browse');
    const tree = page.getByTestId('hierarchy-tree');
    await expect(tree.getByRole('treeitem').first()).toContainText('E2E working');
    await expect(tree.getByRole('treeitem', { name: /Demo Org Legal \(ORGTL\)/ })).toBeVisible();
    await expect(tree.getByRole('treeitem', { name: /Demo AM Business \(AMBUS\)/ })).toBeVisible();
    await expect(tree.getByRole('treeitem', { name: /E2E Legal Group/ })).toHaveCount(0);   // not readable by u_viewer

    await tree.getByRole('treeitem', { name: /Demo Org Legal \(ORGTL\)/ }).locator('.twisty').click();
    await expect(tree.getByRole('treeitem', { name: 'Demo Legal Region A' })).toBeVisible();
    await tree.getByRole('treeitem', { name: 'Demo Legal Region A' }).click();
    await expect(page.getByTestId('node-name')).toHaveText('Demo Legal Region A');
    await expect(page.getByTestId('open-in-hierarchy')).toHaveAttribute('href', /\/hierarchies\/ORGTL\?node=/);
    await expectAccessible(page);

    await page.getByTestId('open-in-hierarchy').click();
    await expect(page).toHaveURL(/\/hierarchies\/ORGTL\?node=/);
    await expect(page.getByTestId('node-name')).toHaveText('Demo Legal Region A');
  });

  test('a user sees only the hierarchies their groups give them', async ({ page }) => {
    await signInAs(page, 'u_editor2');
    await page.goto('/browse');
    const tree = page.getByTestId('hierarchy-tree');
    await expect(tree.getByRole('treeitem', { name: /Demo AM Business \(AMBUS\)/ })).toBeVisible();
    await expect(tree.getByRole('treeitem', { name: /ORGTL|ORGTP/ })).toHaveCount(0);
  });
});
