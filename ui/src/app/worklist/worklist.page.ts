import { ChangeDetectionStrategy, Component, effect, inject, input, untracked } from '@angular/core';
import { Router } from '@angular/router';
import type { WorklistRow } from '../api/generated/models';
import { Announcer } from '../core/announcer';
import { WORKLIST_VIEWS, WorklistView } from '../core/config';
import { STRINGS } from '../core/strings';
import { DsButtonComponent } from '../shared/ds';
import { WorklistStore } from './worklist.store';
import { WorklistTableComponent } from './worklist-table.component';

/**
 * Worklist (LLD §12.2; GOV-13): view chips with the server's counts, search, model filter and the table. The URL carries
 * view, search and model (`/worklist?view=&search=&model=`). The worklist is current state, so the as-of date does not
 * apply to it.
 */
@Component({
  selector: 'nx-worklist-page',
  imports: [WorklistTableComponent, DsButtonComponent],
  providers: [WorklistStore],
  templateUrl: './worklist.page.html',
  styleUrl: './worklist.page.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class WorklistPage {
  readonly view = input<string | undefined>();
  readonly search = input<string | undefined>();
  readonly model = input<string | undefined>();

  protected readonly store = inject(WorklistStore);
  private readonly router = inject(Router);
  private readonly announcer = inject(Announcer);
  protected readonly t = STRINGS.worklist;
  protected readonly common = STRINGS.common;
  protected readonly views = WORKLIST_VIEWS;
  private searchTimer: ReturnType<typeof setTimeout> | null = null;

  constructor() {
    effect(() => {
      const raw = this.view();
      const view = (WORKLIST_VIEWS as readonly string[]).includes(raw ?? '') ? (raw as WorklistView) : 'assigned';
      const search = this.search() ?? '';
      const model = this.model() ?? '';
      untracked(() => void this.store.load(view, search, model).then(() =>
        this.announcer.polite(`${this.t.views[view]}: ${this.store.counts()[view] ?? 0}`)));
    });
  }

  protected choose(view: WorklistView): void {
    this.navigate({ view });
  }

  protected onSearch(value: string): void {
    if (this.searchTimer) {
      clearTimeout(this.searchTimer);
    }
    this.searchTimer = setTimeout(() => this.navigate({ search: value.trim() || null }), 300);
  }

  protected onModel(value: string): void {
    this.navigate({ model: value.trim() || null });
  }

  protected open(row: WorklistRow): void {
    void this.router.navigate(['/requests', row.changeRequestId]);
  }

  private navigate(params: Record<string, string | null>): void {
    void this.router.navigate([], { queryParams: params, queryParamsHandling: 'merge' });
  }
}
