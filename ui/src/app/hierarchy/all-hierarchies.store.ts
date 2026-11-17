import { Injectable, Injector, computed, inject, signal } from '@angular/core';
import { NexusApi, Slice } from '../api/nexus-api';
import type { HierarchySummary } from '../api/generated/models';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { HierarchyStore } from './hierarchy.store';
import { FlatTreeRow } from './tree.model';

/** The id of the version row at the root of the tree. */
export const ROOT_ID = 'version';

/** A row id below the root: the hierarchy code and the node id, so the same node in two hierarchies is two rows. */
export function rowId(code: string, nodeId: string): string {
  return `${code}|${nodeId}`;
}

export function parseRowId(id: string): { code: string; nodeId: string } | null {
  const bar = id.indexOf('|');
  return bar > 0 ? { code: id.slice(0, bar), nodeId: id.slice(bar + 1) } : null;
}

/**
 * Every hierarchy in one tree under a version (Phase 5 LLD §20; HIE-12). The hierarchies the user may read are level 1;
 * each one's tree is the workspace's `HierarchyStore`, created and opened the first time its row is expanded, so nothing
 * is loaded for a hierarchy nobody opens. Its rows are re-keyed with the hierarchy code and shifted one level down.
 */
@Injectable()
export class AllHierarchiesStore {
  private readonly api = inject(NexusApi);
  private readonly injector = inject(Injector);

  readonly hierarchies = signal<HierarchySummary[]>([]);
  readonly loading = signal(false);
  readonly error = signal<UiError | null>(null);
  readonly rootExpanded = signal(true);
  /** Hierarchies whose row is expanded. Their stores are kept when collapsed, so reopening costs nothing. */
  readonly open = signal(new Set<string>());
  readonly selectedId = signal<string | null>(null);
  /** The root row's label (the version, its status and date); set by the page. */
  readonly rootLabel = signal('');
  private readonly stores = signal(new Map<string, HierarchyStore>());
  private slice: Slice = {};
  private generation = 0;

  readonly visibleRows = computed<FlatTreeRow[]>(() => {
    const rows: FlatTreeRow[] = [];
    const list = this.hierarchies();
    const expanded = this.rootExpanded();
    rows.push({ kind: 'node', key: ROOT_ID, id: ROOT_ID, parentId: null, name: this.rootLabel(), depth: 0,
      hasChildren: true, expanded, shared: false, active: true, pinned: false, changed: false });
    if (!expanded) {
      return rows;
    }
    if (this.loading()) {
      rows.push({ kind: 'loading', key: `${ROOT_ID}#loading`, parentId: ROOT_ID, depth: 1 });
      return rows;
    }
    if (this.error()) {
      rows.push({ kind: 'error', key: `${ROOT_ID}#error`, parentId: ROOT_ID, depth: 1, message: this.error()!.detail });
      return rows;
    }
    if (list.length === 0) {
      rows.push({ kind: 'empty', key: `${ROOT_ID}#empty`, parentId: ROOT_ID, depth: 1 });
      return rows;
    }
    const open = this.open();
    const stores = this.stores();
    for (const h of list) {
      const code = h.code ?? '';
      const top = h.topNodeId ?? '';
      const id = rowId(code, top);
      const label = STRINGS.browse.hierarchyRow(h.name ?? code, code);
      const store = stores.get(code);
      const sub = open.has(code) && store ? store.visibleRows() : [];
      if (!open.has(code) || !store || sub.length === 0) {
        rows.push({ kind: 'node', key: id, id, parentId: ROOT_ID, name: label, depth: 1, hasChildren: true,
          expanded: open.has(code), shared: false, active: true, pinned: false, changed: false });
        if (open.has(code)) {
          const err = store?.error();
          rows.push(err
            ? { kind: 'error', key: `${id}#error`, parentId: id, depth: 2, message: err.detail }
            : { kind: 'loading', key: `${id}#loading`, parentId: id, depth: 2 });
        }
        continue;
      }
      for (const r of sub) {
        const key = `${code}/${r.key}`;
        const parentId = r.parentId === null ? ROOT_ID : rowId(code, r.parentId);
        if (r.kind === 'node') {
          const isTop = r.parentId === null;
          rows.push({ ...r, key, id: rowId(code, r.id), parentId, depth: r.depth + 1, name: isTop ? label : r.name });
        } else {
          rows.push({ ...r, key, parentId, depth: r.depth + 1 });
        }
      }
    }
    return rows;
  });

