import { expect, test } from '@playwright/test';
import { expectAccessible, signInAs } from './fixtures';

/** ADR-046 D5 (Phase 4 LLD §17.5): Admin › Validation rules, the one rule catalogue with the database guards in it. */
test.describe('Validation rules', () => {
  test('an administrator sees rules and guards, and gives a guard their own code', async ({ page }) => {
    await signInAs(page, 'u_admin');
    await page.goto('/admin/validation-rules');
    const table = page.getByTestId('rules-table');
    const cycle = table.locator('tr[data-rule="NEXUS.HIERARCHY_CYCLE"]');
    await expect(cycle).toContainText('Database guard');
    await expect(cycle).toContainText('Always on');
    await expectAccessible(page);

    await page.locator('[data-filter="guard"]').click();
    await expect(table.locator('tbody tr')).toHaveCount(16);

    await cycle.getByRole('button', { name: /Edit/ }).click();
    const dialog = page.getByRole('dialog');
    await expect(dialog.getByTestId('rule-guard-note')).toBeVisible();
    await expect(dialog.getByLabel('Severity')).toHaveCount(0);   // a guard cannot be weakened, so it is not offered
    await expectAccessible(page);
    await dialog.getByLabel('Your code').fill('VR07');
    await dialog.getByTestId('rule-save').click();
    await expect(dialog).toHaveCount(0);
    await expect(cycle.locator('th')).toContainText('VR07');
  });

  test('an editor is told the rules are for administrators and approvers', async ({ page }) => {
    await signInAs(page, 'u_editor1');
    await page.goto('/admin/validation-rules');
    await expect(page.getByRole('alert')).toContainText('Only administrators and approvers');
  });
});
