import { provideRouter } from '@angular/router';
import { applicationConfig, type Meta, type StoryObj } from '@storybook/angular-vite';
import { QueryResultsComponent } from './query-results.component';

/** Query results (QRY-01, Phase 5 LLD §17.12). Synthetic names. */
const rows = [
  { nodeId: 'n1', name: 'Synthetic Leaf 01', parentName: 'Synthetic Region 1', leaf: true,
    columns: [{ code: 'SYN.Ccy', value: 'USD', provenance: 'inherited', sourceNodeId: 'r1' }, { code: 'SYN.Amt', value: 1, provenance: 'stored' }] },
  { nodeId: 'n2', name: 'Synthetic Leaf 02', parentName: 'Synthetic Region 1', leaf: true,
    columns: [{ code: 'SYN.Ccy', value: 'USD', provenance: 'inherited', sourceNodeId: 'r1' }, { code: 'SYN.Amt', provenance: 'none' }] },
];

const meta: Meta<QueryResultsComponent> = {
  title: 'Custom/Query results',
  component: QueryResultsComponent,
  decorators: [applicationConfig({ providers: [provideRouter([])] })],
  args: { rows, columns: ['SYN.Ccy', 'SYN.Amt'], hierarchyCode: 'SYN_H', partial: false, scanned: 2, hasMore: false, busy: false },
};
export default meta;
type Story = StoryObj<QueryResultsComponent>;

export const Complete: Story = {};
export const MoreToShow: Story = { args: { hasMore: true } };
export const StoppedAtTheBudget: Story = { args: { partial: true, hasMore: true, scanned: 50000 } };
export const NoMatches: Story = { args: { rows: [] } };
