import { ChangeDetectionStrategy, Component, input, output } from '@angular/core';
import { RouterLink } from '@angular/router';
import type { AuditEntry } from '../api/generated/models';
import { STRINGS } from '../core/strings';
import { DsBadgeComponent, DsButtonComponent, DsTableDirective, DsTone } from '../shared/ds';
import { NxDatePipe, NxInstantPipe } from '../shared/format/nx-date.pipe';
import { changeText, kindText, whatText } from './audit-text';

const TONES: Record<string, DsTone> = { stated: 'info', superseded: 'neutral', restated: 'neutral', created: 'success',
  updated: 'info', deleted: 'warning' };

/**
 * `nx-audit-table` (Phase 5 LLD §18.7; AUD-01): one row per recorded change, newest first, with the change in words
 * (before → after), the node and request as links, and who requested and approved it. Presentational.
 */
@Component({
  selector: 'nx-audit-table',
  imports: [RouterLink, DsBadgeComponent, DsButtonComponent, DsTableDirective, NxDatePipe, NxInstantPipe],
  template: `
    @if (rows().length === 0 && !loading()) {
      <p class="empty" role="status" data-testid="audit-empty">{{ t.empty }}</p>
    } @else {
      <div class="scroll" tabindex="0" role="region" [attr.aria-label]="t.tableLabel">
        <table dsTable [attr.aria-busy]="loading()" data-testid="audit-table">
          <caption class="nx-visually-hidden">{{ t.tableLabel }}</caption>
          <thead>
            <tr>
              <th scope="col">{{ t.columns.when }}</th>
              <th scope="col">{{ t.columns.what }}</th>
              <th scope="col">{{ t.columns.change }}</th>
              <th scope="col">{{ t.columns.node }}</th>
              <th scope="col">{{ t.columns.hierarchy }}</th>
              <th scope="col">{{ t.columns.request }}</th>
              <th scope="col">{{ t.columns.requestedBy }}</th>
              <th scope="col">{{ t.columns.approvedBy }}</th>
            </tr>
          </thead>
          <tbody>
            @for (e of rows(); track e.id) {
              <tr [attr.data-entry]="e.id" [attr.data-kind]="e.kind">
                <td class="when">{{ e.occurredAt | nxInstant: timeZone() }}</td>
                <th scope="row" class="what">
                  {{ what(e) }}
                  <ds-badge [tone]="tone(e.kind)">{{ kind(e) }}</ds-badge>
                </th>
                <td data-testid="audit-change">
                  {{ change(e) }}
                  @if (e.validFrom) {
                    <span class="nx-muted">{{ t.validFrom((e.validFrom | nxDate) ?? '') }}</span>
                  }
                </td>
                <td>
                  @if (e.nodeId && e.hierarchyCode) {
                    <a [routerLink]="['/hierarchies', e.hierarchyCode]" [queryParams]="{ node: e.nodeId }">{{ e.nodeName ?? e.nodeId }}</a>
                  } @else {
                    {{ e.nodeName ?? '' }}
                  }
                </td>
                <td>{{ e.hierarchyCode ?? '' }}</td>
                <td>
                  @if (e.changeRequestId) {
                    <a [routerLink]="['/requests', e.changeRequestId]">{{ e.changeRequestTitle ?? e.changeRequestId }}</a>
                  }
                </td>
                <td>{{ e.requestedBy ?? '' }}</td>
                <td>{{ e.decisionBasis === 'approved_policy' ? t.byPolicy : (e.decidedBy ?? '') }}</td>
              </tr>
            }
          </tbody>
        </table>
      </div>
      @if (hasMore()) {
        <div class="more">
          <ds-button [disabled]="loading()" (pressed)="loadMore.emit()" data-testid="audit-more">{{ t.showMore }}</ds-button>
        </div>
      }
    }
  `,
  styles: `
    .scroll { position: relative; overflow-x: auto; border: var(--nx-border-width) solid var(--nx-color-border-default);
              border-radius: var(--nx-radius-1); }
    .what { font-weight: var(--nx-font-weight-strong); color: var(--nx-color-text-primary); }
    .what ds-badge { display: block; margin-block-start: var(--nx-space-1); }
    .when { white-space: nowrap; }
    td .nx-muted { display: block; font-size: var(--nx-font-size-label); }
    .more { display: flex; justify-content: center; margin-block-start: var(--nx-space-4); }
    .empty { margin: 0; }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class AuditTableComponent {
  readonly rows = input.required<AuditEntry[]>();
  readonly loading = input(false);
  readonly hasMore = input(false);
  readonly timeZone = input<string | undefined>(undefined);
  readonly loadMore = output<void>();
  protected readonly t = STRINGS.audit;

  protected readonly what = whatText;
  protected readonly change = changeText;
  protected readonly kind = kindText;

  protected tone(kind: string | undefined): DsTone {
    return TONES[kind ?? ''] ?? 'neutral';
  }
}
