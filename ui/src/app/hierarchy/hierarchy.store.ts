import { Injectable, computed, inject, signal } from '@angular/core';
import { NexusApi, Slice } from '../api/nexus-api';
import type { HierarchySummary } from '../api/generated/models';
import { CHILDREN_PAGE, REVEAL_MAX_PAGES } from '../core/config';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { ChildrenState, FlatTreeRow, TreeNode } from './tree.model';

/**
 * State of one open hierarchy (LLD §3.2, §7.1): nodes, children pages per parent, the expanded set and the selection,
 * for one slice (as-of date and recorded time). Pages are cached for the session per slice (P-21); changing the slice
 * starts again. `visibleRows` is recomputed only when these change and costs O(visible rows): the virtual viewport then
 * renders only the rows in view, so tens of thousands of loaded siblings stay cheap.
 */
@Injectable()
export class HierarchyStore {
  private readonly api = inject(NexusApi);

  readonly hierarchy = signal<HierarchySummary | null>(null);
  readonly error = signal<UiError | null>(null);
  readonly nodes = signal(new Map<string, TreeNode>());
  readonly children = signal(new Map<string, ChildrenState>());
  readonly expanded = signal(new Set<string>());
  readonly selectedId = signal<string | null>(null);
  private slice: Slice = {};
  private generation = 0;   // ignores responses that belong to a previous slice

  readonly topId = computed(() => this.hierarchy()?.topNodeId ?? null);

  readonly visibleRows = computed<FlatTreeRow[]>(() => {
    const top = this.topId();
    const nodes = this.nodes();
    const children = this.children();
    const expanded = this.expanded();
    const rows: FlatTreeRow[] = [];
    if (!top || !nodes.has(top)) {
      return rows;
    }
    const walk = (id: string, parentId: string | null, depth: number, shared: boolean, pinned: boolean, key: string) => {
      const n = nodes.get(id)!;
      const isExpanded = expanded.has(id);
      rows.push({ kind: 'node', key, id, parentId, name: n.name, depth, hasChildren: n.hasChildren, expanded: isExpanded,
        shared, active: n.active, pinned });
      if (!isExpanded) {
        return;
      }
      const c = children.get(id);
      if (!c) {
        return;
      }
      for (const p of c.placements) {
        walk(p.id, id, depth + 1, p.shared, false, `${key}/${p.id}`);
      }
      for (const pinnedId of c.pinned) {
        if (nodes.has(pinnedId)) {
          walk(pinnedId, id, depth + 1, false, true, `${key}/pin:${pinnedId}`);
        }
      }
      if (c.loading) {
        rows.push({ kind: 'loading', key: `${key}#loading`, parentId: id, depth: depth + 1 });
      } else if (c.error) {
        rows.push({ kind: 'error', key: `${key}#error`, parentId: id, depth: depth + 1, message: c.error });
      } else if (c.nextCursor) {
        rows.push({ kind: 'more', key: `${key}#more`, parentId: id, depth: depth + 1 });
      } else if (c.loaded && c.placements.length === 0 && c.pinned.length === 0) {
        rows.push({ kind: 'empty', key: `${key}#empty`, parentId: id, depth: depth + 1 });
      }
    };
    walk(top, null, 0, false, false, top);
    return rows;
  });

  /** Opens a hierarchy at a slice: the top node, expanded with its first page of children. */
  async open(code: string, slice: Slice): Promise<void> {
    const generation = ++this.generation;
    this.slice = slice;
    this.nodes.set(new Map());
    this.children.set(new Map());
    this.expanded.set(new Set());
    this.error.set(null);
    try {
      const h = await this.api.hierarchy(code, slice);
      if (generation !== this.generation) {
        return;
      }
      this.hierarchy.set(h);
      if (h.topNodeId) {
        this.putNodes([{ id: h.topNodeId, name: h.topNodeName ?? h.name ?? code, hasChildren: true, active: true }]);
        await this.expand(h.topNodeId);
      }
    } catch (e) {
      if (generation === this.generation) {
        this.error.set(UiError.from(e));
      }
    }
  }

  async expand(id: string): Promise<void> {
    this.expanded.update((s) => new Set(s).add(id));
    const c = this.children().get(id);
    if (!c || (!c.loaded && !c.loading)) {
      await this.loadPage(id);
    }
  }

