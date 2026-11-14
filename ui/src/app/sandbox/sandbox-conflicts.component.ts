import { ChangeDetectionStrategy, Component, input, output } from '@angular/core';
import { RouterLink } from '@angular/router';
import type { Conflict, JsonNode } from '../api/generated/models';
import { STRINGS } from '../core/strings';
import { DsButtonComponent, DsTableDirective } from '../shared/ds';

/**
 * `nx-sandbox-conflicts` (NEW-08, Phase 5 LLD §12): the sandbox's changes whose expected data no longer holds, what was
 * expected, what is there now and the request that changed it, with "Rebase" and "Remove change". Presentational: it
 * emits intents and the page's store does the work.
 */
@Component({
  selector: 'nx-sandbox-conflicts',
  imports: [DsButtonComponent, DsTableDirective, RouterLink],
  template: `
    <section class="conflicts" aria-labelledby="nx-conflicts-title" data-testid="sandbox-conflicts">
      <div class="head">
        <h2 id="nx-conflicts-title">{{ t.conflictsTitle }}</h2>
        @if (canChange()) {
          <ds-button [disabled]="busy()" (pressed)="rebase.emit()" data-testid="sandbox-rebase">{{ t.rebase }}</ds-button>
        }
      </div>
      @if (conflicts().length === 0) {
        <p class="nx-muted" data-testid="no-conflicts">{{ t.noConflicts }}</p>
      } @else {
        <p>{{ t.conflictsIntro }}</p>
        <table dsTable [attr.aria-label]="t.conflictsLabel">
          <thead>
            <tr>
              <th scope="col">{{ t.conflictColumns.change }}</th>
              <th scope="col">{{ t.conflictColumns.field }}</th>
              <th scope="col">{{ t.conflictColumns.expected }}</th>
              <th scope="col">{{ t.conflictColumns.actual }}</th>
              <th scope="col">{{ t.conflictColumns.by }}</th>
              @if (canChange()) {
                <th scope="col"><span class="nx-visually-hidden">{{ t.removeItem }}</span></th>
              }
            </tr>
          </thead>
          <tbody>
            @for (c of conflicts(); track c.itemId) {
              <tr [attr.data-seq]="c.seq">
                <td class="nx-identifier">{{ c.seq }}</td>
                <td>{{ c.field }}</td>
                <td><span class="change change--removed"><span aria-hidden="true">− </span>{{ text(c.expected) }}</span></td>
                <td><span class="change change--added"><span aria-hidden="true">+ </span>{{ text(c.actual) }}</span></td>
                <td>
                  @if (c.changedByRequest) {
                    <a [routerLink]="['/requests', c.changedByRequest]">{{ c.changedByRequest.slice(0, 8) }}</a>
                  } @else {
                    {{ t.unknownRequest }}
                  }
                </td>
                @if (canChange()) {
                  <td>
                    <ds-button variant="link" [disabled]="busy()" (pressed)="remove.emit(c.itemId!)">
                      {{ t.removeItem }}<span class="nx-visually-hidden"> {{ c.seq }}</span>
                    </ds-button>
                  </td>
                }
              </tr>
            }
          </tbody>
        </table>
      }
    </section>
  `,
  styles: `
    .head { display: flex; align-items: center; justify-content: space-between; gap: var(--nx-space-4); }
    .head h2 { margin: 0; }
    .change { padding: 0 var(--nx-space-2); border: var(--nx-border-width) solid currentcolor; border-radius: var(--nx-radius-1); }
    .change--removed { color: var(--nx-color-change-removed); }
    .change--added { color: var(--nx-color-change-added); }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class SandboxConflictsComponent {
  readonly conflicts = input.required<Conflict[]>();
  readonly canChange = input(false);
  readonly busy = input(false);
  readonly rebase = output<void>();
  readonly remove = output<string>();
  protected readonly t = STRINGS.sandbox;

  /** A JSON value as plain text: strings without quotes, nothing as an em dash, lists joined. */
  protected text(v: JsonNode | undefined): string {
    const value = v as unknown;
    if (value === null || value === undefined) return '—';
    if (typeof value === 'string') return value;
    if (Array.isArray(value)) return value.join(', ');
    return JSON.stringify(value);
  }
}
