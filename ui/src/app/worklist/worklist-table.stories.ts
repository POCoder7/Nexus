import type { Meta, StoryObj } from '@storybook/angular-vite';
import { WorklistTableComponent } from './worklist-table.component';

const row = (i: number, extra: object = {}) => ({
  rowId: `r${i}`, changeRequestId: `cr${i}`, title: `Add Synthetic leaf ${i}`, stageLabel: 'Approve', stageStatus: 'active',
  modelCode: 'ADD_LEAF', dueAt: '2031-05-20T14:00:00Z', isUrgent: false, isOverdue: false, ...extra,
});

const meta: Meta<WorklistTableComponent> = {
  title: 'Custom/Worklist table',
  component: WorklistTableComponent,
  args: { rows: [row(1), row(2, { isUrgent: true }), row(3, { isOverdue: true }), row(4, { stageStatus: 'claimed', dueAt: undefined })], loading: false, hasMore: false, emptyText: 'Nothing is assigned to you.' },
};
export default meta;
type Story = StoryObj<WorklistTableComponent>;

export const Default: Story = {};
export const MorePages: Story = { args: { rows: Array.from({ length: 50 }, (_, i) => row(i + 1)), hasMore: true } };
export const Loading: Story = { args: { rows: [], loading: true } };
export const Empty: Story = { args: { rows: [] } };
