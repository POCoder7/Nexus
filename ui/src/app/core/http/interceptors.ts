import { HttpErrorResponse, HttpInterceptorFn } from '@angular/common/http';
import { inject } from '@angular/core';
import { Router } from '@angular/router';
import { catchError, throwError } from 'rxjs';
import { IDEMPOTENCY_KEY, NexusApi, SKIP_ERROR_REPORT } from '../../api/nexus-api';
import { tryRandomId } from '../random-id';
import { UiError } from '../ui-error';

/**
 * A correlation id per request (overview §14), shown in error states so support can find the server log. It is only a
 * convenience: if none can be made the request goes without one, and the server makes its own (CorrelationIdFilter).
 */
export const correlationIdInterceptor: HttpInterceptorFn = (req, next) => {
  const id = req.headers.has('X-Correlation-Id') ? null : tryRandomId();
  return next(id ? req.clone({ setHeaders: { 'X-Correlation-Id': id } }) : req);
};

/** Idempotency-Key from the request context (one per user action, ADR-015). */
export const idempotencyInterceptor: HttpInterceptorFn = (req, next) => {
  const key = req.context.get(IDEMPOTENCY_KEY);
  return next(key ? req.clone({ setHeaders: { 'Idempotency-Key': key } }) : req);
};

/**
 * Maps every failure to a {@link UiError} (LLD §3.1) and reports server and network failures to `POST /client-errors`
 * with status, problem type, correlation id and route only, never values (LLD §11). It never swallows an error.
 */
export const apiErrorInterceptor: HttpInterceptorFn = (req, next) => {
  const router = inject(Router);
  const api = inject(NexusApi);
  return next(req).pipe(
    catchError((e: unknown) => {
      const error = UiError.from(e);
      if (e instanceof HttpErrorResponse && (e.status === 0 || e.status >= 500) && !req.context.get(SKIP_ERROR_REPORT)) {
        api.reportClientError(e.status, error.type, error.correlationId, router.url).catch(() => undefined);
      }
      return throwError(() => error);
    }),
  );
};
