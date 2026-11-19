import { ChangeDetectionStrategy, Component, computed, input, model, output } from '@angular/core';
import type { CompareRow } from '../api/generated/models';
import { STRINGS } from '../core/strings';
import { DsButtonComponent, DsTab, DsTableDirective, DsTabsComponent } from '../shared/ds';
import { changeText, leftText, propertyOf, rightText, toneOf } from './compare-text';

const ICONS: Record<string, string> = { added: '+', removed: '−', moved: '⇄', modified: '✎' };

/**
 * `nx-compare-results` (Phase 5 LLD §17.12; UI_STANDARD §5 diff view): one tab per kind with its count, and a table of
 * differences with left and right side by side. Each change is drawn with its change token and an icon, and named in
 * words, so colour is never the only signal. Presentational: the page loads the rows of the selected kind.
 */
@Component({
  selector: 'nx-compare-results',
  imports: [DsTabsComponent, DsTableDirective, DsButtonComponent],
  template: `
    <ds-tabs [tabs]="tabs()" [label]="t.resultsLabel" idPrefix="nx-compare-tab" [(selected)]="kind">
      @if (rows().length === 0 && !loading()) {
        <p class="nx-muted" role="status" data-testid="compare-none">{{ t.noDifferences }}</p>
      } @else {
        <div class="scroll" tabindex="0" role="region" [attr.aria-label]="t.resultsLabel">
          <table dsTable [attr.aria-busy]="loading()" data-testid="compare-table">
            <caption class="nx-visually-hidden">{{ t.resultsLabel }}</caption>
            <thead>
              <tr>
                <th scope="col">{{ t.columns.node }}</th>
                <th scope="col">{{ t.columns.change }}</th>
                <th scope="col">{{ leftLabel() }}</th>
                <th scope="col">{{ rightLabel() }}</th>
              </tr>
            </thead>
            <tbody>
              @for (r of rows(); track $index) {
                <tr [attr.data-change]="tone(r)" [attr.data-node-id]="r.nodeId">
                  <th scope="row">
                    {{ r.nodeName }}
                    @if (property(r); as p) {
                      <span class="property nx-muted">{{ p }}</span>
                    }
                  </th>
                  <td><span class="change change--{{ tone(r) }}"><span aria-hidden="true">{{ icon(r) }} </span>{{ change(r) }}</span></td>
                  <td class="side side--left">{{ left(r) }}</td>
                  <td class="side side--right">{{ right(r) }}</td>
                </tr>
              }
            </tbody>
          </table>
        </div>
        @if (hasMore()) {
          <div class="more"><ds-button [disabled]="loading()" (pressed)="loadMore.emit()" data-testid="compare-more">{{ t.showMore }}</ds-button></div>
        }
      }
    </ds-tabs>
  `,
  styles: `
    .scroll { overflow-x: auto; border: var(--nx-border-width) solid var(--nx-color-border-default); border-radius: var(--nx-radius-1); }
    .property { display: block; font-weight: var(--nx-font-weight-regular); font-size: var(--nx-font-size-label); }
    .change { font-weight: var(--nx-font-weight-strong); white-space: nowrap; }
    .change--added { color: var(--nx-color-change-added); }
    .change--removed { color: var(--nx-color-change-removed); }
    .change--modified { color: var(--nx-color-change-modified); }
    .change--moved { color: var(--nx-color-change-moved); }
    tr[data-change=added] .side--right, tr[data-change=removed] .side--left { font-weight: var(--nx-font-weight-strong); }
    .more { display: flex; justify-content: center; margin-block-start: var(--nx-space-4); }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class CompareResultsComponent {
  /** Rows per kind, from the run: the tabs show them as counts. */
  readonly counts = input<Record<string, number>>({});
  readonly kinds = input<string[]>(['structure', 'property', 'rename']);
  readonly rows = input.required<CompareRow[]>();
  readonly loading = input(false);
  readonly hasMore = input(false);
  readonly leftLabel = input<string>(STRINGS.compare.left);
  readonly rightLabel = input<string>(STRINGS.compare.right);
  /** The selected kind (two-way); the page loads its rows. */
  readonly kind = model<string>('');
  readonly loadMore = output<void>();
  protected readonly t = STRINGS.compare;

  protected readonly tabs = computed<DsTab[]>(() =>
    this.kinds().map((k) => ({ id: k, label: this.t.countLabel(this.t.kindNames[k] ?? k, this.counts()[k] ?? 0) })));

  protected readonly tone = toneOf;
  protected readonly change = changeText;
  protected readonly left = leftText;
  protected readonly right = rightText;
  protected readonly property = propertyOf;
  protected icon(r: CompareRow): string {
    return ICONS[toneOf(r)];
  }
}
