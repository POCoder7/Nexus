import { ChangeDetectionStrategy, Component, computed, effect, inject, input, signal, untracked } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Router } from '@angular/router';
import { AuditFilters, NexusApi } from '../api/nexus-api';
import type { AuditEntry, HierarchySummary, PropertyDefinitionView, VersionView } from '../api/generated/models';
import { Announcer } from '../core/announcer';
import { ContextStore } from '../core/context.store';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DsButtonComponent, DsFieldComponent } from '../shared/ds';
import { AuditTableComponent } from './audit-table.component';

const ADMIN_CATEGORIES = ['requests', 'definitions', 'access', 'configuration'];

/**
 * Audit (Phase 5 LLD §18.7; AUD-01): the transaction history. The filters are the URL's query parameters, so a search can
 * be shared as a link; "Search" writes them, and the page reads them. Everyone who can read a hierarchy sees its data
 * changes; the other categories are offered to ADMINs only. The server decides what each user sees.
 */
@Component({
  selector: 'nx-audit-page',
  imports: [FormsModule, AuditTableComponent, DsButtonComponent, DsFieldComponent],
  template: `
    <section class="nx-page">
      <h1>{{ t.title }}</h1>
      <p class="nx-muted">{{ t.intro }}</p>
      <form class="filters" [attr.aria-label]="t.filtersLabel" (submit)="$event.preventDefault(); search()">
        <ds-field [label]="t.from" for="nx-audit-from"><input id="nx-audit-from" type="date" name="from" [(ngModel)]="form.from" /></ds-field>
        <ds-field [label]="t.to" for="nx-audit-to"><input id="nx-audit-to" type="date" name="to" [(ngModel)]="form.to" /></ds-field>
        <ds-field [label]="t.user" for="nx-audit-user"><input id="nx-audit-user" name="user" autocomplete="off" [(ngModel)]="form.user" /></ds-field>
        <ds-field [label]="t.version" for="nx-audit-version">
          <select id="nx-audit-version" name="version" [(ngModel)]="form.version">
            <option value="">{{ t.allVersions }}</option>
            @for (v of versions(); track v.name) {
              <option [value]="v.name">{{ v.name }}</option>
            }
          </select>
        </ds-field>
        <ds-field [label]="t.hierarchy" for="nx-audit-hierarchy">
          <select id="nx-audit-hierarchy" name="hierarchy" [(ngModel)]="form.hierarchy">
            <option value="">{{ t.allHierarchies }}</option>
            @for (h of hierarchies(); track h.code) {
              <option [value]="h.code">{{ h.name }} ({{ h.code }})</option>
            }
          </select>
        </ds-field>
        <ds-field [label]="t.property" for="nx-audit-property">
          <select id="nx-audit-property" name="property" [(ngModel)]="form.property">
            <option value="">{{ t.allProperties }}</option>
            @for (g of propertyGroups(); track g.category) {
              <optgroup [label]="g.category">
                @for (p of g.properties; track p.code) {
                  <option [value]="p.code">{{ p.label || p.code }}</option>
                }
              </optgroup>
            }
          </select>
        </ds-field>
        <ds-field [label]="t.node" for="nx-audit-node"><input id="nx-audit-node" name="node" autocomplete="off" [(ngModel)]="form.node" /></ds-field>
        <ds-field [label]="t.request" for="nx-audit-request">
          <input id="nx-audit-request" name="request" autocomplete="off" [(ngModel)]="form.request" />
        </ds-field>
        <fieldset class="categories">
          <legend>{{ t.categories }}</legend>
          @for (c of categories(); track c) {
            <label><input type="checkbox" [name]="'category-' + c" [checked]="form.categories.includes(c)" (change)="toggle(c)" />
              {{ t.categoryNames[c] }}</label>
          }
          <label><input type="checkbox" name="superseded" [(ngModel)]="form.includeSuperseded" /> {{ t.includeSuperseded }}</label>
        </fieldset>
        <div class="buttons">
          <ds-button variant="primary" type="submit" data-testid="audit-search">{{ t.search }}</ds-button>
          <ds-button (pressed)="clear()">{{ t.clear }}</ds-button>
        </div>
      </form>
      @if (error(); as e) {
        <div class="nx-card" role="alert">
          <p class="nx-error-text" data-testid="audit-error">{{ e.detail }}</p>
        </div>
      } @else {
        <nx-audit-table [rows]="rows()" [loading]="loading()" [hasMore]="!!cursor()" [timeZone]="context.me()?.businessTimeZone ?? undefined"
                        (loadMore)="loadMore()" />
      }
    </section>
  `,
  styles: `
    .filters { display: flex; flex-wrap: wrap; align-items: flex-end; gap: var(--nx-space-3) var(--nx-space-4);
               margin-block: var(--nx-space-4); }
    .filters input:not([type=checkbox]) { padding: var(--nx-space-2) var(--nx-space-3); border: var(--nx-border-width) solid var(--nx-color-border-strong);
                     border-radius: var(--nx-radius-1); }
    .categories { display: flex; flex-wrap: wrap; gap: var(--nx-space-3); margin: 0; padding: var(--nx-space-2) var(--nx-space-3);
                  border: var(--nx-border-width) solid var(--nx-color-border-default); border-radius: var(--nx-radius-1); }
    .buttons { display: flex; gap: var(--nx-space-3); }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class AuditPage {
  /** Query parameters (component input binding). */
  readonly from = input<string | undefined>();
  readonly to = input<string | undefined>();
  readonly user = input<string | undefined>();
  readonly version = input<string | undefined>();
  readonly hierarchy = input<string | undefined>();
  readonly property = input<string | undefined>();
  readonly node = input<string | undefined>();
  readonly request = input<string | undefined>();
  readonly category = input<string | string[] | undefined>();
  readonly superseded = input<string | undefined>();

  protected readonly context = inject(ContextStore);
  private readonly api = inject(NexusApi);
  private readonly router = inject(Router);
  private readonly announcer = inject(Announcer);
  protected readonly t = STRINGS.audit;

  protected readonly rows = signal<AuditEntry[]>([]);
  protected readonly cursor = signal<string | null>(null);
  protected readonly loading = signal(false);
  protected readonly error = signal<UiError | null>(null);
  /** ADMIN_SYSTEM anywhere = ADMIN: the other categories are offered (a hint; the server decides). */
  protected readonly categories = computed(() => (this.context.canEverywhere('ADMIN_SYSTEM') ? ['data', ...ADMIN_CATEGORIES] : ['data']));
  /** Dropdown options (owner, 2026-11-19; LLD §18.7): versions, the hierarchies this user can read, properties by category. */
  protected readonly versions = signal<VersionView[]>([]);
  protected readonly hierarchies = signal<HierarchySummary[]>([]);
  private readonly properties = signal<PropertyDefinitionView[]>([]);
  protected readonly propertyGroups = computed(() => {
    const groups = new Map<string, PropertyDefinitionView[]>();
    for (const p of this.properties()) {
      const c = p.category ?? STRINGS.properties.uncategorised;
      groups.set(c, [...(groups.get(c) ?? []), p]);
    }
    return [...groups.entries()].sort(([a], [b]) => a.localeCompare(b))
      .map(([category, properties]) => ({ category, properties: properties.sort((x, y) => (x.label ?? '').localeCompare(y.label ?? '')) }));
  });

  /** The form's values; copied from the URL when it changes, written to the URL by Search. */
  protected form = this.empty();
  private filters: AuditFilters = {};
  private generation = 0;

  constructor() {
    void this.loadOptions();
    effect(() => {
      const filters: AuditFilters = {
        from: this.from(), to: this.to(), user: this.user(), version: this.version(), hierarchy: this.hierarchy(), property: this.property(),
        node: this.node(), request: this.request(),
        category: [this.category() ?? []].flat().filter((c) => !!c),
        includeSuperseded: this.superseded() === 'true',
      };
      untracked(() => {
        this.filters = filters;
        this.form = { from: filters.from ?? '', to: filters.to ?? '', user: filters.user ?? '', version: filters.version ?? '',
          hierarchy: filters.hierarchy ?? '',
          property: filters.property ?? '', node: filters.node ?? '', request: filters.request ?? '',
          categories: filters.category?.length ? [...filters.category] : ['data'], includeSuperseded: !!filters.includeSuperseded };
        void this.load(false);
      });
    });
  }

  /**
   * The dropdowns' options, once per visit. A list that fails to load leaves its dropdown with "All …" only; a value
   * already in the URL is still searched (it is added as an option, so the dropdown shows it).
   */
  private async loadOptions(): Promise<void> {
    const [versions, hierarchies, properties] = await Promise.allSettled([
      this.api.versions(undefined, undefined, 200), this.api.hierarchies(), this.api.propertyDefinitions()]);
    if (versions.status === 'fulfilled') {
      this.versions.set(versions.value.items ?? []);
    }
    if (hierarchies.status === 'fulfilled') {
      this.hierarchies.set(hierarchies.value.items ?? []);
    }
    if (properties.status === 'fulfilled') {
      this.properties.set(properties.value.items ?? []);
    }
    this.keepUrlValues();
  }

  /** A value from the URL that is not in its list (a shared link, a list still loading) stays selectable. */
  private keepUrlValues(): void {
    const v = this.version();
    if (v && !this.versions().some((x) => x.name === v)) {
      this.versions.update((list) => [...list, { name: v }]);
    }
    const h = this.hierarchy();
    if (h && !this.hierarchies().some((x) => x.code === h)) {
      this.hierarchies.update((list) => [...list, { code: h, name: h }]);
    }
    const p = this.property();
    if (p && !this.properties().some((x) => x.code === p)) {
      this.properties.update((list) => [...list, { code: p, label: p }]);
    }
  }

  protected toggle(c: string): void {
    const set = new Set(this.form.categories);
    if (set.has(c)) {
      set.delete(c);
    } else {
      set.add(c);
    }
    this.form.categories = [...set];
  }

  protected search(): void {
    const f = this.form;
    const blank = (v: string) => v.trim() || null;
    void this.router.navigate([], {
      queryParams: {
        from: blank(f.from), to: blank(f.to), user: blank(f.user), version: blank(f.version), hierarchy: blank(f.hierarchy),
        property: blank(f.property),
        node: blank(f.node), request: blank(f.request),
        category: f.categories.length && !(f.categories.length === 1 && f.categories[0] === 'data') ? f.categories : null,
        superseded: f.includeSuperseded ? 'true' : null,
      },
    });
  }

  protected clear(): void {
    this.form = this.empty();
    void this.router.navigate([], { queryParams: {} });
  }

  protected loadMore(): void {
    void this.load(true);
  }

  private async load(more: boolean): Promise<void> {
    const generation = ++this.generation;
    this.loading.set(true);
    this.error.set(null);
    try {
      const page = await this.api.audit(this.filters, more ? this.cursor() ?? undefined : undefined);
      if (generation !== this.generation) {
        return;
      }
      this.rows.set(more ? [...this.rows(), ...(page.items ?? [])] : page.items ?? []);
      this.cursor.set(page.nextCursor ?? null);
      if (!more) {
        this.announcer.polite(`${this.t.title}: ${this.rows().length}${page.nextCursor ? '+' : ''}`);
      }
    } catch (e) {
      if (generation === this.generation) {
        this.rows.set([]);
        this.cursor.set(null);
        this.error.set(UiError.from(e));
      }
    } finally {
      if (generation === this.generation) {
        this.loading.set(false);
      }
    }
  }

  private empty() {
    return { from: '', to: '', user: '', version: '', hierarchy: '', property: '', node: '', request: '', categories: ['data'],
      includeSuperseded: false };
  }
}
