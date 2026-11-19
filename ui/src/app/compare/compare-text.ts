import type { CompareRow } from '../api/generated/models';
import { STRINGS } from '../core/strings';

/** How compare rows are worded (Phase 5 LLD §17.4, §17.12). The API returns facts; the words are here. */
const t = STRINGS.compare;
type Detail = Record<string, unknown>;

/** The change token a row is drawn with (UI_STANDARD §5): added, removed, modified or moved. */
export type ChangeTone = 'added' | 'removed' | 'modified' | 'moved';

/** The kind of change, as a key into t.changes. */
export function changeOf(row: CompareRow): string {
  const d = (row.detail ?? {}) as Detail;
  if (row.kind === 'structure') return String(d['change'] ?? 'modified');
  return row.kind === 'rename' ? 'renamed' : 'modified';
}

export function toneOf(row: CompareRow): ChangeTone {
  switch (changeOf(row)) {
    case 'added': case 'shared_added': return 'added';
    case 'removed': case 'shared_removed': return 'removed';
    case 'moved': case 'reordered': return 'moved';
    default: return 'modified';
  }
}

export function changeText(row: CompareRow): string {
  const c = changeOf(row);
  return t.changes[c] ?? c;
}

function value(v: unknown): string {
  if (v === null || v === undefined) return t.blank;
  return typeof v === 'object' ? JSON.stringify(v) : String(v);
}

function placement(d: Detail, side: 'left' | 'right'): string {
  const name = d[`${side}ParentName`];
  const order = d[`${side}SortOrder`];
  if (d[`${side}ParentId`] === undefined && name === undefined) return '';
  const where = name ? t.under(String(name)) : t.top;
  return d['change'] === 'reordered' && order !== undefined ? `${where}, ${t.position(String(order))}` : where;
}

/** What the left side had (empty when the node or value is not there). */
export function leftText(row: CompareRow): string {
  const d = (row.detail ?? {}) as Detail;
  switch (row.kind) {
    case 'structure': return placement(d, 'left');
    case 'rename': return [d['leftName'], d['leftDescription']].filter((x) => x !== null && x !== undefined).join(' — ');
    default: return `${value(d['leftValue'])} (${t.provenance[String(d['leftProvenance'] ?? 'none')] ?? d['leftProvenance']})`;
  }
}

/** What the right side has. */
export function rightText(row: CompareRow): string {
  const d = (row.detail ?? {}) as Detail;
  switch (row.kind) {
    case 'structure': return placement(d, 'right');
    case 'rename': return [d['rightName'], d['rightDescription']].filter((x) => x !== null && x !== undefined).join(' — ');
    default: return `${value(d['rightValue'])} (${t.provenance[String(d['rightProvenance'] ?? 'none')] ?? d['rightProvenance']})`;
  }
}

/** The property a property row is about (its label, or its code). */
export function propertyOf(row: CompareRow): string | null {
  const d = (row.detail ?? {}) as Detail;
  return row.kind === 'property' ? String(d['propertyLabel'] ?? d['propertyCode'] ?? '') : null;
}
