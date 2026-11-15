import { Page, expect, test } from '@playwright/test';
import { HIERARCHY, VIEWER, expectAccessible, signInAs } from './fixtures';

/**
 * QRY-01 property queries (Phase 5 LLD §17.12, PLAN 5-13b): a query with a nested group and a column is built and run,
 * "Show more" fetches the next page, the query is saved and shared, and another reader opens and runs it with their own
 * access. Synthetic data only.
 */
test.describe.configure({ mode: 'serial' });

const ARCHITECT = 'e2e_architect';
const NAME = `E2E bulk query ${Date.now().toString(36).toUpperCase().slice(-5)}`;

async function condition(page: Page, n: number, field: string, op: string, value?: string) {
  await page.getByLabel(`Condition ${n}: field`).selectOption({ label: field });
  await page.getByLabel(`Condition ${n}: comparison`).selectOption({ label: op });
  if (value !== undefined) {
    const input = page.getByLabel(`Condition ${n}: value`);
    if (await input.evaluate((el) => el.tagName === 'SELECT')) {
      await input.selectOption({ label: value });
    } else {
      await input.fill(value);
    }
  }
}

test('a query with a nested group runs, and Show more brings the next page', async ({ page }) => {
  await signInAs(page, ARCHITECT);
  await page.goto('/queries');
  await expect(page.getByTestId('query-hierarchy')).toHaveValue(HIERARCHY);
  await expectAccessible(page);

  // leaves whose name starts with "E2E Bulk 01" or "E2E Bulk 02": 200 of the 450 bulk leaves
  await page.getByTestId('query-add-condition').click();
  await condition(page, 1, 'Is a leaf', 'is', 'Yes');
  await page.getByTestId('query-add-group').first().click();
  const group = page.locator('fieldset[data-depth="1"]');
  await group.getByTestId('query-add-condition').click();
  await group.getByTestId('query-add-condition').click();
  await condition(page, 2, 'Name', 'starts with', 'E2E Bulk 01');
  await condition(page, 3, 'Name', 'starts with', 'E2E Bulk 02');
  await page.getByTestId('query-columns').selectOption({ label: 'Reporting currency (E2E.Currency)' });
  await expectAccessible(page);

  await page.getByTestId('query-run').click();
  await expect(page.getByTestId('query-status')).toHaveText('100 matches+');
  const results = page.getByTestId('query-results');
  await expect(results.getByRole('row')).toHaveCount(101);   // header + 100
  await expect(results.getByRole('row').nth(1)).toContainText('E2E Bulk 0100');
  await expect(results.getByRole('row').nth(1)).toContainText('inherited');
  await page.getByTestId('query-more').click();
  await expect(page.getByTestId('query-status')).toHaveText('200 matches');
  await expect(page.getByTestId('query-more')).toHaveCount(0);
  await expect(results.getByRole('row').last()).toContainText('E2E Bulk 0299');
  await expectAccessible(page);
});

test('a refused condition is explained before anything runs', async ({ page }) => {
  await signInAs(page, ARCHITECT);
  await page.goto('/queries');
  await page.getByTestId('query-add-condition').click();
  await condition(page, 1, 'Name', 'starts with');
  await page.getByTestId('query-run').click();
  await expect(page.getByTestId('query-problems')).toHaveText('Condition 1: enter a value.');
  await expect(page.getByTestId('query-results')).toHaveCount(0);
});

test('the query is saved and shared', async ({ page }) => {
  await signInAs(page, ARCHITECT);
  await page.goto('/queries');
  await page.getByTestId('query-add-condition').click();
  await condition(page, 1, 'Name', 'starts with', 'E2E Bulk 03');
  await page.getByTestId('query-run').click();
  await expect(page.getByTestId('query-status')).toHaveText('100 matches');
  await page.getByTestId('query-save-name').fill(NAME);
  await page.getByTestId('query-share').check();
  await page.getByTestId('query-save').click();
  const saved = page.getByTestId('saved-queries').locator(`[data-saved="${NAME}"]`);
  await expect(saved).toContainText('Shared');
});

test('another reader opens the shared query and runs it with their own access', async ({ page }) => {
  await signInAs(page, VIEWER);
  await page.goto('/queries');
  const saved = page.getByTestId('saved-queries').locator(`[data-saved="${NAME}"]`);
  await saved.getByRole('button', { name: new RegExp(NAME) }).click();
  await expect(page.getByTestId('query-status')).toHaveText('100 matches');
  await expect(page.getByRole('note')).toContainText('Shared by someone else');
  await expect(saved.getByRole('button', { name: `Delete ${NAME}` })).toHaveCount(0);
  await expectAccessible(page);
});
