import { provideRouter } from '@angular/router';
import { applicationConfig, type Meta, type StoryObj } from '@storybook/angular-vite';
import { NavMenuComponent } from './nav-menu.component';

/** Phase 5 LLD §21: a top-navigation menu (disclosure button). */
const meta: Meta<NavMenuComponent> = {
  title: 'Custom/Navigation menu',
  component: NavMenuComponent,
  decorators: [applicationConfig({ providers: [provideRouter([{ path: '**', children: [] }])] })],
  args: { label: 'Admin', items: [{ label: 'Versions', link: '/versions' }, { label: 'Sandboxes', link: '/sandboxes' },
    { label: 'Audit', link: '/audit' }] },
};
export default meta;
type Story = StoryObj<NavMenuComponent>;

export const Closed: Story = {};
/** Opened by clicking the button, so the list is checked with axe too. */
export const Open: Story = {
  play: async ({ canvasElement }) => {
    (canvasElement.querySelector('button') as HTMLButtonElement).click();
  },
};
export const WithCount: Story = { args: { label: 'Requests', items: [{ label: 'Worklist', link: '/worklist', count: 3 }] } };
