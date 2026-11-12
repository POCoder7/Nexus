import type { ItemView } from '../api/generated/models';
import { STRINGS } from '../core/strings';

/** How one change item is worded in the before/after views (one place for both modes). */
export type ChangeKind = 'added' | 'removed' | 'modified' | 'moved';

const t = STRINGS.review;

export function changeKind(item: ItemView): ChangeKind {
  switch (item.action) {
    case 'add_node':
    case 'add_hierarchy':
    case 'insert_node':
      return 'added';
    case 'remove_node':
    case 'delete_node':
    case 'clear_property':
      return 'removed';
    case 'move_node':
      return 'moved';
    default:
      return 'modified';
  }
}

export function describeItem(item: ItemView): string {
  const p = (item.payload ?? {}) as Record<string, unknown>;
  switch (item.action) {
    case 'add_node': return t.addNode(String(p['name'] ?? ''), !!p['isLeaf']);
    case 'set_property': return t.setProperty(item.propertyCode ?? '');
    case 'clear_property': return t.clearProperty(item.propertyCode ?? '');
    case 'insert_node': return t.insertNode;
    case 'move_node': return t.moveNode;
    case 'remove_node': return t.removeNode(!!p['cascade']);
    case 'delete_node': return t.deleteNode;
    case 'update_node': return t.updateNode;
    case 'add_hierarchy': return t.addHierarchy(String(p['code'] ?? ''));
    default: return item.action ?? '';
  }
}

export function beforeText(item: ItemView): string {
  const b = item.before as Record<string, unknown> | null | undefined;
  if (!b || Object.keys(b).length === 0) {
    return item.action === 'add_node' ? t.newNode : STRINGS.common.none;
  }
  if ('value' in b) {
    return b['present'] === false ? STRINGS.properties.none : b['value'] === null ? STRINGS.properties.blank : String(b['value']);
  }
  if ('name' in b) {
    return [b['name'], b['description']].filter((v) => v !== undefined && v !== null).map(String).join(' · ');
  }
  if ('parentIds' in b) {
    const n = Array.isArray(b['parentIds']) ? b['parentIds'].length : 0;
    return `${n} ${n === 1 ? 'parent' : 'parents'}`;
  }
  return Object.entries(b).map(([k, v]) => `${k}: ${Array.isArray(v) ? v.length : String(v)}`).join(', ');
}

export function afterText(item: ItemView): string {
  const p = (item.payload ?? {}) as Record<string, unknown>;
  switch (item.action) {
    case 'set_property':
      return p['value'] === null ? STRINGS.properties.blank : String(p['value']);
    case 'add_node':
    case 'add_hierarchy':
      return String(p['name'] ?? '');
    case 'update_node':
      return [p['name'], p['description']].filter((v) => v !== undefined).map((v) => (v === null ? STRINGS.properties.blank : String(v))).join(' · ');
    case 'clear_property':
      return STRINGS.properties.none;
    case 'move_node':
    case 'insert_node':
      return item.targetParentId ? `→ ${item.targetParentId.slice(0, 8)}` : STRINGS.common.none;
    case 'remove_node':
    case 'delete_node':
      return STRINGS.common.none;
    default:
      return STRINGS.common.none;
  }
}