  collapse(id: string): void {
    this.expanded.update((s) => {
      const next = new Set(s);
      next.delete(id);
      return next;
    });
  }

  toggle(id: string): Promise<void> | void {
    return this.expanded().has(id) ? this.collapse(id) : this.expand(id);
  }

  select(id: string | null): void {
    this.selectedId.set(id);
  }

  /** The next page of a parent's children ("Show next 200"), or a retry after an error. */
  async loadPage(parentId: string): Promise<void> {
    const code = this.hierarchy()?.code;
    if (!code) {
      return;
    }
    const generation = this.generation;
    const before = this.children().get(parentId);
    if (before?.loading) {
      return;
    }
    this.patchChildren(parentId, { loading: true, error: null });
    try {
      const page = await this.api.children(code, parentId, this.slice, before?.nextCursor ?? undefined, CHILDREN_PAGE);
      if (generation !== this.generation) {
        return;
      }
      const items = page.items ?? [];
      this.putNodes(items.map((c) => ({ id: c.nodeId!, name: c.name ?? c.nodeId!, hasChildren: !!c.hasChildren, active: c.active !== false })));
      const current = this.children().get(parentId)!;
      const seen = new Set(current.placements.map((p) => p.id));
      const added = items.filter((c) => !seen.has(c.nodeId!)).map((c) => ({ id: c.nodeId!, shared: c.primary === false }));
      this.patchChildren(parentId, {
        placements: [...current.placements, ...added],
        // a node pinned by search that a later page brings in is no longer pinned
        pinned: current.pinned.filter((p) => !added.some((a) => a.id === p)),
        nextCursor: page.nextCursor ?? null, loading: false, loaded: true,
      });
    } catch {
      if (generation === this.generation) {
        this.patchChildren(parentId, { loading: false, error: STRINGS.hierarchy.childrenError });
      }
    }
  }

  /**
   * Reveals a node (LLD §7.2): expands its primary path, loading pages of each ancestor's children until the next ancestor
   * appears; beyond REVEAL_MAX_PAGES it pins the node under its ancestor as "found by search". Then selects it.
   */
  async reveal(nodeId: string, name?: string): Promise<boolean> {
    const code = this.hierarchy()?.code;
    if (!code) {
      return false;
    }
    const { path = [] } = await this.api.path(code, nodeId, this.slice);
    if (path.length === 0) {
      return false;
    }
    for (let i = 0; i < path.length - 1; i++) {
      const ancestor = path[i].nodeId!;
      const next = path[i + 1];
      this.expanded.update((s) => new Set(s).add(ancestor));
      let c = this.children().get(ancestor);
      if (!c?.loaded) {
        await this.loadPage(ancestor);
        c = this.children().get(ancestor);
      }
      let pages = 1;
      while (c && !c.placements.some((p) => p.id === next.nodeId) && c.nextCursor && pages < REVEAL_MAX_PAGES) {
        await this.loadPage(ancestor);
        c = this.children().get(ancestor);
        pages++;
      }
      if (c && !c.placements.some((p) => p.id === next.nodeId)) {
        this.putNodes([{ id: next.nodeId!, name: next.name ?? name ?? next.nodeId!, hasChildren: i + 1 < path.length - 1, active: true }]);
        if (!c.pinned.includes(next.nodeId!)) {
          this.patchChildren(ancestor, { pinned: [...c.pinned, next.nodeId!] });
        }
      }
    }
    this.select(nodeId);
    return true;
  }

  /** Visible children of a parent that can be expanded (for the `*` key). */
  siblingsOf(parentId: string | null): string[] {
    if (!parentId) {
      return [];
    }
    return (this.children().get(parentId)?.placements ?? []).map((p) => p.id).filter((id) => this.nodes().get(id)?.hasChildren);
  }

  private putNodes(list: TreeNode[]): void {
    this.nodes.update((m) => {
      const next = new Map(m);
      for (const n of list) {
        next.set(n.id, n);
      }
      return next;
    });
  }

  private patchChildren(parentId: string, patch: Partial<ChildrenState>): void {
    this.children.update((m) => {
      const next = new Map(m);
      const current = next.get(parentId) ?? { placements: [], nextCursor: null, loading: false, error: null, loaded: false, pinned: [] };
      next.set(parentId, { ...current, ...patch });
      return next;
    });
  }
}
