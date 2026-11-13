import type { Meta, StoryObj } from '@storybook/angular-vite';
import type { VersionView } from '../api/generated/models';
import { VersionsTableComponent } from './versions-table.component';

const rows: VersionView[] = [
  { name: 'Synthetic FY32 plan', status: 'working', businessAsOf: '2031-12-31', description: 'Synthetic planning copy', revision: 1,
    transitions: [{ to: 'submitted', allowed: true }], edit: { allowed: true } },
  { name: 'Synthetic Q2 close', status: 'submitted', businessAsOf: '2031-06-30', recordedAsOf: '2031-07-02T15:30:00Z', revision: 3,
    baseVersion: 'Synthetic FY32 plan',
    transitions: [{ to: 'working', allowed: true },
      { to: 'finalized', allowed: false, whyNot: 'Another version administrator must finalize what you submitted.' }],
    edit: { allowed: false, whyNot: 'Only a working version can be renamed.' } },
  { name: 'Synthetic Q1 close', status: 'finalized', businessAsOf: '2031-03-31', recordedAsOf: '2031-04-02T15:30:00Z', revision: 5,
    transitions: [{ to: 'expired', allowed: true }], edit: { allowed: false, whyNot: 'Only a working version can be renamed.' } },
  { name: 'Synthetic FY30 close', status: 'expired', businessAsOf: '2030-12-31', recordedAsOf: '2031-01-03T15:30:00Z', revision: 7,
    transitions: [], edit: { allowed: false, whyNot: 'Only a working version can be renamed.' } },
];

const meta: Meta<VersionsTableComponent> = {
  title: 'Custom/Versions table',
  component: VersionsTableComponent,
  args: { rows, loading: false, hasMore: false, emptyText: 'No versions yet.', canAdmin: true, timeZone: 'UTC' },
};
export default meta;
type Story = StoryObj<VersionsTableComponent>;

export const Administrator: Story = {};
export const Viewer: Story = { args: { canAdmin: false } };
export const MorePages: Story = { args: { hasMore: true } };
export const Loading: Story = { args: { rows: [], loading: true } };
export const Empty: Story = { args: { rows: [] } };
