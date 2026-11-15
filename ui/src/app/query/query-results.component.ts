import { ChangeDetectionStrategy, Component, input, output } from '@angular/core';
import { RouterLink } from '@angular/router';
import type { JsonNode, QueryCell, QueryRow } from '../api/generated/models';
import { STRINGS } from '../core/strings';
import { DsButtonComponent, DsTableDirective } from '../shared/ds';

/**
 * `nx-query-results` (QRY-01, Phase 5 LLD §17.12): the matches with the chosen columns and where each value comes from.
 * A partial answer says so ("N matches so far…") and offers Continue; a full page offers Show more. Each name opens
 * the node in its hierarchy. Presentational.
 */
@Component({
  selector: 'nx-query-results',
  imports: [DsButtonComponent, DsTableDirective, RouterLink],
  template: `
    <section aria-labelledby="nx-query-results" data-testid="query-results">
      <h2 id="nx-query-results">{{ t.results }}</h2>
      <p role="status" data-testid="query-status">
        @if (partial()) {
          {{ t.soFar(rows().length, scanned()) }}
        } @else if (rows().length === 0) {
          {{ t.noResults }}
        } @else {
          {{ t.found(rows().length) }}{{ hasMore() ? '+' : '' }}
        }
      </p>
      @if (rows().length > 0) {
        <table dsTable [attr.aria-label]="t.resultsLabel">
          <thead>
            <tr>
              <th scope="col">{{ t.name }}</th>
              <th scope="col">{{ t.parent }}</th>
              @for (c of columns(); track c) {
                <th scope="col">{{ c }}</th>
              }
            </tr>
          </thead>
          <tbody>
            @for (r of rows(); track r.nodeId) {
              <tr [attr.data-node-id]="r.nodeId">
                <td><a [routerLink]="['/hierarchies', hierarchyCode()]" [queryParams]="{ node: r.nodeId }">{{ r.name }}</a></td>
                <td>{{ r.parentName ?? '—' }}</td>
                @for (c of columns(); track c; let i = $index) {
                  @let cell = r.columns?.[i];
                  <td>
                    {{ text(cell?.value) }}
                    @if (cell && cell.provenance !== 'stored') {
                      <span class="prov">{{ provenance(cell) }}</span>
                    }
                  </td>
                }
              </tr>
            }
          </tbody>
        </table>
      }
      @if (hasMore()) {
        <div class="more" [class.more--partial]="partial()">
          <ds-button [variant]="partial() ? 'primary' : 'secondary'" [disabled]="busy()" (pressed)="more.emit()" data-testid="query-more">
            {{ partial() ? t.continue : t.more }}
          </ds-button>
        </div>
      }
    </section>
  `,
  styles: `
    .prov { margin-left: var(--nx-space-2); font-size: var(--nx-font-size-label); color: var(--nx-color-text-secondary); }
    .more { margin-top: var(--nx-space-3); }
    .more--partial { padding: var(--nx-space-3); border: var(--nx-border-width) solid var(--nx-color-status-warning);
                     border-radius: var(--nx-radius-1); background: var(--nx-color-surface-banner); }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class QueryResultsComponent {
  readonly rows = input.required<QueryRow[]>();
  readonly columns = input<string[]>([]);
  readonly hierarchyCode = input<string | null>(null);
  readonly partial = input(false);
  readonly scanned = input(0);
  readonly hasMore = input(false);
  readonly busy = input(false);
  readonly more = output<void>();
  protected readonly t = STRINGS.queries;

  protected text(v: JsonNode | undefined): string {
    const value = v as unknown;
    if (value === null || value === undefined) return '—';
    if (Array.isArray(value)) return value.join(', ');
    return typeof value === 'object' ? JSON.stringify(value) : String(value);
  }

  protected provenance(c: QueryCell): string {
    return this.t.provenance[c.provenance ?? 'none'] ?? c.provenance ?? '';
  }
}
