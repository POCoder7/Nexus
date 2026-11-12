import { HttpInterceptorFn } from '@angular/common/http';
import { Injectable, Type, signal } from '@angular/core';

/**
 * Production replacement for `dev-identity.providers.ts` (angular.json fileReplacements): no development identity, no
 * picker, no header. Authentication comes with OD-06 (Phase 9). Same exports, so the app compiles unchanged.
 */
export const DEV_IDENTITY_HEADER = '';
export const DEV_LOGINS: string[] = [];

@Injectable({ providedIn: 'root' })
export class DevIdentity {
  readonly login = signal<string | null>(null);

  set(_login: string): void {
    /* not available in production */
  }
}

export interface DevTools {
  enabled: boolean;
  interceptor: HttpInterceptorFn | null;
  picker: Type<unknown> | null;
}

export function devIdentityInterceptor(_identity: () => DevIdentity): HttpInterceptorFn {
  return (req, next) => next(req);
}

export const DEV_TOOLS: DevTools = { enabled: false, interceptor: null, picker: null };
