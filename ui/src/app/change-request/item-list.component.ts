import { ChangeDetectionStrategy, Component, input } from '@angular/core';
import type { Finding, ItemView } from '../api/generated/models';
import { STRINGS } from '../core/strings';
import { DsTableDirective } from '../shared/ds';

/**
 * `nx-item-list` (LLD §3.2): the changes of a request as a simple "before → after" list per item (the diff view is not
 * built in Phase 3). Findings about an item's node are shown on that item, so a validation error appears next to the
 * change it is about.
 */
@Component({
  selector: 'nx-item-list',
  imports: [DsTableDirective],
  templateUrl: './item-list.component.html',
  styleUrl: './item-list.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class ItemListComponent {
  readonly items = input.required<ItemView[]>();
  readonly findings = input<Finding[]>([]);
  readonly label = input<string>(STRINGS.review.items);
  protected readonly t = STRINGS.review;

  protected describe(item: ItemView): string {
    const p = (item.payload ?? {}) as Record<string, unknown>;
    switch (item.action) {
      case 'add_node':
        return this.t.addNode(String(p['name'] ?? ''), !!p['isLeaf']);
      case 'set_property':
        return this.t.setProperty(item.propertyCode ?? '');
      case 'clear_property':
        return this.t.clearProperty(item.propertyCode ?? '');
      case 'insert_node':
        return this.t.insertNode;
      case 'move_node':
        return this.t.moveNode;
      case 'remove_node':
        return this.t.removeNode(!!p['cascade']);
      case 'delete_node':
        return this.t.deleteNode;
      case 'update_node':
        return this.t.updateNode;
      case 'add_hierarchy':
        return this.t.addHierarchy(String(p['code'] ?? ''));
      default:
        return item.action ?? '';
    }
  }

  protected before(item: ItemView): string {
    const b = item.before as Record<string, unknown> | null | undefined;
    if (!b || Object.keys(b).length === 0) {
      return item.action === 'add_node' ? this.t.newNode : STRINGS.common.none;
    }
    if ('value' in b) {
      return b['value'] === null ? STRINGS.properties.blank : String(b['value']);
    }
    if ('name' in b) {
      return String(b['name']);
    }
    return Object.entries(b).map(([k, v]) => `${k}: ${Array.isArray(v) ? v.length : String(v)}`).join(', ');
  }

  protected after(item: ItemView): string {
    const p = (item.payload ?? {}) as Record<string, unknown>;
    if (item.action === 'set_property') {
      return p['value'] === null ? STRINGS.properties.blank : String(p['value']);
    }
    if (item.action === 'add_node') {
      return String(p['name'] ?? '');
    }
    if (item.action === 'update_node') {
      return [p['name'], p['description']].filter((v) => v !== undefined).map((v) => (v === null ? STRINGS.properties.blank : String(v))).join(' · ');
    }
    if (item.action === 'add_hierarchy') {
      return String(p['name'] ?? '');
    }
    if (item.action === 'clear_property') {
      return STRINGS.properties.none;
    }
    if (item.action === 'move_node' || item.action === 'insert_node') {
      return item.targetParentId ? `→ ${item.targetParentId.slice(0, 8)}` : STRINGS.common.none;
    }
    return STRINGS.common.none;
  }

  protected findingsFor(item: ItemView): Finding[] {
    return this.findings().filter((f) => !!f.nodeId && f.nodeId === item.nodeId);
  }
}
