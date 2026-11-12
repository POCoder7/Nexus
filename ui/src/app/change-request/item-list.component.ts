import { ChangeDetectionStrategy, Component, input, signal } from '@angular/core';
import type { Finding, ItemView } from '../api/generated/models';
import { STRINGS } from '../core/strings';
import { DsTableDirective } from '../shared/ds';
import { ChangeKind, afterText, beforeText, changeKind, describeItem } from './item-text';

const ICONS: Record<ChangeKind, string> = { added: '+', removed: '−', modified: '~', moved: '↷' };

/**
 * `nx-item-list`, the before/after view of a request (UI_STANDARD §5 diff / compare view; second scope extension):
 * side-by-side (a table of before and after) or inline (removed and added lines). Added, removed, changed and moved use the
 * change tokens plus an icon and a word, never colour alone. Findings about an item's node are shown on that item.
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
  protected readonly d = STRINGS.diff;
  protected readonly mode = signal<'side' | 'inline'>('side');

  protected readonly describe = describeItem;
  protected readonly before = beforeText;
  protected readonly after = afterText;
  protected readonly kind = changeKind;
  protected icon(item: ItemView): string {
    return ICONS[changeKind(item)];
  }
  protected kindLabel(item: ItemView): string {
    return this.d[changeKind(item)];
  }

  protected findingsFor(item: ItemView): Finding[] {
    return this.findings().filter((f) => !!f.nodeId && f.nodeId === item.nodeId);
  }
}
