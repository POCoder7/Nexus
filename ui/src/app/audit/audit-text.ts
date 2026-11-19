import type { AuditEntry, ItemView, RequestEvent } from '../api/generated/models';
import { describeItem } from '../change-request/item-text';
import { STRINGS } from '../core/strings';

/**
 * How audit entries and request events are worded (Phase 5 LLD §18.3, §18.6). The API returns facts; the words are
 * here, in one place, like item-text.ts for items.
 */
const t = STRINGS.audit;
const h = STRINGS.requestHistory;

type Row = Record<string, unknown>;

/** A stored value in words: text as is, true/false as yes/no, JSON null as "(blank)". */
export function valueText(v: unknown): string {
  if (v === null || v === undefined) {
    return t.blank;
  }
  if (typeof v === 'boolean') {
    return v ? t.yes : t.no;
  }
  return typeof v === 'object' ? JSON.stringify(v) : String(v);
}

/** The kind as shown: a stated row without a "before" is an addition. */
export function kindText(e: AuditEntry): string {
  const kind = e.kind === 'stated' && !e.before ? 'added' : e.kind ?? '';
  return t.kinds[kind] ?? kind;
}

/** What the entry is about: a property, a node's details, a placement, a hierarchy or a table. */
export function whatText(e: AuditEntry): string {
  switch (e.table) {
    case 'property_value': return e.propertyLabel ?? e.propertyCode ?? t.table(e.table);
    case 'node_attr': return t.nodeDetails;
    case 'hierarchy_relationship': return t.placement(e.hierarchyCode ?? '');
    case 'node': return t.nodeCreated;
    case 'hierarchy': return t.hierarchyRow(String((e.after as Row | undefined)?.['hierarchy_code'] ?? e.hierarchyCode ?? ''));
    default: return t.table(e.table ?? '');
  }
}

/** The change in words: "Retail → Wholesale", "Name: A → B", "under North → under South", or the new value. */
export function changeText(e: AuditEntry): string {
  const before = (e.before ?? null) as Row | null;
  const after = (e.after ?? null) as Row | null;
  if (e.table === 'hierarchy_relationship') {
    const parent = (r: Row | null) => (r ? t.under(String(r['parent_name'] ?? r['parent_node_id'] ?? '')) : '');
    return before && after ? `${parent(before)} → ${parent(after)}` : parent(after ?? before);
  }
  if (e.table === 'property_value') {
    const v = (r: Row | null) => valueText(r?.['value']);
    return before && after ? `${v(before)} → ${v(after)}` : v(after ?? before);
  }
  const fields = before && after ? e.changedFields ?? [] : Object.keys(after ?? before ?? {});
  return fields
    .filter((f) => f in t.fields || (before && after))
    .map((f) => {
      const label = t.fields[f] ?? t.table(f);
      return before && after
        ? `${label}: ${valueText(before[f])} → ${valueText(after[f])}`
        : `${label}: ${valueText((after ?? before)![f])}`;
    })
    .join('; ');
}

/** One request event in words (actor and time are shown beside it). */
export function eventText(ev: RequestEvent): string {
  const d = (ev.data ?? {}) as Row;
  switch (ev.type) {
    case 'created': return h.created(String(d['title'] ?? ''));
    case 'edited': return h.edited;
    case 'status': {
      const to = String(d['to'] ?? '');
      const word = h.statuses[to] ?? to;
      const parts = [word];
      if (to === 'approved' && d['basis'] === 'approved_policy') parts[0] = `${word} ${h.byPolicy}`;
      if (d['error']) parts.push(String(d['error']));
      return parts.join(': ');
    }
    case 'item_added':
    case 'item_changed':
    case 'item_removed': {
      const item = (d['item'] ?? {}) as ItemView & { seq?: number; nodeName?: string };
      const text = describeItem(item) + (item.nodeName ? ` (${item.nodeName})` : '');
      const fn = ev.type === 'item_added' ? h.itemAdded : ev.type === 'item_removed' ? h.itemRemoved : h.itemChanged;
      return fn(item.seq ?? 0, text);
    }
    case 'workflow': {
      const action = String(d['action'] ?? '');
      let word = h.workflow[action] ?? action;
      if (action === 'override' && d['decision']) word = `${word} (${h.overrideDecision(String(d['decision']))})`;
      return d['stage'] ? h.stage(word, String(d['stage'])) : word;
    }
    case 'policy': {
      const outcome = STRINGS.timeline.outcomes[String(d['outcome'] ?? '')] ?? String(d['outcome'] ?? '');
      return d['policy'] ? h.policy(String(d['policy']), outcome) : h.noPolicy;
    }
    default: return ev.type ?? '';
  }
}

/** The note, comment or failed checks that go with an event, if any. */
export function eventDetail(ev: RequestEvent): string | null {
  const d = (ev.data ?? {}) as Row;
  if (d['note']) return String(d['note']);
  if (d['comment']) return String(d['comment']);
  const checks = d['failedChecks'] as string[] | undefined;
  return checks && checks.length ? h.failedChecks(checks.join(', ')) : null;
}
