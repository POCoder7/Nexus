import type { Meta, StoryObj } from '@storybook/angular-vite';
import { moduleMetadata } from '@storybook/angular-vite';
import { NexusApi } from '../api/nexus-api';
import { NodeOwnershipComponent } from './node-ownership.component';

const edge = (id: string, name: string, pct: number) => ({ edgeId: id, otherNodeId: id, otherName: name, relation: 'shareholding',
  economicPct: pct, votingPct: pct, direct: true, source: 'manual' });

function api(owners: object[], holdings: object[]) {
  return { owners: async () => ({ items: owners }), holdings: async () => ({ items: holdings }) };
}

const meta: Meta<NodeOwnershipComponent> = {
  title: 'Custom/Ownership view',
  component: NodeOwnershipComponent,
  args: { nodeId: 'n1', nodeName: 'Synthetic entity' },
};
export default meta;
type Story = StoryObj<NodeOwnershipComponent>;

export const OwnersAndHoldings: Story = {
  decorators: [moduleMetadata({ providers: [{ provide: NexusApi,
    useValue: api([edge('o1', 'Synthetic parent A', 60), edge('o2', 'Synthetic parent B', 40)], [edge('h1', 'Synthetic subsidiary', 75)]) }] })],
};
export const NoOwnership: Story = {
  decorators: [moduleMetadata({ providers: [{ provide: NexusApi, useValue: api([], []) }] })],
};
