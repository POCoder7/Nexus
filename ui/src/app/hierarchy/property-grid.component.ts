import { ChangeDetectionStrategy, Component, ElementRef, computed, inject, input, output } from '@angular/core';
import type { PropertyValue } from '../api/generated/models';
import { STRINGS } from '../core/strings';

export interface PropertyGroup {
  category: string;
  rows: PropertyValue[];
}

/**
 * `nx-property-grid` (LLD §3.3, UI_STANDARD §5): resolved properties grouped by category, each value with its provenance
 * marker (stored, inherited with a link to the source node, derived, default, not set) as icon + text + provenance token,
 * never colour alone. WAI-ARIA grid: arrow keys move between cells, Home/End within a row. Read-only in Phase 3.
 */
@Component({
  selector: 'nx-property-grid',
  templateUrl: './property-grid.component.html',
  styleUrl: './property-grid.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class PropertyGridComponent {
  readonly properties = input.required<PropertyValue[]>();
  readonly nodeName = input.required<string>();
  /** Names of source nodes for "Inherited from <node>" (resolved by the container). */
  readonly sourceNames = input<Record<string, string>>({});
  /** Offer "Edit" per value (scope extension); derived values are never editable. */
  readonly editable = input(false);
  readonly openSource = output<string>();
  readonly edit = output<PropertyValue>();
  protected readonly change = STRINGS.change;

  protected canEdit(p: PropertyValue): boolean {
    return this.editable() && p.provenance !== 'derived';
  }

  protected readonly t = STRINGS.properties;
  private readonly host = inject<ElementRef<HTMLElement>>(ElementRef);

  protected readonly groups = computed<PropertyGroup[]>(() => {
    const byCategory = new Map<string, PropertyValue[]>();
    for (const p of this.properties()) {
      const c = p.category ?? this.t.uncategorised;
      byCategory.set(c, [...(byCategory.get(c) ?? []), p]);
    }
    return [...byCategory.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([category, rows]) => ({ category, rows }));
  });

  protected display(p: PropertyValue): string {
    if (p.provenance === 'none') {
      return this.t.none;
    }
    const v = p.value as unknown;
    if (v === null || v === undefined) {
      return this.t.blank;
    }
    return typeof v === 'string' ? v : JSON.stringify(v);
  }

  protected marker(p: PropertyValue): { icon: string; text: string; tone: string } {
    switch (p.provenance) {
      case 'stored':
        return { icon: '●', text: this.t.stored, tone: 'stored' };
      case 'inherited':
        return { icon: '↑', text: this.t.inherited, tone: 'inherited' };
      case 'derived':
        return { icon: 'ƒ', text: this.t.derived, tone: 'derived' };
      case 'default':
        return { icon: '○', text: this.t.default, tone: 'default' };
      default:
        return { icon: '–', text: this.t.none, tone: 'default' };
    }
  }

  protected sourceName(p: PropertyValue): string {
    return (p.sourceNodeId && this.sourceNames()[p.sourceNodeId]) || p.sourceNodeId || '';
  }

  /** Grid navigation between focusable cells (roving tabindex). */
  protected onKeydown(event: KeyboardEvent): void {
    if ((event.target as HTMLElement).tagName === 'BUTTON' && (event.key === 'Enter' || event.key === ' ')) {
      return;   // let the Edit / source buttons inside a cell work
    }
    const cells = [...this.host.nativeElement.querySelectorAll<HTMLElement>('[role=gridcell], [role=columnheader]')];
    const current = cells.indexOf(document.activeElement as HTMLElement);
    if (current < 0) {
      return;
    }
    const columns = 3;
    let next = current;
    switch (event.key) {
      case 'ArrowRight': next = Math.min(current + 1, cells.length - 1); break;
      case 'ArrowLeft': next = Math.max(current - 1, 0); break;
      case 'ArrowDown': next = Math.min(current + columns, cells.length - 1); break;
      case 'ArrowUp': next = Math.max(current - columns, 0); break;
      case 'Home': next = current - (current % columns); break;
      case 'End': next = current - (current % columns) + columns - 1; break;
      default: return;
    }
    event.preventDefault();
    cells[current].tabIndex = -1;
    cells[next].tabIndex = 0;
    cells[next].focus();
  }
}
