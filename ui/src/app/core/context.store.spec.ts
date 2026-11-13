import { TestBed } from '@angular/core/testing';
import { Router, provideRouter } from '@angular/router';
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

  it('hints property edit rights by category (ADR-036)', async () => {
    TestBed.configureTestingModule({
      providers: [provideRouter([]), {
        provide: NexusApi,
        useValue: { me: async () => ({ businessToday: '2031-05-17', grants: [
          { roleCode: 'VIEWER', hierarchyCode: null },
          { roleCode: 'STEWARD', hierarchyCode: 'SYN_H', categoryCodes: ['Finance'] },
        ] }) },
      }],
    });
    const store = TestBed.inject(ContextStore);
    await store.load();
    expect(store.canEditCategory('SYN_H', 'Finance')).toBe(true);
    expect(store.canEditCategory('SYN_H', 'Legal')).toBe(false);
    expect(store.canEditCategory('SYN_H', null)).toBe(false);   // uncategorised needs an unlimited grant
    expect(store.canEditCategory('OTHER', 'Finance')).toBe(false);
  });

  describe("a version's picture (Phase 3 LLD V.6)", () => {
    function setupVersions(status = 'finalized') {
      const asked: string[] = [];
      const navigations: unknown[] = [];
      TestBed.configureTestingModule({
        providers: [provideRouter([]), {
          provide: NexusApi,
          useValue: {
            me: async () => ({ businessToday: '2031-05-17', businessTimeZone: 'UTC' }),
            version: async (name: string) => {
              asked.push(name);
              return { body: { name, status }, etag: '"1"' };
            },
          },
        }],
      });
      const store = TestBed.inject(ContextStore);
      const router = TestBed.inject(Router);
      router.navigate = (async (commands: unknown, extras: unknown) => {
        navigations.push({ commands, extras });
        return true;
      }) as typeof router.navigate;
      return { store, asked, navigations };
    }

    it('names the version, its status and its pin in the banner, and sends the pin with every read', async () => {
      const { store, asked } = setupVersions();
      await store.load();
      store.syncFromUrl('2031-04-30', '2031-05-01T12:00:00Z', 'Synthetic close');
      await Promise.resolve();
      expect(asked).toEqual(['Synthetic close']);
      expect(store.isHistorical()).toBe(true);
      expect(store.slice()).toEqual({ asOf: '2031-04-30', recordedAsOf: '2031-05-01T12:00:00Z' });
      expect(store.banner()).toBe('Version Synthetic close, finalized: the data on 30 Apr 2031 as recorded at 01 May 2031 12:00 UTC. Read-only.');
    });

    it('treats a recorded time alone as historical, even on today', async () => {
      const { store } = setupVersions();
      await store.load();
      store.syncFromUrl('2031-05-17', '2031-05-16T08:00:00Z');
      expect(store.isHistorical()).toBe(true);
      expect(store.banner()).toContain('as recorded at 16 May 2031 08:00 UTC');
    });

    it('keeps the plain banner for a past date with no version, and ignores a malformed recorded time', async () => {
      const { store, asked } = setupVersions();
      await store.load();
      store.syncFromUrl('2031-05-16', 'not-a-time');
      expect(store.slice()).toEqual({ asOf: '2031-05-16' });
      expect(store.banner()).toContain('You are viewing 16 May 2031, not today.');
      expect(asked).toEqual([]);
    });

    it("opens a picture at the version's date and pin, and leaves it when the date changes", async () => {
      const { store, navigations } = setupVersions();
      await store.load();
      await store.openPicture({ name: 'Synthetic close', businessAsOf: '2031-04-30', recordedAsOf: '2031-05-01T12:00:00Z' });
      await store.setAsOf('2031-05-10');
      expect(navigations).toEqual([
        { commands: ['/hierarchies'], extras: expect.objectContaining({
          queryParams: { asOf: '2031-04-30', recordedAsOf: '2031-05-01T12:00:00Z', version: 'Synthetic close' } }) },
        { commands: [], extras: expect.objectContaining({ queryParams: { asOf: '2031-05-10', recordedAsOf: null, version: null } }) },
      ]);
    });
  });

  it('reads permissions per hierarchy as a hint for which controls to offer', async () => {
    const store = setup('2031-05-17');
    await store.load();
    expect(store.can('PROPOSE', 'SYN_H')).toBe(true);
    expect(store.can('DECIDE', 'SYN_H')).toBe(false);
    expect(store.can('PROPOSE', 'OTHER')).toBe(false);
  });
});
