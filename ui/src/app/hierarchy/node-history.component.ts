import { ChangeDetectionStrategy, Component, effect, inject, input, signal, untracked } from '@angular/core';
import { RouterLink } from '@angular/router';
import { NexusApi } from '../api/nexus-api';
import type { HistoryEvent } from '../api/generated/models';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DsBadgeComponent, DsButtonComponent } from '../shared/ds';
import { NxDatePipe, NxInstantPipe, formatBusinessDate } from '../shared/format/nx-date.pipe';

/**
 * History tab (QRY-04; second scope extension): every recorded version of the node's details, placements and property
 * values, newest recorded first, each with its valid period, when it was recorded or superseded, and the change request
 * that wrote it. Read-only; pages with "Show more" (keyset).
 */
@Component({
  selector: 'nx-node-history',
  imports: [RouterLink, DsBadgeComponent, DsButtonComponent, NxDatePipe, NxInstantPipe],
  templateUrl: './node-history.component.html',
  styleUrl: './node-history.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class NodeHistoryComponent {
  readonly nodeId = input.required<string>();
  readonly nodeName = input('');
  readonly hierarchyCode = input<string | null>(null);

  private readonly api = inject(NexusApi);
  protected readonly t = STRINGS.history;
  protected readonly common = STRINGS.common;
  protected readonly events = signal<HistoryEvent[]>([]);
  protected readonly cursor = signal<string | null>(null);
  protected readonly loading = signal(false);
  protected readonly error = signal<UiError | null>(null);
  private generation = 0;

  constructor() {
    effect(() => {
      const id = this.nodeId();
      const code = this.hierarchyCode();
      untracked(() => void this.load(id, code, undefined));
    });
  }

  protected async load(id: string, code: string | null, cursor: string | undefined): Promise<void> {
    const generation = cursor ? this.generation : ++this.generation;
    this.loading.set(true);
    this.error.set(null);
    try {
      const page = await this.api.history(id, code ?? undefined, cursor);
      if (generation !== this.generation) return;
      this.events.update((e) => (cursor ? [...e, ...(page.items ?? [])] : page.items ?? []));
      this.cursor.set(page.nextCursor ?? null);
    } catch (e) {
      if (generation === this.generation) this.error.set(UiError.from(e));
    } finally {
      if (generation === this.generation) this.loading.set(false);
    }
  }

  protected more(): void {
    const c = this.cursor();
    if (c) void this.load(this.nodeId(), this.hierarchyCode(), c);
  }

  protected validText(e: HistoryEvent): string {
    return this.t.valid(formatBusinessDate(e.validFrom), e.validTo ? formatBusinessDate(e.validTo) : this.t.open);
  }

  protected summary(e: HistoryEvent): string {
    switch (e.kind) {
      case 'attribute':
        return [e.name, e.description, e.allowsChildren === false ? this.t.leaf : null, e.active === false ? this.t.inactive : null]
          .filter((x) => !!x).join(' · ');
      case 'placement':
        return `${this.t.under(e.parentName ?? e.parentId ?? '', e.hierarchyCode ?? '')} (${e.primary ? this.t.primary : this.t.shared})`;
      default: {
        const v = e.value as unknown;
        const shown = v === null || v === undefined ? this.t.blank : typeof v === 'string' ? v : JSON.stringify(v);
        return `${e.propertyLabel ?? e.propertyCode}: ${shown}${e.hierarchyCode ? ` (${e.hierarchyCode})` : ''}`;
      }
    }
  }

  protected track(i: number, e: HistoryEvent): string {
    return `${e.kind}-${e.recordedFrom}-${e.validFrom}-${e.propertyCode ?? ''}-${e.parentId ?? ''}-${i}`;
  }
}
