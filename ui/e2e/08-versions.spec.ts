import { Page, expect, test } from '@playwright/test';
import { APPROVER, COMMITTER, HIERARCHY, VIEWER, apiAs, businessToday, dayBefore, escapeRegExp, expectAccessible, openNodeBySearch,
  signInAs } from './fixtures';

/**
 * Versions end to end on synthetic data (VER-01, VER-02; Phase 3 LLD V.6, V.8). A version administrator creates a version
 * and a copy of it; a steward raises a request in it; the version cannot be submitted while that request is in flight;
 * once it is applied the version is submitted, which freezes its picture, so a later change effective on the same date
 * does not appear in it. Finalizing needs a second administrator, the finalized picture is read-only, and the version
 * is then expired. The steps share one version, so they run in order.
 *
 * The steward is e2e_architect: e2e_steward keeps an open draft from 04, and "Add child" would add to that draft.
 * Both leaves are effective the day before today, so they fall inside a version dated that day.
 */
test.describe.configure({ mode: 'serial' });

const ADMIN = 'e2e_vadmin';
const ADMIN2 = 'e2e_vadmin2';
const ARCHITECT = 'e2e_architect';
const SUFFIX = Date.now().toString(36);
const CLOSE = `E2E close ${SUFFIX}`;
const COPY = `E2E copy ${SUFFIX}`;
const LEAF_IN = `E2E Close Leaf A ${SUFFIX}`;
const LEAF_LATER = `E2E Close Leaf B ${SUFFIX}`;
let versionDate = '';

function row(page: Page, name: string) {
  return page.locator(`tr[data-version="${name}"]`);
}

function toast(page: Page, text: string) {
  return page.getByRole('status').filter({ hasText: text }).first();
}

/**
 * The architect adds a leaf under E2E Region North, effective on the version's date, and submits the request. With
 * `choose` the architect picks the version in the context bar; without it the version must already be the one shown.
 */
async function raiseLeaf(page: Page, leaf: string, version: string, costCentre: string, choose: boolean): Promise<string> {
  await signInAs(page, ARCHITECT);
  await page.goto(`/hierarchies/${HIERARCHY}`);
  if (choose) {
    await page.getByTestId('context-version').selectOption(version);
    await expect(toast(page, `New requests will be raised in ${version}`)).toBeVisible();
  }
  await expect(page.getByTestId('context-version')).toHaveValue(version);
  await openNodeBySearch(page, 'E2E Region North');
  await page.getByRole('button', { name: 'Add child' }).click();
  const dialog = page.getByRole('dialog', { name: 'Add a child under E2E Region North' });
  await dialog.getByLabel('Name').fill(leaf);
  await dialog.getByLabel('Effective from').fill(versionDate);
  await dialog.getByLabel('Cost centre').fill(costCentre);
  await dialog.getByRole('button', { name: 'Add to request' }).click();
  await expect(dialog).toHaveCount(0);
  const tray = page.getByRole('complementary', { name: 'Your draft request' });
  // the tray names a version only when the draft is in another one than the context bar shows (LLD V.6)
  await expect(tray.getByTestId('tray-version')).toHaveCount(0);
  await tray.getByRole('button', { name: 'Review and submit' }).click();
  await expect(page.getByTestId('review-version')).toHaveText(`Version ${version}`);
  await expect(page.getByTestId('validation-ok')).toBeVisible();
  const id = page.url().split('/requests/')[1].split('/')[0];
  await page.getByRole('button', { name: 'Submit request' }).click();
  await expect(page.getByTestId('workflow-timeline').locator('[data-stage-type=approve]')).toContainText('In progress', { timeout: 20_000 });
  return id;
}

async function approveAndCommit(page: Page, id: string): Promise<void> {
  await signInAs(page, APPROVER);
  await page.goto(`/requests/${id}`);
  await page.getByRole('button', { name: 'Approve' }).click();
  await expect(page.getByTestId('workflow-timeline').locator('[data-stage-type=commit]')).toContainText('In progress', { timeout: 20_000 });
  await signInAs(page, COMMITTER);
  await page.goto(`/requests/${id}`);
  await page.getByRole('button', { name: 'Commit' }).click();
  await expect(page.getByTestId('request-status')).toContainText('Applied', { timeout: 25_000 });
}

/** Opens the version's picture from the Versions page, as the architect (whose Hierarchies opens E2E_H). */
async function openPicture(page: Page, version: string): Promise<void> {
  const api = await apiAs(ARCHITECT);
  expect((await api.put('/api/v1/me/preferences', { data: { lastHierarchyCode: HIERARCHY } })).ok()).toBe(true);
  await api.dispose();
  await signInAs(page, ARCHITECT);
  await page.goto('/versions');
  await row(page, version).getByRole('button', { name: `Open picture ${version}` }).click();
  await expect(page).toHaveURL(new RegExp(`/hierarchies/${HIERARCHY}\\?.*version=`));
}

