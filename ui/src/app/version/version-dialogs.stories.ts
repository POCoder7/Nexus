import { HttpErrorResponse } from '@angular/common/http';
import type { Meta, StoryObj } from '@storybook/angular-vite';
import { moduleMetadata } from '@storybook/angular-vite';
import { expect, userEvent, within } from 'storybook/test';
import { NexusApi } from '../api/nexus-api';
import type { VersionView } from '../api/generated/models';
import { DIALOG_DATA, DialogRef } from '../shared/ds';
import { TransitionDialogComponent } from './transition-dialog.component';
import { VersionDialogComponent } from './version-dialog.component';

/** The dialogs render inline here (no overlay) with a fake API, so axe checks their content. Synthetic names only. */
const working: VersionView = { name: 'Synthetic FY32 plan', status: 'working', businessAsOf: '2031-12-31', revision: 1 };
const submitted: VersionView = { name: 'Synthetic Q2 close', status: 'submitted', businessAsOf: '2031-06-30', revision: 3,
  recordedAsOf: '2031-07-02T15:30:00Z' };

const api = {
  versions: async () => ({ items: [working, submitted] }),
  createVersion: async (body: VersionView) => ({ body: { ...body, status: 'working', revision: 1 }, etag: '"1"' }),
  updateVersion: async (name: string, _etag: string, body: VersionView) => ({ body: { ...working, ...body, name: body.name ?? name }, etag: '"2"' }),
  transitionVersion: async () => {
    throw new HttpErrorResponse({ status: 403, error: { code: 'version.self_finalize',
      detail: 'Another version administrator must finalize what you submitted.' } });
  },
};
const ref = { close: () => undefined };

function providers(data: unknown) {
  return moduleMetadata({ providers: [{ provide: NexusApi, useValue: api }, { provide: DIALOG_DATA, useValue: data },
    { provide: DialogRef, useValue: ref }] });
}

const meta: Meta = { title: 'Custom/Version dialogs' };
export default meta;
type Story = StoryObj;

export const CreateVersion: Story = {
  decorators: [providers({ mode: 'create' })],
  render: () => ({ template: '<nx-version-dialog />', moduleMetadata: { imports: [VersionDialogComponent] } }),
};
/** Create pressed with nothing filled in: the summary links to each field in error, and takes focus. */
export const CreateWithErrors: Story = {
  decorators: [providers({ mode: 'create' })],
  render: () => ({ template: '<nx-version-dialog />', moduleMetadata: { imports: [VersionDialogComponent] } }),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    await userEvent.click(canvas.getByRole('button', { name: 'Create version' }));
    const summary = await canvas.findByTestId('version-summary');
    await expect(summary).toHaveTextContent('Name: Required');
    await expect(summary).toHaveTextContent('Business date: Required');
  },
};
export const EditVersion: Story = {
  decorators: [providers({ mode: 'edit', version: working })],
  render: () => ({ template: '<nx-version-dialog />', moduleMetadata: { imports: [VersionDialogComponent] } }),
};
export const ConfirmSubmit: Story = {
  decorators: [providers({ version: working, to: 'submitted' })],
  render: () => ({ template: '<nx-transition-dialog />', moduleMetadata: { imports: [TransitionDialogComponent] } }),
};
/** Finalize is permanent, so its button reads as destructive; the fake server refuses it to show the inline reason. */
export const ConfirmFinalize: Story = {
  decorators: [providers({ version: submitted, to: 'finalized' })],
  render: () => ({ template: '<nx-transition-dialog />', moduleMetadata: { imports: [TransitionDialogComponent] } }),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    await userEvent.click(canvas.getByRole('button', { name: 'Finalize version' }));
    await expect(await canvas.findByTestId('transition-error')).toHaveTextContent('Another version administrator');
  },
};
