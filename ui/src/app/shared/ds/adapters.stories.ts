import type { Meta, StoryObj } from '@storybook/angular-vite';
import { DsBadgeComponent } from './ds-badge.component';
import { DsButtonComponent } from './ds-button.component';

/** Design-system adapters with placeholder tokens (LLD §3.4). Replaced by the design system's components (OD-02). */
const meta: Meta = {
  title: 'Adapters/Button and badge',
  decorators: [],
  render: (args) => ({
    props: args,
    moduleMetadata: { imports: [DsButtonComponent, DsBadgeComponent] },
    template: `<div style="display:flex; gap: 1rem; flex-wrap: wrap; align-items: center">
      <ds-button variant="primary">Submit request</ds-button>
      <ds-button>Cancel</ds-button>
      <ds-button variant="danger">Reject</ds-button>
      <ds-button variant="link">Today</ds-button>
      <ds-button variant="primary" [disabled]="true">Add to request</ds-button>
      <ds-badge tone="success">Applied</ds-badge>
      <ds-badge tone="pending">In review</ds-badge>
      <ds-badge tone="error">Rejected</ds-badge>
      <ds-badge tone="warning">Urgent</ds-badge>
      <ds-badge tone="info">Draft</ds-badge>
      <ds-badge>Withdrawn</ds-badge>
    </div>`,
  }),
};
export default meta;

export const All: StoryObj = {};
