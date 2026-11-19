import { ChangeDetectionStrategy, Component, OnDestroy, computed, effect, inject, input, signal, untracked } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Router } from '@angular/router';
import { NexusApi } from '../api/nexus-api';
import type { CompareRow, CompareRunView, CompareSide, HierarchySummary, VersionView } from '../api/generated/models';
import { Announcer } from '../core/announcer';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DsButtonComponent, DsFieldComponent } from '../shared/ds';
import { formatBusinessDate } from '../shared/format/nx-date.pipe';
import { CompareResultsComponent } from './compare-results.component';

const KINDS = ['structure', 'property', 'rename'];

interface SideForm {
  hierarchy: string;
  version: string;
  asOf: string;
}

/**
 * Compare (Phase 5 LLD §17.4, §17.12; QRY-02, VER-04). Two sides, each a hierarchy and a version or a date; the kinds and
 * options; "Compare" starts a run and puts its id in the URL (`?run=`), so a result can be shared and reloaded. The page
 * polls the run while it runs, then shows the differences by kind. "Compare with baseline" on the Versions page opens it
 * with the baseline on the left. The server decides what the user may read.
 */
@Component({
  selector: 'nx-compare-page',
  imports: [FormsModule, DsButtonComponent, DsFieldComponent, CompareResultsComponent],
  template: `
    <section class="nx-page">
      <h1>{{ t.title }}</h1>
      <p class="nx-muted">{{ t.intro }}</p>
      <form class="form" (submit)="$event.preventDefault(); start()">
        @for (s of sides; track s.key) {
          <fieldset class="side" [attr.data-side]="s.key">
            <legend>{{ s.label }}</legend>
            <ds-field [label]="t.hierarchy" [for]="'nx-cmp-' + s.key + '-h'">
              <select [id]="'nx-cmp-' + s.key + '-h'" [name]="s.key + 'h'" [(ngModel)]="form[s.key].hierarchy" required>
                <option value="">{{ t.chooseHierarchy }}</option>
                @for (h of hierarchies(); track h.code) {
                  <option [value]="h.code">{{ h.name }} ({{ h.code }})</option>
                }
              </select>
            </ds-field>
            <ds-field [label]="t.version" [for]="'nx-cmp-' + s.key + '-v'">
              <select [id]="'nx-cmp-' + s.key + '-v'" [name]="s.key + 'v'" [(ngModel)]="form[s.key].version">
                <option value="">{{ t.today }}</option>
                @for (v of versions(); track v.name) {
                  <option [value]="v.name">{{ v.name }} ({{ statusWord(v.status) }})</option>
                }
              </select>
            </ds-field>
            @if (!form[s.key].version) {
              <ds-field [label]="t.asOf" [for]="'nx-cmp-' + s.key + '-d'">
                <input type="date" [id]="'nx-cmp-' + s.key + '-d'" [name]="s.key + 'd'" [(ngModel)]="form[s.key].asOf" />
              </ds-field>
            }
          </fieldset>
        }
        <fieldset class="options">
          <legend>{{ t.kinds }}</legend>
          @for (k of allKinds; track k) {
            <label><input type="checkbox" [name]="'kind-' + k" [checked]="kinds.includes(k)" (change)="toggleKind(k)" /> {{ t.kindNames[k] }}</label>
          }
          <label><input type="checkbox" name="order" [(ngModel)]="includeOrder" /> {{ t.includeOrder }}</label>
          <label><input type="checkbox" name="inactive" [(ngModel)]="includeInactive" /> {{ t.includeInactive }}</label>
        </fieldset>
        <div>
          <ds-button variant="primary" type="submit" [disabled]="starting() || running()" data-testid="compare-run">{{ t.run }}</ds-button>
        </div>
      </form>

      @if (error(); as e) {
        <div class="nx-card" role="alert"><p class="nx-error-text" data-testid="compare-error">{{ e.detail }}</p></div>
      }
      @if (run(); as r) {
        <div class="summary" role="status" data-testid="compare-status">
          @if (r.status === 'running') {
            <p>{{ t.running }}</p>
          } @else if (r.status === 'failed') {
            <p class="nx-error-text">{{ t.failed }} {{ r.error }}</p>
          } @else {
            <p class="nx-muted">{{ sideText(r.left) }} ↔ {{ sideText(r.right) }}</p>
            @if (r.reused) {
              <p class="nx-muted">{{ t.reused }}</p>
            }
          }
        </div>
        @if (r.status === 'done') {
          <nx-compare-results [counts]="counts()" [kinds]="r.kinds ?? allKinds" [rows]="rows()" [loading]="rowsLoading()"
                              [hasMore]="!!cursor()" [leftLabel]="sideText(r.left)" [rightLabel]="sideText(r.right)"
                              [(kind)]="kind" (loadMore)="loadRows(true)" />
        }
      }
    </section>
  `,
  styles: `
    .form { display: flex; flex-wrap: wrap; align-items: flex-end; gap: var(--nx-space-4); margin-block: var(--nx-space-4); }
    fieldset { display: flex; flex-wrap: wrap; align-items: flex-end; gap: var(--nx-space-3); margin: 0;
               padding: var(--nx-space-3); border: var(--nx-border-width) solid var(--nx-color-border-default); border-radius: var(--nx-radius-1); }
    select, input[type=date] { padding: var(--nx-space-2) var(--nx-space-3); border: var(--nx-border-width) solid var(--nx-color-border-strong);
                               border-radius: var(--nx-radius-1); }
    .summary { margin-block: var(--nx-space-3); }
    .summary p { margin: 0; }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class ComparePage implements OnDestroy {
  /** Query parameters: the form (lh, lv, la, rh, rv, ra) and the run to show. */
  readonly lh = input<string | undefined>();
  readonly lv = input<string | undefined>();
  readonly la = input<string | undefined>();
  readonly rh = input<string | undefined>();
  readonly rv = input<string | undefined>();
  readonly ra = input<string | undefined>();
  readonly runId = input<string | undefined>(undefined, { alias: 'run' });

  private readonly api = inject(NexusApi);
  private readonly router = inject(Router);
  private readonly announcer = inject(Announcer);
  protected readonly t = STRINGS.compare;
  protected readonly allKinds = KINDS;
  protected readonly sides = [{ key: 'left' as const, label: STRINGS.compare.left }, { key: 'right' as const, label: STRINGS.compare.right }];

  protected readonly hierarchies = signal<HierarchySummary[]>([]);
  protected readonly versions = signal<VersionView[]>([]);
  protected form: { left: SideForm; right: SideForm } = { left: this.blank(), right: this.blank() };
  protected kinds = [...KINDS];
  protected includeOrder = false;
  protected includeInactive = false;

  protected readonly starting = signal(false);
  protected readonly run = signal<CompareRunView | null>(null);
  protected readonly running = computed(() => this.run()?.status === 'running');
  protected readonly counts = computed(() => (this.run()?.counts ?? {}) as Record<string, number>);
  protected readonly kind = signal('');
  protected readonly rows = signal<CompareRow[]>([]);
  protected readonly cursor = signal<string | null>(null);
  protected readonly rowsLoading = signal(false);
  protected readonly error = signal<UiError | null>(null);
  private poll: ReturnType<typeof setTimeout> | null = null;

  constructor() {
    void this.loadOptions();
    // the form follows the URL (a shared link, "Compare with baseline")
    effect(() => {
      const left = { hierarchy: this.lh() ?? '', version: this.lv() ?? '', asOf: this.la() ?? '' };
      const right = { hierarchy: this.rh() ?? '', version: this.rv() ?? '', asOf: this.ra() ?? '' };
      untracked(() => (this.form = { left, right }));
    });
    // the run in the URL is loaded, and followed while it runs
    effect(() => {
      const id = this.runId();
      untracked(() => (id ? void this.follow(id) : this.run.set(null)));
    });
    // a new tab (or a new result) loads that kind's rows
    effect(() => {
      const kind = this.kind();
      const r = this.run();
      if (r?.status === 'done') {
        untracked(() => void this.loadRows(false, kind || r.kinds?.[0] || 'structure'));
      }
    });
  }

  ngOnDestroy(): void {
    if (this.poll) clearTimeout(this.poll);
  }

  protected toggleKind(k: string): void {
    this.kinds = this.kinds.includes(k) ? this.kinds.filter((x) => x !== k) : [...this.kinds, k];
  }

  protected statusWord(status: string | undefined): string {
    return STRINGS.versions.statusWords[status ?? ''] ?? status ?? '';
  }

  protected sideText(s: { hierarchyCode?: string; version?: string; asOf?: string } | undefined): string {
    if (!s) return '';
    return this.t.sideLabel(s.hierarchyCode ?? '', s.version ?? formatBusinessDate(s.asOf ?? null));
  }

  protected async start(): Promise<void> {
    const side = (f: SideForm): CompareSide => ({ hierarchyCode: f.hierarchy, version: f.version || undefined,
      asOf: f.version ? undefined : f.asOf || undefined });
    this.starting.set(true);
    this.error.set(null);
    try {
      const run = await this.api.startCompare({ left: side(this.form.left), right: side(this.form.right),
        kinds: this.kinds.length ? this.kinds : KINDS, includeOrder: this.includeOrder, includeInactive: this.includeInactive });
      const f = this.form;
      void this.router.navigate([], { queryParams: {
        lh: f.left.hierarchy, lv: f.left.version || null, la: f.left.version ? null : f.left.asOf || null,
        rh: f.right.hierarchy, rv: f.right.version || null, ra: f.right.version ? null : f.right.asOf || null, run: run.id } });
    } catch (e) {
      this.error.set(UiError.from(e));
      this.announcer.assertive(this.error()!.detail);
    } finally {
      this.starting.set(false);
    }
  }

  /** Polls the run every second until it is done or failed. */
  private async follow(id: string): Promise<void> {
    if (this.poll) clearTimeout(this.poll);
    try {
      const r = await this.api.compare(id);
      if (this.runId() !== id) return;
      this.run.set(r);
      if (r.status === 'running') {
        this.poll = setTimeout(() => void this.follow(id), 1000);
      } else {
        this.announcer.polite(r.status === 'done' ? this.t.title : this.t.failed);
      }
    } catch (e) {
      this.error.set(UiError.from(e));
    }
  }

  protected async loadRows(more: boolean, kind = this.kind() || this.run()?.kinds?.[0] || 'structure'): Promise<void> {
    const r = this.run();
    if (!r?.id) return;
    this.rowsLoading.set(true);
    try {
      const page = await this.api.compareRows(r.id, kind, more ? this.cursor() ?? undefined : undefined);
      this.rows.set(more ? [...this.rows(), ...(page.items ?? [])] : page.items ?? []);
      this.cursor.set(page.nextCursor ?? null);
    } catch (e) {
      this.error.set(UiError.from(e));
    } finally {
      this.rowsLoading.set(false);
    }
  }

  private async loadOptions(): Promise<void> {
    const [h, v] = await Promise.allSettled([this.api.hierarchies(), this.api.versions(undefined, undefined, 200)]);
    if (h.status === 'fulfilled') this.hierarchies.set(h.value.items ?? []);
    if (v.status === 'fulfilled') this.versions.set(v.value.items ?? []);
  }

  private blank(): SideForm {
    return { hierarchy: '', version: '', asOf: '' };
  }
}
