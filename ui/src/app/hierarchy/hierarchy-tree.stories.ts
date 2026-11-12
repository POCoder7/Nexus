import type { Meta, StoryObj } from '@storybook/angular-vite';
import { FlatTreeRow } from './tree.model';
import { HierarchyTreeComponent } from './hierarchy-tree.component';

// Synthetic rows only (UI_STANDARD §5: every state of every custom component).
const node = (id: string, name: string, depth: number, extra: Partial<Extract<FlatTreeRow, { kind: 'node' }>> = {}): FlatTreeRow => ({
  kind: 'node', key: id, id, parentId: depth ? 'top' : null, name, depth, hasChildren: false, expanded: false, shared: false,
  active: true, pinned: false, ...extra,
});
const base: FlatTreeRow[] = [
  node('top', 'Synthetic Group', 0, { hasChildren: true, expanded: true }),
  node('n', 'Region North', 1, { hasChildren: true }),
  node('s', 'Shared Services', 1, { shared: true }),
  node('i', 'Dormant entity', 1, { active: false }),
];

const meta: Meta<HierarchyTreeComponent> = {
  title: 'Custom/Hierarchy tree',
  component: HierarchyTreeComponent,
  args: { label: 'Synthetic hierarchy', rows: base, selectedId: null, rowHeight: 28 },
  render: (args) => ({ props: args, template: `<div style="height: 18rem"><nx-hierarchy-tree [rows]="rows" [label]="label" [selectedId]="selectedId" [rowHeight]="rowHeight" /></div>` }),
};
export default meta;
type Story = StoryObj<HierarchyTreeComponent>;

export const Default: Story = {};
export const Selected: Story = { args: { selectedId: 'n' } };
export const PagedSiblings: Story = {
  args: {
    rows: [
      node('top', 'Synthetic Group', 0, { hasChildren: true, expanded: true }),
      ...Array.from({ length: 200 }, (_, i) => node(`b${i}`, `Bulk ${String(i + 1).padStart(4, '0')}`, 1)),
      { kind: 'more', key: 'top#more', parentId: 'top', depth: 1 },
    ],
  },
};
export const Loading: Story = { args: { rows: [...base, { kind: 'loading', key: 'top#loading', parentId: 'top', depth: 1 }] } };
export const Error: Story = { args: { rows: [...base, { kind: 'error', key: 'top#error', parentId: 'top', depth: 1, message: "Couldn't load children." }] } };
export const Empty: Story = {
  args: { rows: [node('top', 'Synthetic Group', 0, { hasChildren: true, expanded: true }), { kind: 'empty', key: 'top#empty', parentId: 'top', depth: 1 }] },
};
export const FoundBySearch: Story = { args: { rows: [...base, node('deep', 'Deep target', 1, { pinned: true })], selectedId: 'deep' } };
export const Comfortable: Story = { args: { rowHeight: 36 } };