async function expandNorth(page: Page): Promise<void> {
  await page.getByRole('treeitem', { name: /^E2E Region North/ }).locator('.twisty').click();
  await expect(page.getByRole('treeitem', { name: /E2E North Leaf One/ })).toBeVisible();
}

let firstRequest = '';

test('VER-01: an administrator creates a version and a copy of it; others cannot', async ({ page }) => {
  versionDate = dayBefore(await businessToday());
  await signInAs(page, ADMIN);
  await page.goto('/versions');
  await expect(page.getByRole('heading', { name: 'Versions', level: 1 })).toBeVisible();
  await expect(page.getByTestId('versions-shared-note')).toContainText('Working versions are not separate copies');

  await page.getByRole('button', { name: 'New version' }).click();
  let dialog = page.getByRole('dialog', { name: 'Create a version' });
  await dialog.getByRole('textbox', { name: /^Name/ }).fill(CLOSE);
  await dialog.getByRole('textbox', { name: /^Business date/ }).fill(versionDate);
  await dialog.getByLabel('Description').fill('Synthetic month-end close');
  await dialog.getByRole('button', { name: 'Create version' }).click();
  await expect(dialog).toHaveCount(0);
  await expect(toast(page, `Version ${CLOSE} created`)).toBeVisible();
  await expect(row(page, CLOSE).getByTestId('version-status')).toContainText('Working');
  await expect(row(page, CLOSE)).toContainText('Not frozen');
  await expect(page.getByRole('button', { name: 'New version' })).toBeFocused();   // focus returns to the trigger

  // a copy: leaving the date empty uses the base's date, so it shows the same picture
  await page.getByRole('button', { name: 'New version' }).click();
  dialog = page.getByRole('dialog', { name: 'Create a version' });
  await dialog.getByRole('textbox', { name: /^Name/ }).fill(COPY);
  await dialog.getByLabel('Copy from').selectOption(CLOSE);
  await expect(dialog).toContainText(`Leave empty to use the date of ${CLOSE}`);
  await dialog.getByRole('button', { name: 'Create version' }).click();
  await expect(dialog).toHaveCount(0);
  await expect(row(page, COPY)).toContainText(CLOSE);   // Based on
  const api = await apiAs(ADMIN);
  const copy = await (await api.get(`/api/v1/versions/${encodeURIComponent(COPY)}`)).json();
  await api.dispose();
  expect(copy.businessAsOf).toBe(versionDate);
  expect(copy.baseVersion).toBe(CLOSE);

  // the description can be edited while the version is working
  await row(page, COPY).getByRole('button', { name: `Edit ${COPY}` }).click();
  dialog = page.getByRole('dialog', { name: `Edit version ${COPY}` });
  await dialog.getByLabel('Description').fill('Synthetic what-if copy');
  await dialog.getByRole('button', { name: 'Save changes' }).click();
  await expect(dialog).toHaveCount(0);
  await expect(row(page, COPY)).toContainText('Synthetic what-if copy');
  await expectAccessible(page);

  // a viewer sees the list and the pictures, and no way to change them
  await signInAs(page, VIEWER);
  await page.goto('/versions');
  await expect(row(page, CLOSE)).toBeVisible();
  await expect(page.getByTestId('new-version')).toHaveCount(0);
  await expect(row(page, CLOSE).getByRole('button')).toHaveText([/Open picture/]);
});

test('VER-01: a steward raises a request in the version; it cannot be submitted while the request is in flight', async ({ page }) => {
  firstRequest = await raiseLeaf(page, LEAF_IN, CLOSE, 'CC-E2E-V1', true);

  await signInAs(page, ADMIN);
  await page.goto('/versions');
  const submit = row(page, CLOSE).getByRole('button', { name: `Submit ${CLOSE}` });
  await expect(submit).toBeDisabled();
  const why = row(page, CLOSE).getByTestId('why-not');
  await expect(why).toContainText('1 request in this version is still in flight');
  await expect(submit).toHaveAttribute('aria-describedby', (await why.getAttribute('id'))!);
  await expectAccessible(page);
});

test('VER-02: once the request is applied, submitting freezes the version\'s picture', async ({ page }) => {
  await approveAndCommit(page, firstRequest);

  await signInAs(page, ADMIN);
  await page.goto('/versions');
  await row(page, CLOSE).getByRole('button', { name: `Submit ${CLOSE}` }).click();
  const dialog = page.getByRole('dialog', { name: `Submit version ${CLOSE}?` });
  await expect(dialog.getByTestId('transition-effect')).toContainText('Submitting freezes the picture now');
  await dialog.getByLabel('Reason').fill('Synthetic close is complete');
  await expectAccessible(page);
  await dialog.getByRole('button', { name: 'Submit version' }).click();
  await expect(dialog).toHaveCount(0);
  await expect(toast(page, `Version ${CLOSE} is now submitted`)).toBeVisible();
  await expect(row(page, CLOSE).getByTestId('version-status')).toContainText('Submitted');
  await expect(row(page, CLOSE)).not.toContainText('Not frozen');
});

