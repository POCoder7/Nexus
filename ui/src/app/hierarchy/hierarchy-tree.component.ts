import { CdkVirtualScrollViewport, ScrollingModule } from '@angular/cdk/scrolling';
import { ChangeDetectionStrategy, Component, computed, effect, input, output, signal, viewChild } from '@angular/core';
import { CHILDREN_PAGE } from '../core/config';
import { STRINGS } from '../core/strings';
import { FlatTreeRow } from './tree.model';

/**
 * `nx-hierarchy-tree` (LLD §3.3, §7.1; UI_STANDARD §5): a WAI-ARIA tree over the flattened visible rows, rendered with a
 * CDK virtual viewport at a fixed row height, so only the rows in view exist in the DOM. Presentational: it emits
 * intents (expand, collapse, select, load more, retry) and the container's store does the work.
 *
 * Keyboard (WAI-ARIA tree): ↑/↓ move; → expands or moves to the first child; ← collapses or moves to the parent;
 * Home/End; Enter or Space selects; `*` expands loaded siblings; printable characters type ahead over visible rows.
 * Focus stays on the tree element and moves with `aria-activedescendant`, which works with virtual scrolling.
 */
@Component({
  selector: 'nx-hierarchy-tree',
  imports: [ScrollingModule],
  templateUrl: './hierarchy-tree.component.html',
  styleUrl: './hierarchy-tree.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class HierarchyTreeComponent {
  readonly rows = input.required<FlatTreeRow[]>();
  readonly selectedId = input<string | null>(null);
  readonly label = input.required<string>();
  readonly rowHeight = input(28);
  readonly idPrefix = input('nx-tree');

  readonly expand = output<string>();
  readonly collapse = output<string>();
  readonly select = output<string>();
  readonly loadMore = output<string>();
  readonly expandSiblings = output<string | null>();
  /** Mouse drag and drop of a node onto another node (UI_STANDARD §6: optional, never the only way; "Move to…" is). */
  readonly dragEnabled = input(false);
  readonly dropMove = output<{ nodeId: string; nodeName: string; targetId: string; targetName: string }>();
  protected readonly dropTarget = signal<string | null>(null);
  private dragged: { id: string; name: string } | null = null;

  protected onDragStart(event: DragEvent, row: FlatTreeRow): void {
    if (row.kind !== 'node') return;
    this.dragged = { id: row.id, name: row.name };
    event.dataTransfer?.setData('text/plain', row.id);
    if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move';
  }

  protected onDragOver(event: DragEvent, row: FlatTreeRow): void {
    if (this.dragged && row.kind === 'node' && row.id !== this.dragged.id) {
      event.preventDefault();   // allows the drop
      this.dropTarget.set(row.id);
    }
  }

  protected onDrop(event: DragEvent, row: FlatTreeRow): void {
    event.preventDefault();
    const dragged = this.dragged;
    this.dragged = null;
    this.dropTarget.set(null);
    if (dragged && row.kind === 'node' && row.id !== dragged.id) {
      this.dropMove.emit({ nodeId: dragged.id, nodeName: dragged.name, targetId: row.id, targetName: row.name });
    }
  }

  protected onDragEnd(): void {
    this.dragged = null;
    this.dropTarget.set(null);
  }

  protected readonly t = STRINGS.hierarchy;
  protected readonly common = STRINGS.common;
  protected readonly pageSize = CHILDREN_PAGE;
  private readonly viewport = viewChild(CdkVirtualScrollViewport);

  /** Index of the row that has keyboard focus (the active descendant). */
  protected readonly focusIndex = signal(0);
  private typeahead = '';
  private typeaheadTimer: ReturnType<typeof setTimeout> | null = null;

  protected readonly activeId = computed(() => {
    const row = this.rows()[this.focusIndex()];
    return row ? this.rowDomId(row) : null;
  });

  constructor() {
    // keep focus on the selected row when the selection changes from outside (search reveal, deep link)
    effect(() => {
      const id = this.selectedId();
      const rows = this.rows();
      if (id) {
        const index = rows.findIndex((r) => r.kind === 'node' && r.id === id);
        if (index >= 0 && index !== this.focusIndex()) {
          this.focusIndex.set(index);
          queueMicrotask(() => this.viewport()?.scrollToIndex(Math.max(0, index - 3)));
        }
      } else if (this.focusIndex() >= rows.length) {
        this.focusIndex.set(Math.max(0, rows.length - 1));
      }
    });
  }

  protected rowDomId(row: FlatTreeRow): string {
    return `${this.idPrefix()}-${row.key.replace(/[^A-Za-z0-9_-]/g, '_')}`;
  }

  protected trackRow(_: number, row: FlatTreeRow): string {
    return row.key;
  }

  protected activate(index: number): void {
    const row = this.rows()[index];
    this.focusIndex.set(index);
    if (!row) {
      return;
    }
    if (row.kind === 'node') {
      this.select.emit(row.id);
    } else if (row.kind === 'more' || row.kind === 'error') {
      this.loadMore.emit(row.parentId);
    }
  }

  protected toggle(row: FlatTreeRow, index: number, event: Event): void {
    event.stopPropagation();
    this.focusIndex.set(index);
    if (row.kind === 'node' && row.hasChildren) {
      (row.expanded ? this.collapse : this.expand).emit(row.id);
    }
  }

  protected onKeydown(event: KeyboardEvent): void {
    const rows = this.rows();
    if (rows.length === 0) {
      return;
    }
    const i = Math.min(this.focusIndex(), rows.length - 1);
    const row = rows[i];
    // during a type-ahead, Space is part of the text being typed (WAI-ARIA tree), not "select"
    if (event.key === ' ' && this.typeahead.length > 0) {
      this.typeAhead(' ', i);
      event.preventDefault();
      return;
    }
    switch (event.key) {
      case 'ArrowDown':
        this.moveTo(Math.min(i + 1, rows.length - 1));
        break;
      case 'ArrowUp':
        this.moveTo(Math.max(i - 1, 0));
        break;
      case 'Home':
        this.moveTo(0);
        break;
      case 'End':
        this.moveTo(rows.length - 1);
        break;
      case 'ArrowRight':
        if (row.kind === 'node' && row.hasChildren) {
          if (!row.expanded) {
            this.expand.emit(row.id);
          } else if (i + 1 < rows.length) {
            this.moveTo(i + 1);
          }
        }
        break;
      case 'ArrowLeft':
        if (row.kind === 'node' && row.expanded) {
          this.collapse.emit(row.id);
        } else {
          const parentId = row.parentId;
          const parentIndex = rows.findIndex((r) => r.kind === 'node' && r.id === parentId);
          if (parentIndex >= 0) {
            this.moveTo(parentIndex);
          }
        }
        break;
      case 'Enter':
      case ' ':
        this.activate(i);
        break;
      case '*':
        this.expandSiblings.emit(row.kind === 'node' ? row.parentId : row.parentId);
        break;
      default:
        if (event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey) {
          this.typeAhead(event.key, i);
          break;
        }
        return;
    }
    event.preventDefault();
  }

  private moveTo(index: number): void {
    this.focusIndex.set(index);
    const viewport = this.viewport();
    if (!viewport) {
      return;
    }
    const range = viewport.getRenderedRange();
    if (index < range.start + 1 || index > range.end - 2) {
      viewport.scrollToIndex(Math.max(0, index - 2));
    }
  }

  /** Type-ahead over visible node rows: the next row (after the current one) whose name starts with the typed text. */
  private typeAhead(char: string, from: number): void {
    this.typeahead += char.toLowerCase();
    if (this.typeaheadTimer) {
      clearTimeout(this.typeaheadTimer);
    }
    this.typeaheadTimer = setTimeout(() => (this.typeahead = ''), 600);
    const rows = this.rows();
    const start = this.typeahead.length === 1 ? from + 1 : from;
    for (let k = 0; k < rows.length; k++) {
      const index = (start + k) % rows.length;
      const row = rows[index];
      if (row.kind === 'node' && row.name.toLowerCase().startsWith(this.typeahead)) {
        this.moveTo(index);
        return;
      }
    }
  }
}
