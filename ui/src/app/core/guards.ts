import { inject } from '@angular/core';
import { CanActivateFn, Router } from '@angular/router';
import { NexusApi } from '../api/nexus-api';
import { ContextStore } from './context.store';
import { PreferencesStore } from './preferences.store';

/** `/` → the user's start page (OD-27). Navigation only: the server authorises every call (UI_STANDARD §2). */
export const startPageGuard: CanActivateFn = async () => {
  const context = inject(ContextStore);
  const prefs = inject(PreferencesStore);
  const router = inject(Router);
  await context.load();
  switch (prefs.startPage()) {
    case 'worklist':
      return router.parseUrl('/worklist');
    case 'hierarchies':
      return router.parseUrl('/hierarchies');
    default:
      return router.parseUrl('/home');
  }
};

/** `/hierarchies` → the last hierarchy used, else the first readable one, else Home. */
export const hierarchiesGuard: CanActivateFn = async () => {
  const context = inject(ContextStore);
  const prefs = inject(PreferencesStore);
  const router = inject(Router);
  const api = inject(NexusApi);
  await context.load();
  const last = prefs.lastHierarchy();
  if (last) {
    return router.createUrlTree(['/hierarchies', last]);
  }
  try {
    const page = await api.hierarchies();
    const first = page.items?.[0]?.code;
    return first ? router.createUrlTree(['/hierarchies', first]) : router.parseUrl('/home');
  } catch {
    return router.parseUrl('/home');
  }
};

/** Every page needs the signed-in context first (the as-of banner and permissions depend on it). */
export const contextGuard: CanActivateFn = async () => {
  await inject(ContextStore).load();
  return true;
};
