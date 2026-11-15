import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { NexusApi } from '../api/nexus-api';
import type { QueryDefinition } from '../api/generated/models';
import { ContextStore } from '../core/context.store';
import { QueryStore } from './query.store';

/** The Queries page store (QRY-01, Phase 5 LLD §17.12) against a fake API. Synthetic names only. */
describe('QueryStore', () => {
  function setup() {
    const runs: { definition: QueryDefinition; asOf?: string; cursor?: string }[] = [];
    const saves: string[] = [];
    const pages = [
      { items: [{ nodeId: 'n1', name: 'Syn 1' }], nextCursor: 'c1', scanned: 7, partial: true },
      { items: [{ nodeId: 'n2', name: 'Syn 2' }], nextCursor: undefined, scanned: 3, partial: false },
    ];
    const api = {
      hierarchies: async () => ({ items: [{ code: 'SYN_H', name: 'Synthetic' }] }),
      propertyDefinitions: async () => ({ items: [{ code: 'SYN.Amt', label: 'Amount', dataType: 'integer' }] }),
      savedQueries: async () => ({ items: [] }),
      runQuery: async (definition: QueryDefinition, asOf: string | undefined, cursor: string | undefined) => {
        runs.push({ definition, asOf, cursor });
        return pages[runs.length - 1];
      },
      saveQuery: async () => {
        saves.push('create');
        return { body: { id: 'q1', name: 'Mine', mine: true, rowVersion: 1 }, etag: '"1"' };
      },
      updateSavedQuery: async (_id: string, etag: string) => {
        saves.push(`update ${etag}`);
        return { body: { id: 'q1', name: 'Mine', mine: true, rowVersion: 2 }, etag: '"2"' };
      },
    };
    TestBed.configureTestingModule({ providers: [provideRouter([]), QueryStore, { provide: NexusApi, useValue: api }] });
    TestBed.inject(ContextStore).me.set({ businessToday: '2031-05-17' });
    return { store: TestBed.inject(QueryStore), runs, saves };
  }

  it('says a page stopped at the scan budget is partial, and Continue carries on from its cursor', async () => {
    const { store, runs } = setup();
    await store.load();
    expect(store.hierarchyCode()).toBe('SYN_H');
    await store.run();
    expect(store.partial()).toBe(true);
    expect(store.hasMore()).toBe(true);
    await store.more();
    expect(runs.map((r) => r.cursor)).toEqual([undefined, 'c1']);
    expect(store.rows().map((r) => r.name)).toEqual(['Syn 1', 'Syn 2']);
    expect(store.scanned()).toBe(10);
    expect(store.partial()).toBe(false);
    expect(store.hasMore()).toBe(false);
  });

  it('reads at the server\'s today unless the context bar shows another date', async () => {
    const { store, runs } = setup();
    await store.load();
    await store.run();
    expect(runs[0].asOf).toBeUndefined();
    TestBed.inject(ContextStore).syncFromUrl('2031-01-31');
    await store.run();
    expect(runs[1].asOf).toBe('2031-01-31');
    expect(runs[1].definition.hierarchyCode).toBe('SYN_H');
  });

  it('creates a saved query once, then updates it with its ETag', async () => {
    const { store, saves } = setup();
    await store.load();
    await store.save('Mine', false, false);
    await store.save('Mine', true, false);
    expect(saves).toEqual(['create', 'update "1"']);
    expect(store.current()?.rowVersion).toBe(2);
  });
});
