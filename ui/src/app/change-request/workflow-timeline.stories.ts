import type { Meta, StoryObj } from '@storybook/angular-vite';
import { WorkflowTimelineComponent } from './workflow-timeline.component';

const stages = (approve: string, commit: string) => [
  { seq: 1, label: 'Submit', status: 'completed', type: 'submit', decisions: [] },
  { seq: 2, label: 'Approve', status: approve, type: 'approve',
    decisions: approve === 'completed' ? [{ decision: 'approve', decidedBy: 'u1', decidedAt: '2031-05-17T15:04:00Z', comment: 'Looks right' }] : [] },
  { seq: 3, label: 'Commit', status: commit, type: 'commit', decisions: [] },
];

const meta: Meta<WorkflowTimelineComponent> = {
  title: 'Custom/Workflow timeline',
  component: WorkflowTimelineComponent,
  args: { stages: stages('active', 'pending'), evaluations: [], names: { u1: 'Synthetic approver' } },
};
export default meta;
type Story = StoryObj<WorkflowTimelineComponent>;

export const AtApprove: Story = {};
export const AtCommitWithShadowEvaluation: Story = {
  args: { stages: stages('completed', 'active'), evaluations: [{ policyCode: 'SYN_SHADOW', outcome: 'shadow_would_commit', mode: 'shadow', evaluatedAt: '2031-05-17T15:04:05Z', failedChecks: [] }] },
};
export const Rejected: Story = { args: { stages: stages('rejected', 'pending') } };
export const CommittedByPolicy: Story = {
  args: { stages: stages('completed', 'completed'), evaluations: [{ policyCode: 'SYN_ACTIVE', outcome: 'auto_committed', mode: 'active', evaluatedAt: '2031-05-17T15:04:05Z', failedChecks: [] }] },
};
