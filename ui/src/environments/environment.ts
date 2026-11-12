/**
 * Build-time settings. Nothing secret lives here (UI_STANDARD §9). `name` is the environment badge in the header;
 * shared environments wait for OD-06 (authentication) and OD-44.
 */
export const environment = {
  name: 'Local' as string | null,
};
