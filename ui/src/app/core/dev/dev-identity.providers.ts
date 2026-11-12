import { HttpInterceptorFn } from '@angular/common/http';
import { Injectable, Type, signal } from '@angular/core';
import { DevUserPickerComponent } from './dev-user-picker.component';

/**
 * DEVELOPMENT AND TEST BUILDS ONLY (LLD C-7, §9). The production build replaces this file with
 * `dev-identity.providers.prod.ts` (angular.json fileReplacements), and `scripts/check-prod-build.mjs` fails the build if
 * the header name or the picker reaches the production bundle. Until OD-06 the API's `local`/`test` profiles identify the
 * caller from the `X-Nexus-User` header (synthetic logins only).
 */
export const DEV_IDENTITY_HEADER = 'X-Nexus-User';
const KEY = 'nexus.dev.user';

/** Synthetic logins offered by the picker (the end-to-end seed creates them); any other login can be typed. */
export const DEV_LOGINS = ['e2e_steward', 'e2e_approver', 'e2e_committer', 'e2e_viewer', 'e2e_policy', 'e2e_architect'];

@Injectable({ providedIn: 'root' })
export class DevIdentity {
  /** The login is a development convenience, not a credential, so session storage is acceptable here (never in prod). */
  readonly login = signal<string | null>(read());

  set(login: string): void {
    this.login.set(login);
    try {
      sessionStorage.setItem(KEY, login);
    } catch {
      /* storage unavailable: the login lasts for this page only */
    }
  }
}

function read(): string | null {
  try {
    return sessionStorage.getItem(KEY) ?? new URLSearchParams(location.search).get('devUser');
  } catch {
    return null;
  }
}

export interface DevTools {
  enabled: boolean;
  interceptor: HttpInterceptorFn | null;
  picker: Type<unknown> | null;
}

export function devIdentityInterceptor(identity: () => DevIdentity): HttpInterceptorFn {
  return (req, next) => {
    const login = identity().login();
    return next(login && req.url.startsWith('/api/') ? req.clone({ setHeaders: { [DEV_IDENTITY_HEADER]: login } }) : req);
  };
}

export const DEV_TOOLS: DevTools = {
  enabled: true,
  interceptor: null,   // set in app.config with access to the injector
  picker: DevUserPickerComponent,
};
