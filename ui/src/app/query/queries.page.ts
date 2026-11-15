import { ChangeDetectionStrategy, Component, computed, inject, signal } from '@angular/core';
import type { SavedQueryView } from '../api/generated/models';
import { Announcer } from '../core/announcer';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DsButtonComponent, DsFieldComponent, DsToast } from '../shared/ds';
import { QueryBuilderComponent, QueryEdit, numberConditions } from './query-builder.component';
import { addCondition, addGroup, patchCondition, removeAt, setMode } from './query-model';
import { QueryResultsComponent } from './query-results.component';
import { QueryStore } from './query.store';

/**
 * Queries (QRY-01, Phase 5 LLD §17.12): choose a hierarchy, build conditions in AND/OR groups, pick columns, run, and
 * save or share the query. Results are read at the context bar's date and show only what the user may read; a shared
 * query runs with the reader's own access.
 */
@Component({
  selector: 'nx-queries-page',
  imports: [QueryBuilderComponent, QueryResultsComponent, DsButtonComponent, DsFieldComponent],
  providers: [QueryStore],
  template: `
    <section class="nx-page layout">
      <div class="main">
        <h1>{{ t.title }}</h1>
        <p class="nx-muted">{{ t.intro }}</p>
        @if (store.loadError(); as e) {
          <div class="nx-card" role="alert">
            <p class="nx-error-text">{{ e.detail }}</p>
            <ds-button (pressed)="store.load()">{{ common.retry }}</ds-button>
          </div>
        }
        <form class="nx-card definition" (submit)="$event.preventDefault(); run()" [attr.aria-label]="t.title">
          <div class="row">
            <ds-field [label]="t.hierarchy" for="nx-query-hierarchy">
              <select id="nx-query-hierarchy" [value]="store.hierarchyCode() ?? ''" (change)="store.hierarchyCode.set($any($event.target).value || null)"
                      data-testid="query-hierarchy">
                @if (!store.hierarchyCode()) {
                  <option value="">{{ t.chooseHierarchy }}</option>
                }
                @for (h of store.hierarchies(); track h.code) {
                  <option [value]="h.code" [selected]="h.code === store.hierarchyCode()">{{ h.name }}</option>
                }
              </select>
            </ds-field>
            <ds-field [label]="t.include" for="nx-query-include">
              <select id="nx-query-include" (change)="store.include.set($any($event.target).value)">
                @for (k of includes; track k) {
                  <option [value]="k" [selected]="k === store.include()">{{ t.includes[k] }}</option>
                }
              </select>
            </ds-field>
            <label class="check"><input type="checkbox" [checked]="store.includeInactive()"
                                        (change)="store.includeInactive.set($any($event.target).checked)" /> {{ t.includeInactive }}</label>
          </div>

          <nx-query-builder [group]="store.root()" [fields]="store.fields()" [numbers]="numbers()" (edit)="apply($event)" />

          <ds-field [label]="t.columns" for="nx-query-columns" [hint]="t.columnsHint">
            <select id="nx-query-columns" multiple size="6" (change)="chooseColumns($any($event.target))" data-testid="query-columns">
              @for (f of propertyFields(); track f.key) {
                <option [value]="f.property" [selected]="store.columns().includes(f.property!)">{{ f.label }}</option>
              }
            </select>
          </ds-field>

          @if (store.problems().length > 0 && tried()) {
            <ul class="nx-error-text" role="alert" data-testid="query-problems">
              @for (p of store.problems(); track p) {
                <li>{{ p }}</li>
              }
            </ul>
          }
          <ds-button variant="primary" type="submit" [disabled]="store.running()" data-testid="query-run">
            {{ store.running() ? t.running : t.run }}
          </ds-button>
          @if (store.error(); as e) {
            <p class="nx-error-text" role="alert" data-testid="query-error">{{ e.detail }}</p>
          }
        </form>

        @if (store.ran()) {
          <nx-query-results [rows]="store.rows()" [columns]="store.columnsShown()" [hierarchyCode]="store.hierarchyCode()"
                            [partial]="store.partial()" [scanned]="store.scanned()" [hasMore]="store.hasMore()"
                            [busy]="store.running()" (more)="store.more()" />

          <form class="nx-card save" (submit)="$event.preventDefault(); save(false)" [attr.aria-label]="t.saveTitle">
            <h2>{{ t.saveTitle }}</h2>
            <ds-field [label]="t.saveName" for="nx-query-name" [required]="true" [requiredText]="common.required">
              <input id="nx-query-name" autocomplete="off" [value]="name()" (input)="name.set($any($event.target).value)"
                     data-testid="query-save-name" />
            </ds-field>
            <label class="check"><input type="checkbox" [checked]="shared()" (change)="shared.set($any($event.target).checked)"
                                        data-testid="query-share" /> {{ t.shareIt }}</label>
            <ds-button variant="primary" type="submit" [disabled]="busy() || !name().trim()" data-testid="query-save">
              {{ store.current() ? t.saveChanges : t.save }}
            </ds-button>
            @if (store.current()) {
              <ds-button [disabled]="busy() || !name().trim()" (pressed)="save(true)">{{ t.saveAsNew }}</ds-button>
            }
            @if (saveError(); as e) {
              <p class="nx-error-text" role="alert">{{ e.detail }}</p>
            }
          </form>
        }
      </div>

      <aside class="saved" [attr.aria-label]="t.savedLabel">
        <h2>{{ t.saved }}</h2>
        @if (store.saved().length === 0) {
          <p class="nx-muted">{{ t.noSaved }}</p>
        } @else {
          <ul data-testid="saved-queries">
            @for (q of store.saved(); track q.id) {
              <li [attr.data-saved]="q.name">
                <ds-button variant="link" (pressed)="open(q)">{{ q.name }}<span class="nx-visually-hidden">: {{ t.open(q.name ?? '') }}</span></ds-button>
                @if (q.visibility === 'shared') {
                  <span class="tag">{{ t.shared }}</span>
                }
                @if (q.mine) {
                  <ds-button variant="link" (pressed)="remove(q)"><span aria-hidden="true">✕</span><span class="nx-visually-hidden">{{ t.deleteSaved(q.name ?? '') }}</span></ds-button>
                }
              </li>
            }
          </ul>
        }
        @if (openedShared()) {
          <p class="nx-muted" role="note">{{ t.notYours }}</p>
        }
      </aside>
    </section>
  `,
  styles: `
    .layout { display: grid; grid-template-columns: minmax(0, 1fr) 16rem; gap: var(--nx-space-6); align-items: start; }
    .definition, .save { display: flex; flex-direction: column; gap: var(--nx-space-4); margin: var(--nx-space-4) 0; }
    .row { display: flex; flex-wrap: wrap; align-items: flex-end; gap: var(--nx-space-4); }
    .check { display: inline-flex; align-items: center; gap: var(--nx-space-2); }
    .save h2 { margin: 0; }
    /* buttons keep their own width in the column forms (a stretched host is a dead click area beside the button) */
    .definition > ds-button, .save > ds-button { align-self: flex-start; }
    .saved ul { display: flex; flex-direction: column; gap: var(--nx-space-2); margin: 0; padding: 0; list-style: none; }
    .tag { padding: 0 var(--nx-space-2); border: var(--nx-border-width) solid var(--nx-color-border-default);
           border-radius: var(--nx-radius-1); font-size: var(--nx-font-size-label); color: var(--nx-color-text-secondary); }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class QueriesPage {
  protected readonly store = inject(QueryStore);
  private readonly toast = inject(DsToast);
  private readonly announcer = inject(Announcer);
  protected readonly t = STRINGS.queries;
  protected readonly common = STRINGS.common;
  protected readonly includes = ['all', 'leaves', 'limbs'] as const;

  protected readonly numbers = computed(() => numberConditions(this.store.root()));
  protected readonly propertyFields = computed(() => this.store.fields().filter((f) => !!f.property));
  protected readonly tried = signal(false);
  protected readonly name = signal('');
  protected readonly shared = signal(false);
  protected readonly busy = signal(false);
  protected readonly saveError = signal<UiError | null>(null);
  protected readonly openedShared = signal(false);

  constructor() {
    void this.store.load();
  }

  protected apply(e: QueryEdit): void {
    const fields = this.store.fields();
    const root = this.store.root();
    switch (e.type) {
      case 'addCondition':
        if (fields.length > 0) this.store.root.set(addCondition(root, e.path, fields[0]));
        break;
      case 'addGroup':
        this.store.root.set(addGroup(root, e.path));
        break;
      case 'remove':
        this.store.root.set(removeAt(root, e.path));
        break;
      case 'mode':
        this.store.root.set(setMode(root, e.path, e.mode));
        break;
      case 'patch':
        this.store.root.set(patchCondition(root, e.path, e.patch, fields));
        break;
    }
  }

  protected chooseColumns(select: HTMLSelectElement): void {
    this.store.columns.set(Array.from(select.selectedOptions).map((o) => o.value));
  }

  protected async run(): Promise<void> {
    this.tried.set(true);
    if (!this.store.canRun()) {
      return;
    }
    await this.store.run();
    const error = this.store.error();
    this.announcer.polite(error ? error.detail : this.store.partial()
      ? this.t.soFar(this.store.rows().length, this.store.scanned()) : this.t.found(this.store.rows().length));
  }

  protected open(q: SavedQueryView): void {
    this.store.open(q);
    this.name.set(q.name ?? '');
    this.shared.set(q.visibility === 'shared');
    this.openedShared.set(!q.mine);
    void this.run();
  }

  protected async save(asNew: boolean): Promise<void> {
    this.busy.set(true);
    this.saveError.set(null);
    try {
      const q = await this.store.save(this.name().trim(), this.shared(), asNew);
      const done = this.t.savedDone(q.name ?? '');
      this.toast.confirm(done);
      this.announcer.polite(done);
      this.openedShared.set(false);
    } catch (e) {
      const error = UiError.from(e);
      this.saveError.set(error);
      this.announcer.assertive(error.detail);
    } finally {
      this.busy.set(false);
    }
  }

  protected async remove(q: SavedQueryView): Promise<void> {
    try {
      await this.store.remove(q);
      const done = this.t.deleted(q.name ?? '');
      this.toast.confirm(done);
      this.announcer.polite(done);
    } catch (e) {
      this.announcer.assertive(UiError.from(e).detail);
    }
  }
}
