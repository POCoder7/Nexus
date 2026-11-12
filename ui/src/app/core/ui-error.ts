import { HttpErrorResponse } from '@angular/common/http';
import { STRINGS } from './strings';

export interface FieldError {
  field: string;
  message: string;
}

/**
 * The UI's view of a failed call (LLD §3.1): Problem Details mapped to what a screen shows. Screens never parse
 * responses themselves; the API is the authority and this only carries its words to the user.
 */
export class UiError extends Error {
  constructor(
    readonly status: number,
    readonly title: string,
    readonly detail: string,
    readonly code: string | null,
    readonly type: string | null,
    readonly fieldErrors: FieldError[],
    readonly correlationId: string | null,
    readonly body: Record<string, unknown> | null,
  ) {
    super(detail);
  }

  static from(e: unknown): UiError {
    if (e instanceof UiError) {
      return e;
    }
    if (e instanceof HttpErrorResponse) {
      const body = (e.error && typeof e.error === 'object' ? e.error : null) as Record<string, unknown> | null;
      const correlationId = (body?.['correlationId'] as string | undefined) ?? e.headers?.get('X-Correlation-Id') ?? null;
      let detail = (body?.['detail'] as string | undefined) ?? '';
      if (e.status === 0) {
        detail = STRINGS.errors.network;
      } else if (e.status === 412) {
        detail = STRINGS.errors.stale;
      } else if (e.status === 401) {
        detail = STRINGS.errors.unauthenticated;
      } else if (!detail || e.status >= 500) {
        detail = STRINGS.errors.generic;
      }
      return new UiError(e.status, (body?.['title'] as string | undefined) ?? e.statusText, detail,
        (body?.['code'] as string | undefined) ?? null, (body?.['type'] as string | undefined) ?? null,
        fieldErrorsOf(body), correlationId, body);
    }
    return new UiError(0, 'Error', STRINGS.errors.generic, null, null, [], null, null);
  }
}

/** `errors` of an invalid-request problem: `[{field, message}]` (ItemValidationException). Findings are not field errors. */
function fieldErrorsOf(body: Record<string, unknown> | null): FieldError[] {
  const errors = body?.['errors'];
  if (!Array.isArray(errors)) {
    return [];
  }
  return errors
    .filter((x): x is { field: string; message: string } => !!x && typeof x === 'object' && 'field' in x)
    .map((x) => ({ field: String(x.field), message: String(x.message) }));
}
