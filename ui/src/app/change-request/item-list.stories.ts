import type { Meta, StoryObj } from '@storybook/angular-vite';
import { ItemListComponent } from './item-list.component';

const meta: Meta<ItemListComponent> = {
  title: 'Custom/Before and after view',
  component: ItemListComponent,
  args: {
    items: [
      { id: 'i1', seq: 1, action: 'add_node', nodeId: 'n1', payload: { name: 'Synthetic leaf', isLeaf: true }, before: {} },
      { id: 'i2', seq: 2, action: 'set_property', nodeId: 'n1', propertyCode: 'S.Seg', payload: { value: 'Retail' }, before: { present: false, value: null } },
      { id: 'i3', seq: 3, action: 'update_node', nodeId: 'n2', payload: { description: 'New text' }, before: { name: 'Synthetic node', description: 'Old text' } },
      { id: 'i4', seq: 4, action: 'move_node', nodeId: 'n3', targetParentId: 'abcdef12-0000', payload: {}, before: { parentIds: ['p'] } },
      { id: 'i5', seq: 5, action: 'remove_node', nodeId: 'n4', payload: { cascade: true }, before: { parentIds: ['p'] } },
    ],
    findings: [],
  },
};
export default meta;
type Story = StoryObj<ItemListComponent>;

export const SideBySide: Story = {};
export const WithFinding: Story = { args: { findings: [{ nodeId: 'n1', ruleCode: 'R', message: 'A node with this name already exists.' }] } };
export const Empty: Story = { args: { items: [] } };
