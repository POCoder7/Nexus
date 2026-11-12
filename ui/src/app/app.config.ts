import { provideHttpClient, withFetch, withInterceptors } from '@angular/common/http';
import { ApplicationConfig, inject, provideBrowserGlobalErrorListeners } from '@angular/core';
import { provideRouter, withComponentInputBinding } from '@angular/router';
import { routes } from './app.routes';
import { provideApiConfiguration } from './api/generated/api-configuration';
import { DevIdentity, devIdentityInterceptor } from './core/dev/dev-identity.providers';
import { apiErrorInterceptor, correlationIdInterceptor, idempotencyInterceptor } from './core/http/interceptors';

export const appConfig: ApplicationConfig = {
  providers: [
    provideBrowserGlobalErrorListeners(),
    provideRouter(routes, withComponentInputBinding()),
    // Same-origin API: the dev server proxies /api (proxy.conf.js); generated paths already start with /api/v1.
    provideApiConfiguration(''),
    provideHttpClient(
      withFetch(),
      withInterceptors([
        correlationIdInterceptor,
        idempotencyInterceptor,
        // local and test builds only; the production build replaces it with a pass-through (LLD C-7, §9)
        (req, next) => devIdentityInterceptor(() => inject(DevIdentity))(req, next),
        apiErrorInterceptor,
      ]),
    ),
  ],
};
