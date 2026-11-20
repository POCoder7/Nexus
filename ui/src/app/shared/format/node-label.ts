/**
 * How a node is named on screen (ADR-046 D1). The node name is the business key and may be a code ("10110"); the
 * display name is what people read. With a display name the label is "display name · code", otherwise the name alone.
 */
export function nodeLabel(n: { name?: string | null; displayName?: string | null } | null | undefined): string {
  if (!n) {
    return '';
  }
  const name = n.name ?? '';
  return n.displayName ? `${n.displayName} · ${name}` : name;
}
