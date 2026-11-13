import { HttpErrorResponse } from '@angular/common/http';
import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { NexusApi } from '../api/nexus-api';
import { VERSIONS_PAGE } from '../core/config';
import { ContextStore } from '../core/context.store';
import { VersionsStore } from './versions.store';

/** Versions page state (Phase 3 LLD V.6): the filter goes to the server, pages chain by cursor, errors stay inline. */
describe('VersionsStore', () => {
  function setup(fail = false) {
    const calls: { status?: string; cursor?: string; limit?: number }[] = [];
    const api = {
      versions: async (status?: string, cursor?: string, limit?: number) => {
        calls.push({ status, cursor, limit });
        if (fail) {
          throw new HttpErrorResponse({ status: 500, error: { detail: 'Synthetic failure' } });
        }
        return cursor
          ? { items: [{ name: 'Synthetic B' }], nextCursor: null }
          : { items: [{ name: 'Synthetic A' }], nextCursor: 'c1' };
      },
      me: async () => ({ businessToday: '2031-05-17' }),
    };
    TestBed.configureTestingModule({ providers: [provideRouter([]), VersionsStore, { provide: NexusApi, useValue: api }] });
    return { store: TestBed.inject(VersionsStore), calls };
  }

  it('sends the status filter, and none for "All"', async () => {
    const { store, calls } = setup();
    await store.load('finalized');
    await store.load('all');
    expect(calls).toEqual([{ status: 'finalized', cursor: undefined, limit: VERSIONS_PAGE },
      { status: undefined, cursor: undefined, limit: VERSIONS_PAGE }]);
    expect(store.filter()).toBe('all');
  });

  it('appends the next page by cursor and stops when there is none', async () => {
    const { store, calls } = setup();
    await store.load('working');
    await store.loadMore();
    await store.loadMore();   // no cursor left: no call
    expect(store.rows().map((r) => r.name)).toEqual(['Synthetic A', 'Synthetic B']);
    expect(calls.map((c) => c.cursor)).toEqual([undefined, 'c1']);
    expect(calls[1].status).toBe('working');
  });

  it('shows the error and clears the rows when loading fails', async () => {
    const { store } = setup(true);
    await store.load('all');
    expect(store.error()?.status).toBe(500);
    expect(store.rows()).toEqual([]);
    expect(store.loading()).toBe(false);
  });

  it('refresh reloads the list, the picker and /me', async () => {
    const { store, calls } = setup();
    await store.load('submitted');
    const context = TestBed.inject(ContextStore);
    await store.refresh();
    expect(calls.map((c) => c.status)).toEqual(['submitted', 'submitted', 'working']);
    expect(context.me()?.businessToday).toBe('2031-05-17');
  });
});
