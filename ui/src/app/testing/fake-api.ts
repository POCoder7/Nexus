import type { ChildNode, NodeRef, PageChildNode } from '../api/generated/models';

/** Synthetic tree for store tests: parent id → children, each page of `pageSize`. Names are invented. */
export class FakeTree {
  readonly calls: { parentId: string; cursor?: string }[] = [];
  failNext = false;

  constructor(private readonly children: Record<string, ChildNode[]>, private readonly paths: Record<string, NodeRef[]> = {}) {}

  page(parentId: string, cursor: string | undefined, limit: number): PageChildNode {
    this.calls.push({ parentId, cursor });
    if (this.failNext) {
      this.failNext = false;
      throw new Error('boom');
    }
    const all = this.children[parentId] ?? [];
    const start = cursor ? Number(cursor) : 0;
    const items = all.slice(start, start + limit);
    return { items, nextCursor: start + limit < all.length ? String(start + limit) : undefined };
  }

  path(nodeId: string): NodeRef[] {
    return this.paths[nodeId] ?? [];
  }
}

export function leaves(prefix: string, n: number, parent = 'p'): ChildNode[] {
  return Array.from({ length: n }, (_, i) => ({ nodeId: `${parent}-${i + 1}`, name: `${prefix} ${String(i + 1).padStart(4, '0')}`,
    hasChildren: false, active: true, primary: true }));
}
