/**
 * Random identifiers for idempotency keys and correlation ids (ADR-015, overview §14).
 *
 * `crypto.randomUUID()` exists only in a secure context (HTTPS or localhost), so a page served over plain HTTP from a
 * server address has none. `crypto.getRandomValues()` exists in every context and is the same cryptographic source, so
 * the fallback builds a version 4 UUID (RFC 9562) from it rather than from `Math.random()`.
 */
export function randomId(): string {
  const c = globalThis.crypto;
  if (typeof c?.randomUUID === 'function') {
    return c.randomUUID();
  }
  const b = c.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40;   // version 4
  b[8] = (b[8] & 0x3f) | 0x80;   // variant 10
  const hex = Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/** As {@link randomId}, or null when the browser has no crypto at all: for ids that are only a convenience. */
export function tryRandomId(): string | null {
  try {
    return randomId();
  } catch {
    return null;
  }
}
