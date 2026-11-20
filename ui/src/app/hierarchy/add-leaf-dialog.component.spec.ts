import { TestBed } from '@angular/core/testing';
import { NexusApi } from '../api/nexus-api';
import type { FormProperty } from '../api/generated/models';
import { TrayStore } from '../change-request/tray.store';
import { DIALOG_DATA, DialogRef } from '../shared/ds';
import { AddLeafDialogComponent } from './add-leaf-dialog.component';

/**
 * Add a child (SLICE-01 S1-R4, ADR-046 D2): properties grouped by category in collapsible sections, and a property for
 * leaves only offered and required only for a leaf. Synthetic properties only.
 */
describe('AddLeafDialogComponent', () => {
  const properties: FormProperty[] = [
    { code: 'SYN_LEDGER', label: 'Ledger', category: 'Finance', required: true, nodeFilter: 'leaf' },
    { code: 'SYN_COUNTRY', label: 'Country', category: 'Finance', required: false, nodeFilter: 'leaf' },
    { code: 'SYN_HOURS', label: 'Weekly hours', category: 'HR', required: false, nodeFilter: 'any' },
    { code: 'SYN_FLAG', label: 'Flag', category: 'Reporting', required: false, nodeFilter: 'any' },
  ];

  async function render() {
    const added: unknown[] = [];
    const checks: Record<string, unknown>[] = [];
    TestBed.configureTestingModule({
      providers: [
        { provide: DIALOG_DATA, useValue: { hierarchyCode: 'SYN_H', parentId: 'p1', parentName: 'Synthetic parent', businessToday: '2031-05-17' } },
        { provide: DialogRef, useValue: { close: () => undefined } },
        { provide: NexusApi, useValue: {
          submitForm: async () => ({ properties }),
          hierarchyRules: async () => [
            { code: 'SYN_ALL', description: 'Codes are at most 5 characters.', severity: 'error', thisHierarchyOnly: false },
            { code: 'SYN_L3', description: 'Level-3 limbs have 2 upper-case letters.', severity: 'error', thisHierarchyOnly: true },
          ],
          checkItem: async (body: Record<string, unknown>) => {
            checks.push(body);
            const name = ((body['item'] as { payload: { name: string } }).payload.name);
            return name.length > 2
              ? { errors: [{ ruleCode: 'SYN_L3', nodeId: 'new', message: `Level-3 limb ${name} must be 2 upper-case letters` }], warnings: [] }
              : { errors: [], warnings: [] };
          },
        } },
        { provide: TrayStore, useValue: {
          hasDraft: () => false, request: () => null,
          addLeaf: async (leaf: unknown) => {
            added.push(leaf);
            return { nodeId: 'n1' };
          },
        } },
      ],
    });
    const fixture = TestBed.createComponent(AddLeafDialogComponent);
    await fixture.whenStable();
    await fixture.whenStable();
    const el = fixture.nativeElement as HTMLElement;
    const c = fixture.componentInstance as unknown as Record<string, any>;
    const section = (category: string) => el.querySelector<HTMLElement>(`fieldset[data-category="${category}"]`);
    const disclosure = (category: string) => section(category)!.querySelector<HTMLButtonElement>('button.disclosure')!;
    return { fixture, el, c, added, checks, section, disclosure };
  }

  it('groups the properties by category; sections without a required field start collapsed', async () => {
    const { el, disclosure } = await render();
    expect([...el.querySelectorAll<HTMLElement>('fieldset[data-category]')].map((f) => f.dataset['category'])).toEqual(['Finance', 'HR', 'Reporting']);
    expect(disclosure('Finance').getAttribute('aria-expanded')).toBe('true');
    expect(disclosure('Finance').textContent).toContain('(2 properties, 1 required)');
    expect(disclosure('HR').getAttribute('aria-expanded')).toBe('false');
    expect(el.querySelector('#nx-add-leaf-SYN_HOURS')).toBeNull();
  });

  it('expands and collapses every section at once', async () => {
    const { fixture, el } = await render();
    el.querySelector<HTMLButtonElement>('[data-testid=expand-all]')!.click();
    await fixture.whenStable();
    expect(el.querySelector('#nx-add-leaf-SYN_HOURS')).not.toBeNull();
    el.querySelector<HTMLButtonElement>('[data-testid=collapse-all]')!.click();
    await fixture.whenStable();
    expect(el.querySelectorAll('fieldset[data-category] ds-field')).toHaveLength(0);
  });

  it('neither offers nor requires a leaf-only property when the node may have children', async () => {
    const { fixture, el, c, added, section } = await render();
    c['form'].controls.name.setValue('Synthetic region');
    c['form'].controls.isLeaf.setValue(false);
    await fixture.whenStable();
    expect(section('Finance')).toBeNull();
    expect(el.querySelector('[data-testid=props-hidden-note]')?.textContent).toContain('leaves only');
    await c['save']();
    expect(added).toHaveLength(1);
    expect((added[0] as { isLeaf: boolean; properties: unknown[] }).isLeaf).toBe(false);
    expect((added[0] as { properties: unknown[] }).properties).toEqual([]);
  });

  it('asks for the code and a display name, and sends both', async () => {
    const { fixture, el, c, added } = await render();
    expect(el.querySelector('label[for=nx-add-leaf-name]')?.textContent).toContain('Code');
    expect(el.querySelector('#nx-add-leaf-displayName')).not.toBeNull();
    c['form'].controls.name.setValue(' SYN01 ');
    c['form'].controls.displayName.setValue(' Synthetic region ');
    c['form'].controls.isLeaf.setValue(false);
    await fixture.whenStable();
    await c['save']();
    expect(added[0]).toMatchObject({ name: 'SYN01', displayName: 'Synthetic region' });
  });

  it('requires a leaf-only property for a leaf, and opens its section to show the error', async () => {
    const { fixture, el, c, added, disclosure } = await render();
    c['form'].controls.name.setValue('Synthetic desk');
    disclosure('Finance').click();
    await fixture.whenStable();
    await c['save']();
    await fixture.whenStable();
    expect(added).toHaveLength(0);
    expect(disclosure('Finance').getAttribute('aria-expanded')).toBe('true');
    expect(el.querySelector('[data-testid=add-leaf-summary]')?.textContent).toContain('Ledger: Required');
  });

  it("lists the hierarchy's rules, this hierarchy's own first", async () => {
    const { el } = await render();
    const rules = [...el.querySelectorAll('.rule-list li')].map((li) => li.textContent!.replace(/\s+/g, ' ').trim());
    expect(rules).toEqual(['SYN_L3 Level-3 limbs have 2 upper-case letters. (this hierarchy)', 'SYN_ALL Codes are at most 5 characters.']);
  });

  it('checks the node as filled in, with its properties, and forgets the result when the form changes', async () => {
    const { fixture, el, c, checks } = await render();
    c['form'].controls.name.setValue('SYNTH');
    c['form'].controls.isLeaf.setValue(false);
    await fixture.whenStable();
    await c['check']();
    await fixture.whenStable();
    expect(checks[0]).toMatchObject({
      versionName: undefined, effectiveFrom: '2031-05-17', properties: [],
      item: { action: 'add_node', hierarchyCode: 'SYN_H', targetParentId: 'p1', payload: { name: 'SYNTH', isLeaf: false } },
    });
    expect(el.querySelector('[data-testid=add-leaf-check-error]')?.textContent).toContain('SYN_L3: Level-3 limb SYNTH must be 2 upper-case letters');

    c['form'].controls.name.setValue('SY');
    await fixture.whenStable();
    expect(el.querySelector('[data-testid=add-leaf-check-error]')).toBeNull();   // the old result is gone
    await c['check']();
    await fixture.whenStable();
    expect(el.querySelector('[data-testid=add-leaf-check-ok]')).not.toBeNull();
  });
});
