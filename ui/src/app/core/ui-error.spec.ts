import { HttpErrorResponse, HttpHeaders } from '@angular/common/http';
import { STRINGS } from './strings';
import { UiError } from './ui-error';

/** Problem Details → what a screen shows (LLD §3.1). */
describe('UiError', () => {
  it('keeps the server words, code, field errors and correlation id', () => {
    const e = UiError.from(new HttpErrorResponse({
      status: 400,
      error: { title: 'Bad Request', detail: 'Invalid item', code: 'x.y', correlationId: 'c-1',
        errors: [{ field: 'payload.name', message: 'is required' }] },
    }));
    expect(e).toMatchObject({ status: 400, detail: 'Invalid item', code: 'x.y', correlationId: 'c-1' });
    expect(e.fieldErrors).toEqual([{ field: 'payload.name', message: 'is required' }]);
  });

  it('explains 412 in plain words', () => {
    expect(UiError.from(new HttpErrorResponse({ status: 412, error: { detail: 'Row version mismatch' } })).detail).toBe(STRINGS.errors.stale);
  });

  it('never shows server internals for 5xx, but keeps the reference', () => {
    const e = UiError.from(new HttpErrorResponse({ status: 500, error: { detail: 'NullPointerException at …' },
      headers: new HttpHeaders({ 'X-Correlation-Id': 'c-2' }) }));
    expect(e.detail).toBe(STRINGS.errors.generic);
    expect(e.correlationId).toBe('c-2');
  });

  it('says when the server cannot be reached', () => {
    expect(UiError.from(new HttpErrorResponse({ status: 0 })).detail).toBe(STRINGS.errors.network);
  });
});
