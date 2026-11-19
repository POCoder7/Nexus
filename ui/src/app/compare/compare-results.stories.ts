import type { Meta, StoryObj } from '@storybook/angular-vite';
import { CompareResultsComponent } from './compare-results.component';

/** QRY-02 (Phase 5 LLD §17.12): synthetic differences, drawn with the change tokens and icons. */
const structure = [
  { kind: 'structure', nodeId: 'n1', nodeName: 'Synthetic added', detail: { change: 'added', rightParentId: 'p', rightParentName: 'Synthetic South' } },
  { kind: 'structure', nodeId: 'n2', nodeName: 'Synthetic removed', detail: { change: 'removed', leftParentId: 'p', leftParentName: 'Synthetic North' } },
  { kind: 'structure', nodeId: 'n3', nodeName: 'Synthetic moved', detail: { change: 'moved', leftParentId: 'a', leftParentName: 'Synthetic North',
    rightParentId: 'b', rightParentName: 'Synthetic South' } },
];
const property = [
  { kind: 'property', nodeId: 'n4', nodeName: 'Synthetic entity', detail: { propertyLabel: 'Currency', leftValue: 'EUR', rightValue: 'USD',
    leftProvenance: 'inherited', rightProvenance: 'stored' } },
];

const meta: Meta<CompareResultsComponent> = {
  title: 'Custom/Compare results',
  component: CompareResultsComponent,
  args: { counts: { structure: 3, property: 1, rename: 0 }, kinds: ['structure', 'property', 'rename'], rows: structure as never,
    loading: false, hasMore: false, leftLabel: 'SYN_H · Baseline', rightLabel: 'SYN_H · Working' },
};
export default meta;
type Story = StoryObj<CompareResultsComponent>;

export const Structure: Story = {};
export const Properties: Story = { args: { rows: property as never, kind: 'property' } };
export const NoDifferences: Story = { args: { rows: [], kind: 'rename' } };
export const MorePages: Story = { args: { hasMore: true } };
