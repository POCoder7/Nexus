import { TestBed } from '@angular/core/testing';
import type { PropertyValue } from '../api/generated/models';
import { PropertyGridComponent } from './property-grid.component';

/** HIE-12 property grid: provenance as icon + text, inherited source link, grouping and grid keyboard (LLD §3.3). */
describe('PropertyGridComponent', () => {
  const props: PropertyValue[] = [
    { code: 'T.Ccy', label: 'Currency', category: 'Finance', provenance: 'inherited', value: 'EUR' as never, sourceNodeId: 'top' },
    { code: 'T.Seg', label: 'Segment', category: 'Finance', provenance: 'default', value: 'Unassigned' as never },
    { code: 'T.Own', label: 'Owner', category: 'Admin', provenance: 'stored', value: 'Synthetic desk' as never },
    { code: 'T.Calc', label: 'Calculated', category: 'Admin', provenance: 'derived', value: 3 as never },
    { code: 'T.None', label: 'Unset', category: 'Admin', provenance: 'none' },
  ];

  async function render() {
    const fixture = TestBed.createComponent(PropertyGridComponent);
    fixture.componentRef.setInput('properties', props);
    fixture.componentRef.setInput('nodeName', 'Synthetic node');
    fixture.componentRef.setInput('sourceNames', { top: 'Synthetic top' });
    await fixture.whenStable();
    return fixture;
  }

  it('shows each value with its provenance in words', async () => {
    const el: HTMLElement = (await render()).nativeElement;
    const marker = (code: string) => el.querySelector(`[data-property="${code}"] [data-testid=provenance]`)!.textContent!.replace(/\s+/g, ' ').trim();
    expect(marker('T.Ccy')).toContain('Inherited from Synthetic top');
    expect(marker('T.Seg')).toContain('Default');
    expect(marker('T.Own')).toContain('Stored here');
    expect(marker('T.Calc')).toContain('Derived');
    expect(el.querySelector('[data-property="T.None"] .value')!.textContent).toContain('Not set');
  });

  it('groups by category and links an inherited value to its source node', async () => {
    const fixture = await render();
    const el: HTMLElement = fixture.nativeElement;
    expect([...el.querySelectorAll('tbody .group th')].map((g) => g.textContent?.trim())).toEqual(['Admin', 'Finance']);
    const opened: string[] = [];
    fixture.componentInstance.openSource.subscribe((id) => opened.push(id));
    (el.querySelector('[data-property="T.Ccy"] button') as HTMLButtonElement).click();
    expect(opened).toEqual(['top']);
  });

  it('offers Edit on every value except derived ones when editable, and emits the property', async () => {
    const fixture = await render();
    expect(fixture.nativeElement.querySelectorAll('button.edit')).toHaveLength(0);   // read-only by default
    fixture.componentRef.setInput('editable', true);
    await fixture.whenStable();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-property="T.Calc"] button.edit')).toBeNull();
    expect(el.querySelectorAll('button.edit')).toHaveLength(4);
    const edited: string[] = [];
    fixture.componentInstance.edit.subscribe((p) => edited.push(p.code!));
    (el.querySelector('[data-property="T.Own"] button.edit') as HTMLButtonElement).click();
    expect(edited).toEqual(['T.Own']);
  });

  it('is a labelled grid with arrow-key movement between cells', async () => {
    const el: HTMLElement = (await render()).nativeElement;
    const grid = el.querySelector('[role=grid]')!;
    expect(grid.getAttribute('aria-label')).toBe('Properties of Synthetic node');
    const first = el.querySelector<HTMLElement>('[role=columnheader]')!;
    first.focus();
    first.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }));
    expect(document.activeElement?.textContent?.trim()).toBe('Value');
    (document.activeElement as HTMLElement).dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }));
    expect(document.activeElement?.getAttribute('role')).toBe('gridcell');
  });
});