  /** The hierarchy and node of the selection, or null (nothing, or the version row). */
  readonly selection = computed(() => {
    const id = this.selectedId();
    return id ? parseRowId(id) : null;
  });

  /** Loads the readable hierarchies for a slice (every page; there are tens, not thousands) and forgets opened trees. */
  async load(slice: Slice): Promise<void> {
    const generation = ++this.generation;
    this.slice = slice;
    this.stores.set(new Map());
    this.open.set(new Set());
    this.selectedId.set(null);
    this.error.set(null);
    this.loading.set(true);
    try {
      const all: HierarchySummary[] = [];
      let cursor: string | undefined;
      do {
        const page = await this.api.hierarchies(slice, cursor);
        all.push(...(page.items ?? []));
        cursor = page.nextCursor ?? undefined;
      } while (cursor && generation === this.generation);
      if (generation === this.generation) {
        this.hierarchies.set(all);
      }
    } catch (e) {
      if (generation === this.generation) {
        this.error.set(UiError.from(e));
      }
    } finally {
      if (generation === this.generation) {
        this.loading.set(false);
      }
    }
  }

  async expand(id: string): Promise<void> {
    if (id === ROOT_ID) {
      this.rootExpanded.set(true);
      return;
    }
    const ref = parseRowId(id);
    if (!ref) {
      return;
    }
    if (this.isTop(ref.code, ref.nodeId)) {
      this.open.update((s) => new Set(s).add(ref.code));
      if (!this.stores().has(ref.code)) {
        await this.openHierarchy(ref.code);
      }
      return;
    }
    await this.stores().get(ref.code)?.expand(ref.nodeId);
  }

  collapse(id: string): void {
    if (id === ROOT_ID) {
      this.rootExpanded.set(false);
      return;
    }
    const ref = parseRowId(id);
    if (!ref) {
      return;
    }
    if (this.isTop(ref.code, ref.nodeId)) {
      this.open.update((s) => {
        const next = new Set(s);
        next.delete(ref.code);
        return next;
      });
      return;
    }
    this.stores().get(ref.code)?.collapse(ref.nodeId);
  }

  /** "Show next" or a retry: the root's list, a hierarchy that failed to open, or a parent's next page. */
  async loadMore(parentId: string): Promise<void> {
    if (parentId === ROOT_ID) {
      await this.load(this.slice);
      return;
    }
    const ref = parseRowId(parentId);
    if (!ref) {
      return;
    }
    const store = this.stores().get(ref.code);
    if (this.isTop(ref.code, ref.nodeId) && store?.error()) {
      await this.openHierarchy(ref.code);
      return;
    }
    await store?.loadPage(ref.nodeId);
  }

  /** The version row is not a node: selecting it selects nothing. */
  select(id: string): void {
    this.selectedId.set(id === ROOT_ID ? null : id);
  }

  /** Expandable children of a parent, as row ids (for the `*` key). */
  siblingsOf(parentId: string | null): string[] {
    if (parentId === ROOT_ID) {
      return this.hierarchies().map((h) => rowId(h.code ?? '', h.topNodeId ?? ''));
    }
    const ref = parentId ? parseRowId(parentId) : null;
    const store = ref ? this.stores().get(ref.code) : undefined;
    return ref && store ? store.siblingsOf(ref.nodeId).map((n) => rowId(ref.code, n)) : [];
  }

  /** The hierarchy's top node, if the selection is one (the node panel says so). */
  isTop(code: string, nodeId: string): boolean {
    return this.hierarchies().some((h) => h.code === code && h.topNodeId === nodeId);
  }

  private async openHierarchy(code: string): Promise<void> {
    const store = Injector.create({ providers: [HierarchyStore], parent: this.injector }).get(HierarchyStore);
    this.stores.update((m) => new Map(m).set(code, store));
    await store.open(code, this.slice);
  }
}
