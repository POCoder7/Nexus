import { ChangeDetectionStrategy, Component, computed, inject, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import { NexusApi } from '../api/nexus-api';
import type { HomeView, WorklistRow } from '../api/generated/models';
import { Announcer } from '../core/announcer';
import { ContextStore } from '../core/context.store';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DsBadgeComponent, DsButtonComponent, DsDialog, DsTab, DsTableDirective, DsTabsComponent } from '../shared/ds';
import { NodeChangeData, NodeChangeDialogComponent } from '../hierarchy/node-change-dialog.component';
import { NxInstantPipe } from '../shared/format/nx-date.pipe';

type WorkTab = 'decide' | 'drafts' | 'inFlight';

/**
 * Home (OD-27; NEW-10; layout Phase 5 LLD §21.1). Two columns: on the left what to do (the user's work in tabs, with the
 * actual items, and what changed recently); on the right where to go (continue where you left off, the user's
 * hierarchies, and for ADMINs the governance health). Sections follow the user's role: someone who only reads sees
 * what changed and their hierarchies, with no empty work tabs. Search is in the header. One bounded call (`GET /home`).
 */
@Component({
  selector: 'nx-home-page',
  imports: [RouterLink, DsButtonComponent, DsBadgeComponent, DsTableDirective, DsTabsComponent, NxInstantPipe],
  templateUrl: './home.page.html',
  styleUrl: './home.page.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class HomePage {
  private readonly api = inject(NexusApi);
  private readonly announcer = inject(Announcer);
  protected readonly context = inject(ContextStore);
  private readonly dialog = inject(DsDialog);
  protected readonly t = STRINGS.home;
  protected readonly common = STRINGS.common;
  protected readonly change = STRINGS.change;

  protected readonly home = signal<HomeView | null>(null);
  protected readonly error = signal<UiError | null>(null);
  protected readonly tab = signal<string>('');

  protected readonly homeHeading = STRINGS.nav.home;

  /** The work tabs this user can have (§21.1): decisions for deciders, drafts and in-flight for proposers. */
  protected readonly tabs = computed<DsTab[]>(() => {
    const h = this.home();
    const list: { id: WorkTab; n: number }[] = [];
    if (this.context.can('DECIDE') || this.assigned() > 0) list.push({ id: 'decide', n: this.assigned() });
    if (this.context.can('PROPOSE')) {
      list.push({ id: 'drafts', n: this.count('drafted') });
      list.push({ id: 'inFlight', n: this.count('submitted') });
    }
    return h ? list.map((x) => ({ id: x.id, label: `${this.t.workTabs[x.id]} (${x.n})` })) : [];
  });
  protected readonly currentTab = computed(() => (this.tab() || this.tabs()[0]?.id || 'decide') as WorkTab);
  protected readonly items = computed<WorklistRow[]>(() => {
    const h = this.home();
    switch (this.currentTab()) {
      case 'drafts': return h?.drafts ?? [];
      case 'inFlight': return h?.inFlight ?? [];
      default: return h?.worklist?.top ?? [];
    }
  });
  protected readonly lastHierarchy = computed(() => (this.home()?.hierarchies ?? []).find((c) => c.lastUsed) ?? null);
  protected readonly latestDraft = computed(() => this.home()?.drafts?.[0] ?? null);
  protected readonly sandboxes = computed(() => this.context.mySandboxes().slice(0, 3));
  protected readonly timeZone = () => this.context.me()?.businessTimeZone ?? undefined;

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

  protected assigned(): number {
    return this.count('assigned');
  }

  /** A worklist view's count (assigned, drafted, submitted…). */
  protected count(view: string): number {
    return this.home()?.worklist?.counts?.[view] ?? 0;
  }

  /** "Approve · due in 2 d", "Approve · overdue" or the stage with no due date. */
  protected stageAndDue(row: WorklistRow): string {
    let due: string = this.t.noDueDate;
    if (row.isOverdue) {
      due = this.t.overdueWord;
    } else if (row.dueAt) {
      const hours = Math.max(1, Math.round((Date.parse(row.dueAt) - Date.now()) / 3_600_000));
      due = this.t.dueIn(hours < 48 ? this.t.hoursShort(hours) : this.t.daysShort(Math.round(hours / 24)));
    }
    return this.t.stageAndDue(row.stageLabel ?? this.t.workTabs['drafts'], due);
  }

  /** A draft opens its review page; anything else opens the request. */
  protected link(row: WorklistRow): unknown[] {
    return this.currentTab() === 'drafts' ? ['/requests', row.changeRequestId, 'review'] : ['/requests', row.changeRequestId];
  }

  /** Create a hierarchy (scope extension): an `add_hierarchy` item in the draft request, governed like any change. */
  protected newHierarchy(): void {
    const today = this.context.businessToday();
    if (today) {
      this.dialog.open<boolean, NodeChangeData, NodeChangeDialogComponent>(NodeChangeDialogComponent,
        { mode: 'hierarchy', hierarchyCode: null, businessToday: today }, 'nx-change-title');
    }
  }
}
