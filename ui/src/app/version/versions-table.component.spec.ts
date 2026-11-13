import { TestBed } from '@angular/core/testing';
import type { VersionView } from '../api/generated/models';
import { VersionsTableComponent } from './versions-table.component';

/** The table offers exactly what the server lists on each row; a refused action shows the server's reason (LLD V.6). */
describe('VersionsTableComponent', () => {
  const rows: VersionView[] = [
    { name: 'Synthetic plan', status: 'working', businessAsOf: '2031-05-17', revision: 1,
      transitions: [{ to: 'submitted', allowed: true }], edit: { allowed: true } },
    { name: 'Synthetic close', status: 'submitted', businessAsOf: '2031-04-30', recordedAsOf: '2031-05-01T12:00:00Z', revision: 2,
      transitions: [{ to: 'working', allowed: true },
        { to: 'finalized', allowed: false, whyNot: 'Synthetic: another administrator must finalize' }],
      edit: { allowed: false, whyNot: 'Synthetic: only a working version can be edited' } },
  ];

  async function render(canAdmin: boolean) {
    const fixture = TestBed.createComponent(VersionsTableComponent);
    fixture.componentRef.setInput('rows', rows);
    fixture.componentRef.setInput('canAdmin', canAdmin);
    fixture.componentRef.setInput('timeZone', 'UTC');
    await fixture.whenStable();
    return fixture;
  }

  function buttons(row: Element): HTMLButtonElement[] {
    return [...row.querySelectorAll('button')];
  }

  function texts(list: Element[]): string[] {
    return list.map((b) => (b.textContent ?? '').replace(/\s+/g, ' ').trim());
  }

  it('shows each server transition, disabled with its reason when refused', async () => {
    const el: HTMLElement = (await render(true)).nativeElement;
    const close = el.querySelector('tr[data-version="Synthetic close"]')!;
    const finalize = buttons(close).find((b) => b.textContent?.includes('Finalize'))!;
    expect(finalize.disabled).toBe(true);
    const why = close.querySelector(`#${finalize.getAttribute('aria-describedby')}`)!;
    expect(why.textContent).toContain('another administrator must finalize');
    expect(buttons(close).find((b) => b.textContent?.includes('Reopen'))!.disabled).toBe(false);
    expect(close.textContent).toContain('01 May 2031');   // frozen at, in the business time zone
    const plan = el.querySelector('tr[data-version="Synthetic plan"]')!;
    expect(texts(buttons(plan))).toEqual(['Open picture Synthetic plan', 'Submit Synthetic plan', 'Edit Synthetic plan']);
    expect(plan.textContent).toContain('Not frozen');
  });

  it('offers a viewer only "Open picture"', async () => {
    const el: HTMLElement = (await render(false)).nativeElement;
    expect(texts([...el.querySelectorAll('tbody button')])).toEqual(['Open picture Synthetic plan', 'Open picture Synthetic close']);
    expect(el.querySelectorAll('[data-testid="why-not"]')).toHaveLength(0);
  });

  it('emits the chosen transition with its version', async () => {
    const fixture = await render(true);
    const chosen: unknown[] = [];
    fixture.componentInstance.transition.subscribe((c) => chosen.push(c));
    const plan = (fixture.nativeElement as HTMLElement).querySelector('tr[data-version="Synthetic plan"]')!;
    buttons(plan).find((b) => b.textContent?.includes('Submit'))!.click();
    expect(chosen).toEqual([{ version: rows[0], to: 'submitted' }]);
  });

  it('shows the empty text when there are no versions', async () => {
    const fixture = TestBed.createComponent(VersionsTableComponent);
    fixture.componentRef.setInput('rows', []);
    fixture.componentRef.setInput('emptyText', 'No synthetic versions.');
    await fixture.whenStable();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="versions-empty"]')!.textContent).toContain('No synthetic versions.');
  });
});
