import { TestBed } from '@angular/core/testing';
import type { VersionView } from '../api/generated/models';
import { VersionPickerComponent } from './version-picker.component';

/** The context-bar working-version picker (LLD V.6): names each version with its date and keeps the current choice listed. */
describe('VersionPickerComponent', () => {
  const working: VersionView[] = [{ name: 'Synthetic A', businessAsOf: '2031-05-17' }, { name: 'Synthetic B', businessAsOf: '2031-06-30' }];

  async function render(value: string | null, versions: VersionView[] = working) {
    const fixture = TestBed.createComponent(VersionPickerComponent);
    fixture.componentRef.setInput('versions', versions);
    fixture.componentRef.setInput('value', value);
    await fixture.whenStable();
    return fixture;
  }

  it('lists working versions with their business dates and selects the current one', async () => {
    const el: HTMLElement = (await render('Synthetic B')).nativeElement;
    const select = el.querySelector('select')!;
    expect([...select.options].map((o) => o.textContent?.trim())).toEqual(['Synthetic A (17 May 2031)', 'Synthetic B (30 Jun 2031)']);
    expect(select.value).toBe('Synthetic B');
    expect(el.querySelector('label')!.getAttribute('for')).toBe(select.id);
  });

  it('keeps the current choice listed when it is not on the first page', async () => {
    const el: HTMLElement = (await render('Synthetic Z')).nativeElement;
    expect([...el.querySelector('select')!.options].map((o) => o.value)).toEqual(['Synthetic Z', 'Synthetic A', 'Synthetic B']);
  });

  it('emits only a change of choice', async () => {
    const fixture = await render('Synthetic A');
    const chosen: string[] = [];
    fixture.componentInstance.chosen.subscribe((n) => chosen.push(n));
    const select: HTMLSelectElement = fixture.nativeElement.querySelector('select');
    select.value = 'Synthetic A';
    select.dispatchEvent(new Event('change'));
    select.value = 'Synthetic B';
    select.dispatchEvent(new Event('change'));
    expect(chosen).toEqual(['Synthetic B']);
  });

  it('says so when there is no working version', async () => {
    const el: HTMLElement = (await render(null, [])).nativeElement;
    expect(el.querySelector('select')).toBeNull();
    expect(el.querySelector('[data-testid="context-version"]')!.textContent).toContain('No working version');
  });
});
