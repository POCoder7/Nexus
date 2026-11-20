import { expect, test } from '@playwright/test';
import { readdirSync } from 'node:fs';
import { join } from 'node:path';
import { expectAccessible, signInAs } from './fixtures';

/**
 * ADR-046 (Phase 4 LLD §17.8.2): Admin › Data loads with the synthetic sample (the API's test fixture). One ADMIN
 * uploads and prepares; a second approves and applies; the result is clean. Runs last: the loaded rules apply to every
 * hierarchy from then on.
 */
const SAMPLE = join(__dirname, '..', '..', 'services', 'mdm-api', 'src', 'test', 'resources', 'load', 'hackathon');
let loadUrl = '';

test.describe.serial('Data loads', () => {
  test('an administrator uploads and prepares the data set, and cannot approve it themselves', async ({ page }) => {
    await signInAs(page, 'u_admin');
    await page.goto('/admin/data-loads');
    await page.getByTestId('load-files-input').setInputFiles(readdirSync(SAMPLE).map((f) => join(SAMPLE, f)));
    await page.getByTestId('load-upload').click();
    await expect(page).toHaveURL(/\/admin\/data-loads\/[0-9a-f-]{36}$/, { timeout: 30_000 });
    loadUrl = new URL(page.url()).pathname;
    await expect(page.getByTestId('load-files')).toContainText('nodes.csv');
    await expect(page.getByTestId('load-errors')).toHaveCount(0);
    await expectAccessible(page);

    await page.getByRole('button', { name: 'Prepare the load' }).click();
    await expect(page.getByTestId('load-status')).toContainText('Waiting for approval');
    await expect(page.getByTestId('load-plan')).toContainText('ORGNEXUS');
    await expect(page.getByRole('button', { name: 'Approve' })).toBeDisabled();
    await expect(page.getByTestId('why-not')).toContainText('A second administrator approves it');
    await expectAccessible(page);
  });

  test('a second administrator approves and applies it, and the result is clean', async ({ page }) => {
    test.setTimeout(180_000);
    await signInAs(page, 'e2e_admin');
    await page.goto(loadUrl);
    await page.getByRole('button', { name: 'Approve' }).click();
    await expect(page.getByTestId('load-status')).toContainText('Approved');
    await page.getByRole('button', { name: 'Apply' }).click();
    await expect(page.getByTestId('load-result')).toBeVisible({ timeout: 150_000 });
    await expect(page.getByTestId('load-status')).toContainText('Applied');
    await expect(page.getByTestId('load-reconciliation')).toContainText('Everything staged is in Nexus.');
    await expect(page.getByTestId('load-requests').getByRole('link')).toHaveCount(7);
    await expectAccessible(page);

    await page.goto('/admin/data-loads');
    await expect(page.getByTestId('load-history')).toContainText('Applied');
  });
});
