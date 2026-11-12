import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { NexusApi } from '../api/nexus-api';
import { ContextStore } from './context.store';

/** "Today" comes from the server, never the browser (ADR-018, LLD §3.1). */
describe('ContextStore', () => {
  function setup(businessToday: string) {
    TestBed.configureTestingModule({
      providers: [provideRouter([]), {
        provide: NexusApi,
        useValue: { me: async () => ({ businessToday, workingVersion: 'Synthetic working', permissions: { SYN_H: ['READ', 'PROPOSE'] } }) },
      }],
    });
    return TestBed.inject(ContextStore);
  }

  it('uses the server business date, not the browser clock, to decide "historical"', async () => {
    const store = setup('2031-05-17');   // a date no browser clock in CI will show
    await store.load();
    expect(store.asOf()).toBe('2031-05-17');
    expect(store.isHistorical()).toBe(false);
    store.syncFromUrl('2031-05-17');
    expect(store.isHistorical()).toBe(false);   // the server's today in the URL is not historical
    store.syncFromUrl('2031-05-16');
    expect(store.isHistorical()).toBe(true);
    expect(store.slice()).toEqual({ asOf: '2031-05-16' });
  });

  it('ignores a malformed as-of parameter', async () => {
    const store = setup('2031-05-17');
    await store.load();
    store.syncFromUrl('yesterday');
    expect(store.isHistorical()).toBe(false);
  });

  it('reads permissions per hierarchy as a hint for which controls to offer', async () => {
    const store = setup('2031-05-17');
    await store.load();
    expect(store.can('PROPOSE', 'SYN_H')).toBe(true);
    expect(store.can('DECIDE', 'SYN_H')).toBe(false);
    expect(store.can('PROPOSE', 'OTHER')).toBe(false);
  });
});
