import type { Meta, StoryObj } from '@storybook/angular-vite';
import { PropertyGridComponent } from './property-grid.component';

const meta: Meta<PropertyGridComponent> = {
  title: 'Custom/Property grid',
  component: PropertyGridComponent,
  args: {
    nodeName: 'Synthetic entity',
    sourceNames: { top: 'Synthetic Group' },
    properties: [
      { code: 'S.Currency', label: 'Reporting currency', category: 'Finance', provenance: 'inherited', value: 'EUR' as never, sourceNodeId: 'top' },
      { code: 'S.Segment', label: 'Segment', category: 'Finance', provenance: 'default', value: 'Unassigned' as never },
      { code: 'S.Owner', label: 'Owner desk', category: 'Admin', provenance: 'stored', value: 'Desk 7' as never },
      { code: 'S.Depth', label: 'Depth', category: 'Admin', provenance: 'derived', value: 3 as never },
      { code: 'S.Note', label: 'Note', category: 'Admin', provenance: 'stored', value: null as never },
      { code: 'S.Unset', label: 'Unset', category: 'Admin', provenance: 'none' },
    ],
  },
};
export default meta;
type Story = StoryObj<PropertyGridComponent>;

export const AllProvenances: Story = {};
export const Editable: Story = { args: { editable: true } };
export const SingleCategory: Story = {
  args: { properties: [{ code: 'S.Segment', label: 'Segment', category: 'Finance', provenance: 'stored', value: 'Retail' as never }] },
};
export const Empty: Story = { args: { properties: [] } };
