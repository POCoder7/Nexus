import type { Meta, StoryObj } from '@storybook/angular-vite';
import { VersionPickerComponent } from './version-picker.component';

const meta: Meta<VersionPickerComponent> = {
  title: 'Custom/Working version picker',
  component: VersionPickerComponent,
  args: {
    versions: [{ name: 'Synthetic working', businessAsOf: '2031-05-17' }, { name: 'Synthetic FY32 plan', businessAsOf: '2031-12-31' }],
    value: 'Synthetic working',
    busy: false,
  },
};
export default meta;
type Story = StoryObj<VersionPickerComponent>;

export const Default: Story = {};
export const Saving: Story = { args: { busy: true } };
export const NoWorkingVersion: Story = { args: { versions: [], value: null } };
