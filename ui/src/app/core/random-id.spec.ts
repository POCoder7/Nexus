import { HttpRequest, HttpResponse } from '@angular/common/http';
import { firstValueFrom, of } from 'rxjs';
import { correlationIdInterceptor } from './http/interceptors';
import { randomId, tryRandomId } from './random-id';

const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

/** Pages served over plain HTTP have no crypto.randomUUID (not a secure context); requests must still go out. */
describe('randomId', () => {
  const real = globalThis.crypto;

  afterEach(() => vi.unstubAllGlobals());

  /** A crypto as an insecure page has it: getRandomValues, no randomUUID. */
  function insecureCrypto(): void {
    vi.stubGlobal('crypto', { getRandomValues: real.getRandomValues.bind(real) });
  }

  it('uses crypto.randomUUID when the page is a secure context', () => {
    vi.stubGlobal('crypto', { randomUUID: () => '11111111-1111-4111-8111-111111111111' });
    expect(randomId()).toBe('11111111-1111-4111-8111-111111111111');
  });

  it('builds a version 4 UUID from getRandomValues on a plain HTTP page', () => {
    insecureCrypto();
    const ids = new Set(Array.from({ length: 200 }, () => randomId()));
    expect(ids.size).toBe(200);
    for (const id of ids) {
      expect(id).toMatch(UUID_V4);
    }
  });

  it('sends a correlation id from the fallback, and sends the request without one if there is no crypto at all', async () => {
    const sent: HttpRequest<unknown>[] = [];
    const next = (r: HttpRequest<unknown>) => {
      sent.push(r);
      return of(new HttpResponse({ status: 200 }));
    };
    insecureCrypto();
    await firstValueFrom(correlationIdInterceptor(new HttpRequest('GET', '/api/v1/me'), next));
    expect(sent[0].headers.get('X-Correlation-Id')).toMatch(UUID_V4);

    vi.stubGlobal('crypto', undefined);
    expect(tryRandomId()).toBeNull();
    await firstValueFrom(correlationIdInterceptor(new HttpRequest('GET', '/api/v1/me'), next));
    expect(sent).toHaveLength(2);
    expect(sent[1].headers.has('X-Correlation-Id')).toBe(false);   // the server makes one
  });
});
