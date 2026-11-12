/** One visible row of the flattened lazy tree (LLD §7.1). Presentational components receive only these. */
export type FlatTreeRow =
  | {
      kind: 'node';
      key: string;          // unique per placement (a shared node appears under several parents)
      id: string;
      parentId: string | null;
      name: string;
      depth: number;
      hasChildren: boolean;
      expanded: boolean;
      shared: boolean;      // a non-primary placement (shared node indicator)
      active: boolean;
      pinned: boolean;      // inserted by search reveal beyond the paging bound (LLD §7.2)
    }
  | { kind: 'more'; key: string; parentId: string; depth: number }
  | { kind: 'loading'; key: string; parentId: string; depth: number }
  | { kind: 'error'; key: string; parentId: string; depth: number; message: string }
  | { kind: 'empty'; key: string; parentId: string; depth: number };

export interface TreeNode {
  id: string;
  name: string;
  hasChildren: boolean;
  active: boolean;
}

export interface ChildPlacement {
  id: string;
  shared: boolean;
}

export interface ChildrenState {
  placements: ChildPlacement[];
  nextCursor: string | null;
  loading: boolean;
  error: string | null;
  loaded: boolean;
  pinned: string[];
}
