import { TestBed } from '@angular/core/testing';
import { NexusApi } from '../api/nexus-api';
import { FakeTree, leaves } from '../testing/fake-api';
import { AllHierarchiesStore, ROOT_ID, parseRowId, rowId } from './all-hierarchies.store';

/** Phase 5 LLD §20: every hierarchy in one tree under the version, each opened only when expanded (synthetic data). */
describe('AllHierarchiesStore', () => {
  function setup(fail: string | null = null) {
    const trees: Record<string, FakeTree> = {
      SYN_A: new FakeTree({ topA: [{ nodeId: 'shared', name: 'Shared node', hasChildren: false, primary: true }] }),
      SYN_B: new FakeTree({ topB: [{ nodeId: 'shared', name: 'Shared node', hasChildren: false, primary: true }, ...leaves('Leaf', 3)] }),
    };
    const opened: string[] = [];
    const api = {
      hierarchies: async () => ({ items: [
        { code: 'SYN_A', name: 'Synthetic A', topNodeId: 'topA', topNodeName: 'Top A' },
        { code: 'SYN_B', name: 'Synthetic B', topNodeId: 'topB', topNodeName: 'Top B' },
      ] }),
      hierarchy: async (code: string) => {
        opened.push(code);
        if (code === fail) {
          throw new Error('synthetic failure');
        }
        return { code, name: code, topNodeId: code === 'SYN_A' ? 'topA' : 'topB', topNodeName: 'Top' };
      },
      children: async (code: string, parentId: string, _s: unknown, cursor: string | undefined, limit: number) =>
        trees[code].page(parentId, cursor, limit),
    };
    TestBed.configureTestingModule({ providers: [AllHierarchiesStore, { provide: NexusApi, useValue: api }] });
    const store = TestBed.inject(AllHierarchiesStore);
    store.rootLabel.set('FY Working (Working) · as of 17 Nov 2026');
    return { store, opened };
  }

  it('shows the version as the root and the readable hierarchies below it, without opening any', async () => {
    const { store, opened } = setup();
    await store.load({});
    const rows = store.visibleRows();
    expect(rows.map((r) => (r.kind === 'node' ? `${r.depth}:${r.name}` : r.kind))).toEqual([
      '0:FY Working (Working) · as of 17 Nov 2026', '1:Synthetic A (SYN_A)', '1:Synthetic B (SYN_B)']);
    expect(rows[1].kind === 'node' && rows[1].expanded).toBe(false);
    expect(opened).toEqual([]);
  });

  it('opens a hierarchy on first expand and keys its rows by hierarchy, so a shared node is two rows', async () => {
    const { store, opened } = setup();
    await store.load({});
    await store.expand(rowId('SYN_A', 'topA'));
    await store.expand(rowId('SYN_B', 'topB'));
    const nodes = store.visibleRows().filter((r) => r.kind === 'node');
    const shared = nodes.filter((r) => r.kind === 'node' && r.name === 'Shared node');
    expect(shared.map((r) => r.id)).toEqual(['SYN_A|shared', 'SYN_B|shared']);
    expect(shared.every((r) => r.depth === 2)).toBe(true);
    expect(new Set(nodes.map((r) => r.key)).size).toBe(nodes.length);   // keys stay unique across hierarchies
    expect(opened).toEqual(['SYN_A', 'SYN_B']);

    store.collapse(rowId('SYN_A', 'topA'));
    await store.expand(rowId('SYN_A', 'topA'));
    expect(opened).toEqual(['SYN_A', 'SYN_B']);   // reopening uses the tree already loaded
  });

  it('collapses the root, and the version row selects nothing', async () => {
    const { store } = setup();
    await store.load({});
    store.select(ROOT_ID);
    expect(store.selection()).toBeNull();
    store.select(rowId('SYN_B', 'topB'));
    expect(store.selection()).toEqual({ code: 'SYN_B', nodeId: 'topB' });
    expect(store.isTop('SYN_B', 'topB')).toBe(true);
    store.collapse(ROOT_ID);
    expect(store.visibleRows()).toHaveLength(1);
  });

  it('shows a failed hierarchy as an error row under it, and retries it', async () => {
    const { store, opened } = setup('SYN_A');
    await store.load({});
    await store.expand(rowId('SYN_A', 'topA'));
    const error = store.visibleRows().find((r) => r.kind === 'error');
    expect(error?.parentId).toBe('SYN_A|topA');
    await store.loadMore('SYN_A|topA');
    expect(opened).toEqual(['SYN_A', 'SYN_A']);
  });

  it('parses row ids, including node ids that contain no separator', () => {
    expect(parseRowId('SYN_A|n1')).toEqual({ code: 'SYN_A', nodeId: 'n1' });
    expect(parseRowId(ROOT_ID)).toBeNull();
  });
});
