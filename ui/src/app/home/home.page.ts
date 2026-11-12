import { ChangeDetectionStrategy, Component, computed, inject, signal } from '@angular/core';
import { Router, RouterLink } from '@angular/router';
import { NexusApi } from '../api/nexus-api';
import type { HomeView, SearchHit } from '../api/generated/models';
import { Announcer } from '../core/announcer';
import { ContextStore } from '../core/context.store';
import { PreferencesStore } from '../core/preferences.store';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DsBadgeComponent, DsButtonComponent, DsDialog, DsTableDirective, DsTone } from '../shared/ds';
import { NodeChangeData, NodeChangeDialogComponent } from '../hierarchy/node-change-dialog.component';
import { NxDatePipe } from '../shared/format/nx-date.pipe';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Home (OD-27, LLD §12.2; NEW-10): search, the next five worklist items, the user's requests, their hierarchies and, for
 * policy roles only, the shadow-mode summary. One bounded call (`GET /home`); each card has its own empty and error
 * state. In a historical view the quick actions are hidden.
 */
@Component({
  selector: 'nx-home-page',
  imports: [RouterLink, DsButtonComponent, DsBadgeComponent, DsTableDirective, NxDatePipe],
  templateUrl: './home.page.html',
  styleUrl: './home.page.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class HomePage {
  private readonly api = inject(NexusApi);
  private readonly router = inject(Router);
  private readonly announcer = inject(Announcer);
  protected readonly context = inject(ContextStore);
  private readonly prefs = inject(PreferencesStore);
  protected readonly t = STRINGS.home;
  protected readonly common = STRINGS.common;
  protected readonly statuses = STRINGS.statuses;
  protected readonly overdue = STRINGS.worklist.overdue;
  protected readonly change = STRINGS.change;
  private readonly dialog = inject(DsDialog);

  protected readonly home = signal<HomeView | null>(null);
  protected readonly error = signal<UiError | null>(null);
  protected readonly query = signal('');
  protected readonly hits = signal<SearchHit[] | null>(null);
  protected readonly searchError = signal<string | null>(null);

  /** Search targets the last hierarchy used, else the first one listed. */
  protected readonly searchHierarchy = computed(() =>
    this.prefs.lastHierarchy() ?? this.home()?.hierarchies?.[0]?.code ?? null);
  protected readonly assignedCount = computed(() => this.home()?.worklist?.counts?.['assigned'] ?? 0);
  protected readonly statusCounts = computed(() => Object.entries(this.home()?.requests?.countsByStatus ?? {}));

  constructor() {
    void this.load();
  }

  protected async load(): Promise<void> {
    this.error.set(null);
    try {
      this.home.set(await this.api.home());
      this.announcer.polite(this.t.title);
    } catch (e) {
      this.error.set(UiError.from(e));
    }
  }

  protected tone(status: string | undefined): DsTone {
    switch (status) {
      case 'applied': return 'success';
      case 'rejected': case 'apply_failed': return 'error';
      case 'draft': return 'info';
      default: return 'pending';
    }
  }

  protected async search(event: Event): Promise<void> {
    event.preventDefault();
    const text = this.query().trim();
    this.searchError.set(null);
    this.hits.set(null);
    if (UUID.test(text)) {
      await this.router.navigate(['/requests', text]);
      return;
    }
    const code = this.searchHierarchy();
    if (!code || text.length < 2) {
      this.searchError.set(STRINGS.hierarchy.searchTooShort);
      return;
    }
    try {
      const page = await this.api.search(code, text, this.context.slice(), 10);
      this.hits.set(page.items ?? []);
      this.announcer.polite((page.items ?? []).length ? `${(page.items ?? []).length}` : this.t.noResults);
    } catch (e) {
      this.searchError.set(UiError.from(e).detail);
    }
  }

  /** Create a hierarchy (scope extension): an `add_hierarchy` item in the draft request, governed like any change. */
  protected newHierarchy(): void {
    const today = this.context.businessToday();
    if (today) {
      this.dialog.open<boolean, NodeChangeData, NodeChangeDialogComponent>(NodeChangeDialogComponent,
        { mode: 'hierarchy', hierarchyCode: null, businessToday: today }, 'nx-change-title');
    }
  }

  protected openHit(hit: SearchHit): void {
    void this.router.navigate(['/hierarchies', this.searchHierarchy()], { queryParams: { node: hit.nodeId }, queryParamsHandling: 'merge' });
  }
}