test('VER-02: a change committed after the freeze does not appear in the picture, but does in the live data', async ({ page }) => {
  // the architect's choice is no longer working, so new requests fall back to the latest working version (LLD V.5)
  const later = await raiseLeaf(page, LEAF_LATER, 'E2E working', 'CC-E2E-V2', false);
  await approveAndCommit(page, later);

  await openPicture(page, CLOSE);
  await expect(page.getByTestId('historical-banner')).toContainText(`Version ${CLOSE}, submitted: the data on`);
  await expect(page.getByTestId('historical-banner')).toContainText('Read-only.');
  await expandNorth(page);
  await expect(page.getByRole('treeitem', { name: new RegExp(escapeRegExp(LEAF_IN)) })).toBeVisible();
  await expect(page.getByRole('treeitem', { name: new RegExp(escapeRegExp(LEAF_LATER)) })).toHaveCount(0);
  await page.getByLabel('Search in this hierarchy').fill(LEAF_LATER);
  await expect(page.getByTestId('search-message')).toHaveText('No nodes match.');

  // the same business date, as recorded now: both leaves
  await page.goto(`/hierarchies/${HIERARCHY}?asOf=${versionDate}`);
  await expandNorth(page);
  await expect(page.getByRole('treeitem', { name: new RegExp(escapeRegExp(LEAF_IN)) })).toBeVisible();
  await expect(page.getByRole('treeitem', { name: new RegExp(escapeRegExp(LEAF_LATER)) })).toBeVisible();
});

test('VER-02: the administrator who submitted cannot finalize; a second administrator does', async ({ page }) => {
  await signInAs(page, ADMIN);
  await page.goto('/versions');
  await expect(row(page, CLOSE).getByRole('button', { name: `Finalize ${CLOSE}` })).toBeDisabled();
  await expect(row(page, CLOSE).getByTestId('why-not'))
    .toHaveText('You submitted this version; another version administrator must finalize it');

  await signInAs(page, ADMIN2);
  await page.goto('/versions?status=submitted');
  await row(page, CLOSE).getByRole('button', { name: `Finalize ${CLOSE}` }).click();
  const dialog = page.getByRole('dialog', { name: `Finalize version ${CLOSE}?` });
  await expect(dialog.getByTestId('transition-effect')).toContainText('Finalizing is permanent');
  await dialog.getByRole('button', { name: 'Finalize version' }).click();
  await expect(dialog).toHaveCount(0);
  await expect(toast(page, `Version ${CLOSE} is now finalized`)).toBeVisible();
  // the Submitted view no longer lists it
  await expect(row(page, CLOSE)).toHaveCount(0);
});

test('VER-02: the finalized picture is read-only, and the version is then expired', async ({ page }) => {
  await openPicture(page, CLOSE);
  await expect(page.getByTestId('historical-banner')).toContainText(`Version ${CLOSE}, finalized: the data on`);
  await openNodeBySearch(page, 'E2E Region North');
  await expect(page.getByRole('button', { name: 'Add child' })).toHaveCount(0);   // no write control in a picture
  await openNodeBySearch(page, LEAF_IN);
  await expect(page.getByRole('grid').locator('[data-property="E2E.CostCentre"]')).toContainText('CC-E2E-V1');
  await expectAccessible(page);

  await signInAs(page, ADMIN);
  await page.goto('/versions');
  await expect(row(page, CLOSE).getByRole('button', { name: `Edit ${CLOSE}` })).toBeDisabled();
  await expect(row(page, CLOSE).getByTestId('why-not')).toHaveText('A finalized version can only be expired');
  await row(page, CLOSE).getByRole('button', { name: `Expire ${CLOSE}` }).click();
  const dialog = page.getByRole('dialog', { name: `Expire version ${CLOSE}?` });
  await dialog.getByRole('button', { name: 'Expire version' }).click();
  await expect(dialog).toHaveCount(0);
  await page.getByRole('group', { name: 'Version status' }).getByRole('button', { name: 'Expired' }).click();
  await expect(page).toHaveURL(/status=expired/);
  await expect(row(page, CLOSE).getByTestId('version-status')).toContainText('Expired');
  await expect(row(page, CLOSE).getByTestId('why-not')).toHaveText('An expired version cannot be changed');
  await expect(row(page, CLOSE).getByRole('button', { name: `Expire ${CLOSE}` })).toHaveCount(0);
});
