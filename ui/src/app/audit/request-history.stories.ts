import type { Meta, StoryObj } from '@storybook/angular-vite';
import { RequestHistoryComponent } from './request-history.component';

/** AUD-02 (Phase 5 LLD §18.7): a synthetic request's history, oldest first. */
const at = (m: number) => `2031-05-20T14:${String(m).padStart(2, '0')}:00Z`;
const events = [
  { id: 'a:1', at: at(0), type: 'created', actor: 'Synthetic Editor', data: { title: 'Synthetic change' } },
  { id: 'a:2', at: at(1), type: 'item_added', actor: 'Synthetic Editor', data: { item: { seq: 1, action: 'set_property', propertyCode: 'SYN.Seg' } } },
  { id: 'a:3', at: at(2), type: 'status', actor: 'Synthetic Editor', data: { from: 'draft', to: 'submitted' } },
  { id: 'w:1', at: at(3), type: 'workflow', actor: 'Synthetic Admin', data: { action: 'override', stage: 'Approve', decision: 'approve', comment: 'Approvers are away' } },
  { id: 'p:1', at: at(4), type: 'policy', data: { policy: 'SYN_SHADOW', outcome: 'shadow_would_route', failedChecks: ['too_many_items'] } },
  { id: 'a:4', at: at(5), type: 'status', actor: 'Synthetic Admin', data: { from: 'in_review', to: 'applied' } },
];

const meta: Meta<RequestHistoryComponent> = {
  title: 'Custom/Request history',
  component: RequestHistoryComponent,
  args: { events: events as never, loading: false, hasMore: false, timeZone: 'UTC' },
};
export default meta;
type Story = StoryObj<RequestHistoryComponent>;

export const Default: Story = {};
export const MorePages: Story = { args: { hasMore: true } };
export const Empty: Story = { args: { events: [] } };
