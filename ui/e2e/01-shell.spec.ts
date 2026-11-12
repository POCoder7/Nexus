import { expect, test } from '@playwright/test';
import { HIERARCHY, STEWARD, VIEWER, businessToday, dayBefore, expectAccessible, signInAs } from './fixtures';

/** NEW-10: shell, Home, start page preference, historical view (Phase 3 LLD §6.3, §12, §13). */
test.describe('Shell and start page', () => {
  test('signs in, shows the server business day and lands on Home', async ({ page }) => {
    await signInAs(page, STEWARD);
    await page.goto('/');
    await expect(page).toHaveURL(/\/home$/);
    await expect(page.getByTestId('signed-in-user')).toContainText('E2E Steward');
    await expect(page.getByTestId('context-version')).toHaveText('E2E working');
    // "today" is the server's business date even though the browser runs in another time zone (ADR-018)
    await expect(page.getByLabel('Viewing as of')).toHaveValue(await businessToday());
    await expect(page.getByTestId('home-hierarchies')).toContainText('E2E Legal Group');
    await expect(page.getByTestId('home-governance')).toHaveCount(0);   // policy panel only for policy roles
    await expectAccessible(page);
  });

  test('respects the start page preference after a reload', async ({ page }) => {
    await signInAs(page, VIEWER);
    await page.goto('/settings');
    await page.getByLabel('Worklist').check();
    await expect(page.getByRole('status').filter({ hasText: 'Settings saved' })).toBeVisible();
    await expectAccessible(page);
    await page.goto('/');
    await expect(page).toHaveURL(/\/worklist/);
    await page.goto('/settings');
    await page.getByLabel('Hierarchies (the last one you used)').check();
    await page.goto(`/hierarchies/${HIERARCHY}`);
    await expect(page.getByRole('tree')).toBeVisible();
    await page.waitForTimeout(2500);   // the last hierarchy is remembered after a 2 s debounce (LLD §5.2)
    await page.goto('/');
    await expect(page).toHaveURL(new RegExp(`/hierarchies/${HIERARCHY}`));
  });

  test('a historical view shows the banner and removes every write control', async ({ page }) => {
    await signInAs(page, STEWARD);
    const yesterday = dayBefore(await businessToday());
    await page.goto(`/hierarchies/${HIERARCHY}?asOf=${yesterday}&node=00000000-0000-0000-0000-00000000a001`);
    await expect(page.getByTestId('historical-banner')).toContainText('Everything is read-only');
    await expect(page.getByTestId('node-name')).toHaveText('E2E Region North');
    await expect(page.getByRole('button', { name: 'Add child' })).toHaveCount(0);
    await expect(page.getByTestId('add-child-reason')).toHaveCount(0);
    await expectAccessible(page);
    await page.getByRole('button', { name: 'Today' }).click();
    await expect(page.getByTestId('historical-banner')).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Add child' })).toBeVisible();
  });
});
