import type { StorybookConfig } from '@storybook/angular-vite';

/** Storybook (ADR-025, UI_STANDARD §5, §10): a story for every state of every custom component. Telemetry is off. */
const config: StorybookConfig = {
  stories: ['../src/**/*.stories.@(ts)'],
  addons: ['@storybook/addon-docs'],
  framework: '@storybook/angular-vite',
  core: { disableTelemetry: true },
};
export default config;
