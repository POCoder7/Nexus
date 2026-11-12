import { TestBed } from '@angular/core/testing';
import { NexusApi } from '../api/nexus-api';
import { FakeTree, leaves } from '../testing/fake-api';
import { HierarchyStore } from './hierarchy.store';

/** HIE-12 tree state (LLD §7.1, §7.2) against a fake API with synthetic data. */
describe('HierarchyStore', () => {
  function setup(tree: FakeTree) {
    const api = {
      hierarchy: async (code: string) => ({ code, name: 'Synthetic', topNodeId: 'top', topNodeName: 'Top' }),
      children: async (_c: string, parentId: string, _s: unknown, cursor: string | undefined, limit: number) => tree.page(parentId, cursor, limit),
      path: async (_c: string, nodeId: string) => ({ path: tree.path(nodeId) }),
    };
    TestBed.configureTestingModule({ providers: [HierarchyStore, { provide: NexusApi, useValue: api }] });
    return TestBed.inject(HierarchyStore);
  }

  it('flattens the open tree and adds a "show next" row on a partial page', async () => {
    const tree = new FakeTree({ top: [{ nodeId: 'p', name: 'Parent', hasChildren: true, primary: true }], p: leaves('Leaf', 450) });
    const store = setup(tree);
    await store.open('H', {});
    expect(store.visibleRows().map((r) => r.kind)).toEqual(['node', 'node']);   // top expanded, Parent collapsed

    await store.expand('p');
    const rows = store.visibleRows();
    expect(rows.filter((r) => r.kind === 'node')).toHaveLength(2 + 200);
    expect(rows.at(-1)?.kind).toBe('more');

    await store.loadPage('p');
    await store.loadPage('p');
    const after = store.visibleRows();
    expect(after.filter((r) => r.kind === 'node')).toHaveLength(2 + 450);
    expect(after.some((r) => r.kind === 'more')).toBe(false);   // page boundary: no "show next" after the last page
    expect(tree.calls.filter((c) => c.parentId === 'p').map((c) => c.cursor)).toEqual([undefined, '200', '400']);
  });

  it('marks shared placements and shows an empty row for a parent without children', async () => {
    const tree = new FakeTree({
      top: [{ nodeId: 'a', name: 'A', hasChildren: true, primary: true }, { nodeId: 's', name: 'Shared', hasChildren: false, primary: false }],
      a: [],
    });
    const store = setup(tree);
    await store.open('H', {});
    await store.expand('a');
    const shared = store.visibleRows().find((r) => r.kind === 'node' && r.id === 's');
    expect(shared && shared.kind === 'node' && shared.shared).toBe(true);
    expect(store.visibleRows().some((r) => r.kind === 'empty' && r.parentId === 'a')).toBe(true);
  });

  it('shows an error row when a page fails and loads it on retry', async () => {
    const tree = new FakeTree({ top: [{ nodeId: 'p', name: 'Parent', hasChildren: true, primary: true }], p: leaves('Leaf', 3) });
    const store = setup(tree);
    await store.open('H', {});
    tree.failNext = true;
    await store.expand('p');
    expect(store.visibleRows().at(-1)?.kind).toBe('error');
    await store.loadPage('p');
    expect(store.visibleRows().filter((r) => r.kind === 'node')).toHaveLength(5);
  });

  it('reveals a node eight levels down by expanding its primary path', async () => {
    const chain: Record<string, { nodeId: string; name: string; hasChildren: boolean; primary: boolean }[]> = {};
    const path = [{ nodeId: 'top', name: 'Top' }];
    let parent = 'top';
    for (let i = 1; i <= 8; i++) {
      chain[parent] = [{ nodeId: `l${i}`, name: `Level ${i}`, hasChildren: i < 8, primary: true }];
      path.push({ nodeId: `l${i}`, name: `Level ${i}` });
      parent = `l${i}`;
    }
    const tree = new FakeTree(chain, { l8: path });
    const store = setup(tree);
    await store.open('H', {});
    expect(await store.reveal('l8')).toBe(true);
    expect(store.selectedId()).toBe('l8');
    const target = store.visibleRows().find((r) => r.kind === 'node' && r.id === 'l8');
    expect(target?.depth).toBe(8);
  });

  it('pins a search result under its parent beyond five pages instead of loading everything', async () => {
    const many = leaves('Bulk', 2000, 'b');
    const tree = new FakeTree({ top: [{ nodeId: 'b', name: 'Bulk', hasChildren: true, primary: true }], b: many },
      { 'b-1900': [{ nodeId: 'top', name: 'Top' }, { nodeId: 'b', name: 'Bulk' }, { nodeId: 'b-1900', name: 'Bulk 1900' }] });
    const store = setup(tree);
    await store.open('H', {});
    await store.reveal('b-1900');
    expect(tree.calls.filter((c) => c.parentId === 'b')).toHaveLength(5);
    const pinned = store.visibleRows().find((r) => r.kind === 'node' && r.id === 'b-1900');
    expect(pinned && pinned.kind === 'node' && pinned.pinned).toBe(true);
  });

  it('starts again when the slice changes (cache per as-of date)', async () => {
    const tree = new FakeTree({ top: leaves('Leaf', 2, 'top') });
    const store = setup(tree);
    await store.open('H', {});
    await store.open('H', { asOf: '2026-01-01' });
    expect(tree.calls.filter((c) => c.parentId === 'top')).toHaveLength(2);
  });
});
