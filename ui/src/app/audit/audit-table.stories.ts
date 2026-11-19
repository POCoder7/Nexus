import { provideRouter } from '@angular/router';
import { applicationConfig, type Meta, type StoryObj } from '@storybook/angular-vite';
import { AuditTableComponent } from './audit-table.component';

/** AUD-01 (Phase 5 LLD §18.7): synthetic entries only. */
const base = { occurredAt: '2031-05-20T14:00:00Z', category: 'data', operation: 'INSERT', changeRequestId: 'cr1',
  changeRequestTitle: 'Synthetic change', requestedBy: 'Synthetic Editor', decidedBy: 'Synthetic Approver', changedFields: [] };
const rows = [
  { ...base, id: 'mdm:3', kind: 'stated', table: 'property_value', propertyLabel: 'Segment', nodeId: 'n1', nodeName: 'Synthetic leaf',
    hierarchyCode: 'SYN_H', validFrom: '2031-05-20', before: { value: 'Retail' }, after: { value: 'Wholesale' }, changedFields: ['value'] },
  { ...base, id: 'mdm:2', kind: 'stated', table: 'hierarchy_relationship', nodeId: 'n1', nodeName: 'Synthetic leaf', hierarchyCode: 'SYN_H',
    before: { parent_name: 'North' }, after: { parent_name: 'South' }, changedFields: ['parent_node_id'] },
  { ...base, id: 'mdm:1', kind: 'stated', table: 'node_attr', nodeId: 'n2', nodeName: 'Synthetic other', hierarchyCode: null,
    before: { node_name: 'Old name' }, after: { node_name: 'Synthetic other' }, changedFields: ['node_name'], decisionBasis: 'approved_policy' },
];

const meta: Meta<AuditTableComponent> = {
  title: 'Custom/Audit table',
  component: AuditTableComponent,
  decorators: [applicationConfig({ providers: [provideRouter([])] })],
  args: { rows: rows as never, loading: false, hasMore: false, timeZone: 'UTC' },
};
export default meta;
type Story = StoryObj<AuditTableComponent>;

export const Default: Story = {};
export const MorePages: Story = { args: { hasMore: true } };
export const Empty: Story = { args: { rows: [] } };
