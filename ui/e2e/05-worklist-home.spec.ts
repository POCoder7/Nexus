import { expect, test } from '@playwright/test';
import { APPROVER, POLICY, STEWARD, apiAs, expectAccessible, signInAs } from './fixtures';

/** GOV-13 worklist screen and NEW-10 Home (Phase 3 LLD §12.2, §13). Runs after the SLICE-01 journey. */
test.describe('Worklist and Home', () => {
  test('each view chip shows the API count; search and model filter narrow the rows', async ({ page }) => {
    const api = await apiAs(STEWARD);
    const counts = (await (await api.get('/api/v1/worklist?view=all&limit=1')).json()).counts as Record<string, number>;
    await api.dispose();
    await signInAs(page, STEWARD);
    await page.goto('/worklist');
    for (const [view, n] of Object.entries(counts)) {
      await expect(page.locator(`[data-view="${view}"] [data-testid=view-count]`)).toHaveText(String(n));
    }
    // the worklist is open work only: the committed request has left it; the steward's open draft is under Drafted
    await page.locator('[data-view="drafted"]').click();
    await expect(page).toHaveURL(/view=drafted/);
    await expect(page.getByTestId('worklist-table')).toContainText('Add E2E North Leaf One under E2E Region North');
    await page.getByLabel('Search titles').fill('no-such-title-zzz');
    await expect(page.getByText('You have no drafts.')).toBeVisible();
    await page.getByLabel('Search titles').fill('');
    await page.getByLabel('Workflow model').fill('ADD_LEAF');
    await page.getByLabel('Workflow model').press('Tab');
    await expect(page).toHaveURL(/model=ADD_LEAF/);
    await expect(page.getByTestId('worklist-table')).toContainText('Add E2E North Leaf One');
    await expectAccessible(page);
  });

  test('an empty view says so in words', async ({ page }) => {
    await signInAs(page, APPROVER);
    await page.goto('/worklist?view=overdue');
    await expect(page.getByText('Nothing is overdue.')).toBeVisible();
  });

  test('Home shows the governance panel to policy roles only, and search opens a node', async ({ page }) => {
    await signInAs(page, POLICY);
    await page.goto('/home');
    await expect(page.getByTestId('home-governance')).toContainText('E2E_SHADOW');
    await expectAccessible(page);
    await page.goto('/home');
    await signInAs(page, STEWARD);
    await page.goto('/home');
    await expect(page.getByTestId('home-governance')).toHaveCount(0);
    await expect(page.getByTestId('home-requests')).toContainText('E2E New Leaf');
    await page.getByLabel('Find a node or request').fill('Leaf Two');
    await page.getByRole('button', { name: 'Search' }).click();
    await page.getByTestId('home-search-results').getByRole('link', { name: 'E2E North Leaf Two' }).click();
    await expect(page.getByTestId('node-name')).toHaveText('E2E North Leaf Two');
  });
});
