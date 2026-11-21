import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { signal } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { DevIdentity } from './dev-identity.providers';
import { DevUserPickerComponent } from './dev-user-picker.component';

/** The development user picker is a plain dropdown of the database's users (owner, 2026-11-20). Synthetic logins. */
describe('DevUserPickerComponent', () => {
  function render(current: string | null) {
    TestBed.configureTestingModule({
      providers: [provideHttpClient(), provideHttpClientTesting(),
        { provide: DevIdentity, useValue: { login: signal(current), set: () => undefined } }],
    });
    const fixture = TestBed.createComponent(DevUserPickerComponent);
    fixture.detectChanges();
    TestBed.inject(HttpTestingController).expectOne('/api/v1/dev/users')
      .flush([{ login: 'syn_editor', displayName: 'Synthetic Editor' }, { login: 'syn_admin', displayName: 'Synthetic Admin' }]);
    fixture.detectChanges();
    return fixture.nativeElement as HTMLElement;
  }

  it('is a labelled dropdown with no text box or Switch user button', () => {
    const el = render('syn_admin');
    const select = el.querySelector<HTMLSelectElement>('select#nx-dev-user')!;
    expect(el.querySelector('label[for=nx-dev-user]')?.textContent).toContain('Development user');
    expect(el.querySelector('input')).toBeNull();
    expect(el.querySelector('button')).toBeNull();
    expect([...select.options].map((o) => o.textContent?.trim())).toEqual(['Synthetic Editor (syn_editor)', 'Synthetic Admin (syn_admin)']);
    expect(select.value).toBe('syn_admin');
  });

  it('keeps the current login listed when the database does not offer it, and asks for a choice when there is none', () => {
    expect([...render('syn_other').querySelectorAll('option')].map((o) => o.value)).toEqual(['syn_other', 'syn_editor', 'syn_admin']);
    TestBed.resetTestingModule();
    const first = render(null).querySelector('option')!;
    expect(first.textContent).toContain('Choose a user');
    expect(first.disabled).toBe(true);
  });
});
