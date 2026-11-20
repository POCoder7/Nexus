import { ChangeDetectionStrategy, Component, inject, signal } from '@angular/core';
import { NexusApi } from '../api/nexus-api';
import type { ValidationRuleView } from '../api/generated/models';
import { ContextStore } from '../core/context.store';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DsBadgeComponent, DsButtonComponent, DsDialog, DsTableDirective } from '../shared/ds';
import { RuleDialogComponent } from './rule-dialog.component';

const FILTERS = ['all', 'rule', 'guard'] as const;
type Filter = (typeof FILTERS)[number];

/**
 * Admin › Validation rules (ADR-046 D5, Phase 4 LLD §17.5): the one rule catalogue. Rules run when a request is
 * validated; database guards are enforced on every change and can only be relabelled. ADMIN edits; APPROVER reads.
 */
@Component({
  selector: 'nx-validation-rules-page',
  imports: [DsBadgeComponent, DsButtonComponent, DsTableDirective],
  template: `
    <section class="nx-page">
      <h1>{{ t.title }}</h1>
      <p class="nx-muted">{{ t.intro }}</p>
      <div class="chips" role="group" [attr.aria-label]="t.filtersLabel">
        @for (f of filters; track f) {
          <button type="button" class="chip" [attr.aria-pressed]="filter() === f" [attr.data-filter]="f" (click)="choose(f)">
            {{ t.filters[f] }}
          </button>
        }
      </div>
      @if (error(); as e) {
        <div class="nx-card" role="alert">
          <p class="nx-error-text">{{ e.status === 403 ? t.forbidden : e.detail }}</p>
          @if (e.status !== 403) {
            <ds-button (pressed)="load()">{{ common.retry }}</ds-button>
          }
        </div>
      } @else if (loading() && rows().length === 0) {
        <p class="nx-muted" role="status">{{ common.loading }}</p>
      } @else if (rows().length === 0) {
        <p class="nx-muted" role="status">{{ t.empty }}</p>
      } @else {
        <div class="scroll" tabindex="0" role="region" [attr.aria-label]="t.tableLabel">
          <table dsTable [attr.aria-busy]="loading()" data-testid="rules-table">
            <caption class="nx-visually-hidden">{{ t.tableLabel }}</caption>
            <thead>
              <tr>
                <th scope="col">{{ t.columns.code }}</th>
                <th scope="col">{{ t.columns.name }}</th>
                <th scope="col">{{ t.columns.kind }}</th>
                <th scope="col">{{ t.columns.level }}</th>
                <th scope="col">{{ t.columns.mode }}</th>
                <th scope="col">{{ t.columns.severity }}</th>
                <th scope="col">{{ t.columns.state }}</th>
                @if (canEdit()) {
                  <th scope="col">{{ t.columns.actions }}</th>
                }
              </tr>
            </thead>
            <tbody>
              @for (r of rows(); track r.code) {
                <tr [attr.data-rule]="r.code">
                  <th scope="row">
                    <span class="nx-identifier">{{ r.externalCode || r.code }}</span>
                    @if (r.externalCode) {
                      <span class="sub nx-muted nx-identifier">{{ r.code }}</span>
                    }
                  </th>
                  <td>
                    {{ r.name || r.code }}
                    @if (r.description) {
                      <span class="sub nx-muted">{{ r.description }}</span>
                    }
                  </td>
                  <td><ds-badge [tone]="r.enforcement === 'guard' ? 'info' : 'neutral'">{{ t.kinds[r.enforcement ?? ''] }}</ds-badge></td>
                  <td>{{ r.level }}</td>
                  <td>{{ t.modes[r.mode ?? ''] ?? r.mode }}</td>
                  <td>{{ t.severities[r.severity ?? ''] ?? r.severity }}</td>
                  <td>{{ r.enforcement === 'guard' ? t.guardNote : (r.active ? t.active : t.inactive) }}</td>
                  @if (canEdit()) {
                    <td>
                      <ds-button (pressed)="edit(r)">{{ t.edit }}<span class="nx-visually-hidden"> {{ r.externalCode || r.code }}</span></ds-button>
                    </td>
                  }
                </tr>
              }
            </tbody>
          </table>
        </div>
        @if (nextCursor()) {
          <ds-button [disabled]="loading()" (pressed)="more()">{{ t.loadMore }}</ds-button>
        }
      }
    </section>
  `,
  styles: `
    .chips { display: flex; flex-wrap: wrap; gap: var(--nx-space-3); margin-block: var(--nx-space-4); }
    .chip { padding: var(--nx-space-2) var(--nx-space-4); border: var(--nx-border-width) solid var(--nx-color-border-strong);
            border-radius: var(--nx-radius-2); background: var(--nx-color-surface-panel); color: var(--nx-color-text-primary);
            cursor: pointer; }
    .chip[aria-pressed="true"] { border-color: var(--nx-color-action-primary); background: var(--nx-color-surface-selected);
                                 font-weight: var(--nx-font-weight-strong); }
    .scroll { overflow-x: auto; }
    .sub { display: block; }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class ValidationRulesPage {
  private readonly api = inject(NexusApi);
  private readonly context = inject(ContextStore);
  private readonly dialog = inject(DsDialog);
  protected readonly t = STRINGS.rules;
  protected readonly common = STRINGS.common;
  protected readonly filters = FILTERS;
  protected readonly filter = signal<Filter>('all');
  protected readonly rows = signal<ValidationRuleView[]>([]);
  protected readonly nextCursor = signal<string | null>(null);
  protected readonly loading = signal(false);
  protected readonly error = signal<UiError | null>(null);
  protected readonly canEdit = () => this.context.can('ADMIN_SYSTEM');

  constructor() {
    void this.load();
  }

  protected choose(f: Filter): void {
    this.filter.set(f);
    void this.load();
  }

  protected async load(): Promise<void> {
    this.rows.set([]);
    this.nextCursor.set(null);
    await this.fetch(undefined);
  }

  protected async more(): Promise<void> {
    await this.fetch(this.nextCursor() ?? undefined);
  }

  protected edit(rule: ValidationRuleView): void {
    this.dialog.open<ValidationRuleView, ValidationRuleView, RuleDialogComponent>(RuleDialogComponent, rule, 'nx-rule-dialog-title')
      .closed.subscribe((saved) => {
        if (saved) {
          this.rows.update((rows) => rows.map((r) => (r.code === saved.code ? saved : r)));
        }
      });
  }

  private async fetch(cursor: string | undefined): Promise<void> {
    this.loading.set(true);
    this.error.set(null);
    try {
      const f = this.filter();
      const page = await this.api.validationRules(f === 'all' ? undefined : f, cursor);
      this.rows.update((rows) => [...rows, ...(page.items ?? [])]);
      this.nextCursor.set(page.nextCursor ?? null);
    } catch (e) {
      this.error.set(UiError.from(e));
    } finally {
      this.loading.set(false);
    }
  }
}
