import type { Meta, StoryObj } from '@storybook/angular-vite';
import { ChangeRequestTrayComponent } from './change-request-tray.component';

const meta: Meta<ChangeRequestTrayComponent> = {
  title: 'Custom/Change-request tray',
  component: ChangeRequestTrayComponent,
  args: { count: 3, failedCount: 0, busy: false },
};
export default meta;
type Story = StoryObj<ChangeRequestTrayComponent>;

export const Default: Story = {};
export const Empty: Story = { args: { count: 0 } };
export const Busy: Story = { args: { busy: true } };
export const PartialFailure: Story = { args: { failedCount: 1 } };
export const InAnotherVersion: Story = { args: { otherVersion: 'FY27 plan' } };
