import type { Meta, StoryObj } from '@storybook/angular-vite';
import { DecisionPanelComponent } from './decision-panel.component';

const meta: Meta<DecisionPanelComponent> = {
  title: 'Custom/Decision panel',
  component: DecisionPanelComponent,
  args: { stage: { instanceStageId: 's1', type: 'approve', youCanAct: true }, reason: null, busy: false, error: null },
};
export default meta;
type Story = StoryObj<DecisionPanelComponent>;

export const CanApprove: Story = {};
export const CanCommit: Story = { args: { stage: { instanceStageId: 's1', type: 'commit', youCanAct: true } } };
export const Unavailable: Story = {
  args: { stage: { instanceStageId: 's1', type: 'commit', youCanAct: false }, reason: 'You requested or submitted this change, so you cannot approve or commit it.' },
};
export const NothingOpen: Story = { args: { stage: null } };
export const Busy: Story = { args: { busy: true } };
