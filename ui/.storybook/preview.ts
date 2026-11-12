import type { Preview } from '@storybook/angular-vite';

/** Stories render with the same tokens and global styles as the app (angular.json build styles). */
const preview: Preview = {
  parameters: {
    layout: 'padded',
    controls: { matchers: { color: /(background|color)$/i, date: /Date$/i } },
  },
};

export default preview;
