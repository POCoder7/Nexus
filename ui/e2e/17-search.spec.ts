import { expect, test } from '@playwright/test';
import { expectAccessible, signInAs } from './fixtures';

/** QRY-03 (Phase 5 LLD §17.6, §17.6.1): search across hierarchies, from the header, for hierarchies, nodes and requests. */
test.describe('Search', () => {
  test('the header finds hierarchies and nodes across every readable hierarchy, and opens a node in its hierarchy', async ({ page }) => {
    await signInAs(page, 'u_viewer');   // reads ORGTL, ORGTP and AMBUS
    await page.goto('/home');
    await page.getByLabel('Find a node or request').fill('Demo');
    await page.getByRole('button', { name: 'Search', exact: true }).click();
    const results = page.getByRole('region', { name: 'Search' });
    await expect(results).toContainText('Demo Org Legal (ORGTL)');
    await expect(results).toContainText('Demo AM Business (AMBUS)');
    await expect(results).not.toContainText('E2E Legal Group');   // not readable by u_viewer
    await expectAccessible(page);

    await page.getByTestId('search-see-all').click();
    await expect(page).toHaveURL(/\/search\?q=Demo/);
    await expect(page.getByTestId('search-hierarchies')).toContainText('Demo Org Profit');
    await page.getByTestId('search-nodes').getByRole('link', { name: 'Demo Legal Region A' }).click();
    await expect(page).toHaveURL(/\/hierarchies\/ORGTL\?.*node=/);
    await expect(page.getByTestId('node-name')).toHaveText('Demo Legal Region A');
  });

  test('requests are found by title, and only by those who can see them', async ({ page }) => {
    await signInAs(page, 'u_viewer');   // 15-audit's request changed ORGTL, which u_viewer reads
    await page.goto('/search?q=audit%20journey');
    await expect(page.getByTestId('search-requests')).toContainText('E2E audit journey');
    await expectAccessible(page);

    await signInAs(page, 'u_editor2');   // AMBUS only
    await page.goto('/search?q=audit%20journey');
    await expect(page.getByTestId('search-none')).toBeVisible();
  });
});
