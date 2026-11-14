import { provideRouter } from '@angular/router';
import { applicationConfig, type Meta, type StoryObj } from '@storybook/angular-vite';
import { SandboxConflictsComponent } from './sandbox-conflicts.component';

/** The sandbox conflicts panel (NEW-08, Phase 5 LLD §12). Synthetic names and ids. */
const meta: Meta<SandboxConflictsComponent> = {
  title: 'Custom/Sandbox conflicts',
  component: SandboxConflictsComponent,
  decorators: [applicationConfig({ providers: [provideRouter([])] })],
  args: {
    canChange: true,
    busy: false,
    conflicts: [
      { seq: 1, itemId: 'i1', action: 'update_node', field: 'name', expected: 'Region North', actual: 'Region North East',
        changedByRequest: '0a1b2c3d-0000-4000-8000-000000000001' },
      { seq: 4, itemId: 'i4', action: 'set_property', field: 'value', expected: 'EUR', actual: 'USD' },
    ],
  },
};
export default meta;
type Story = StoryObj<SandboxConflictsComponent>;

export const Conflicts: Story = {};
export const NoConflicts: Story = { args: { conflicts: [] } };
export const ReadOnly: Story = { args: { canChange: false } };
export const Busy: Story = { args: { busy: true } };
