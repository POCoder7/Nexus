import { ChangeDetectionStrategy, Component, effect, inject, input, untracked } from '@angular/core';
import { Router } from '@angular/router';
import type { VersionView } from '../api/generated/models';
import { Announcer } from '../core/announcer';
import { ContextStore } from '../core/context.store';
import { STRINGS } from '../core/strings';
import { DsButtonComponent, DsDialog } from '../shared/ds';
import { TransitionDialogComponent, TransitionDialogData } from './transition-dialog.component';
import { VersionDialogComponent, VersionDialogData } from './version-dialog.component';
import { VERSION_FILTERS, VersionFilter, VersionsStore } from './versions.store';
import { TransitionChoice, VersionsTableComponent } from './versions-table.component';

/**
 * Versions (Phase 3 LLD V.6; VER-01, VER-02): status chips, the table and "New version". The URL carries the filter
 * (`/versions?status=`). Versions are current state, so the as-of date does not apply here. Every action is offered as
 * the server lists it on the row; the server decides.
 */
@Component({
  selector: 'nx-versions-page',
  imports: [VersionsTableComponent, DsButtonComponent],
  providers: [VersionsStore],
  template: `
    <section class="nx-page">
      <div class="head">
        <h1>{{ t.title }}</h1>
        @if (canAdmin()) {
          <ds-button variant="primary" (pressed)="create()" data-testid="new-version">{{ t.newVersion }}</ds-button>
        }
      </div>
      <p class="nx-muted" data-testid="versions-shared-note">{{ t.sharedNote }}</p>
      <div class="chips" role="group" [attr.aria-label]="t.filtersLabel">
        @for (f of filters; track f) {
          <button type="button" class="chip" [attr.aria-pressed]="store.filter() === f" [attr.data-filter]="f" (click)="choose(f)">
            {{ t.filters[f] }}
          </button>
        }
      </div>
      @if (store.error(); as e) {
        <div class="nx-card" role="alert">
          <p class="nx-error-text">{{ e.detail }}</p>
          <ds-button (pressed)="store.load(store.filter())">{{ common.retry }}</ds-button>
        </div>
      }
      @if (store.loading() && store.rows().length === 0) {
        <p class="nx-muted" role="status">{{ common.loading }}</p>
      } @else if (!store.error()) {
        <nx-versions-table [rows]="store.rows()" [loading]="store.loading()" [hasMore]="!!store.nextCursor()"
                           [emptyText]="t.empty[store.filter()]" [canAdmin]="canAdmin()" [timeZone]="timeZone()"
                           (openPicture)="openPicture($event)" (transition)="transition($event)" (edit)="edit($event)"
                           (loadMore)="store.loadMore()" />
      }
    </section>
  `,
  styleUrl: './versions.page.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class VersionsPage {
  readonly status = input<string | undefined>();

  protected readonly store = inject(VersionsStore);
  private readonly context = inject(ContextStore);
  private readonly dialog = inject(DsDialog);
  private readonly router = inject(Router);
  private readonly announcer = inject(Announcer);
  protected readonly t = STRINGS.versions;
  protected readonly common = STRINGS.common;
  protected readonly filters = VERSION_FILTERS;
  protected readonly canAdmin = () => this.context.can('ADMIN_VERSION');
  protected readonly timeZone = () => this.context.me()?.businessTimeZone ?? undefined;

  constructor() {
    effect(() => {
      const raw = this.status();
      const filter = (VERSION_FILTERS as readonly string[]).includes(raw ?? '') ? (raw as VersionFilter) : 'all';
      untracked(() => void this.store.load(filter).then(() =>
        this.announcer.polite(`${this.t.filters[filter]}: ${this.store.rows().length}`)));
    });
  }

  protected choose(filter: VersionFilter): void {
    void this.router.navigate([], { queryParams: { status: filter === 'all' ? null : filter }, queryParamsHandling: 'merge' });
  }

  protected openPicture(v: VersionView): void {
    void this.context.openPicture(v);
  }

  protected create(): void {
    this.openDialog<VersionDialogData>(VersionDialogComponent, { mode: 'create' }, 'nx-version-dialog-title');
  }

  protected edit(v: VersionView): void {
    this.openDialog<VersionDialogData>(VersionDialogComponent, { mode: 'edit', version: v }, 'nx-version-dialog-title');
  }

  protected transition(choice: TransitionChoice): void {
    this.openDialog<TransitionDialogData>(TransitionDialogComponent, { version: choice.version, to: choice.to }, 'nx-transition-title');
  }

  /** Focus returns to the trigger on close (the dialog adapter restores it); a change reloads everything that shows versions. */
  private openDialog<D>(component: typeof VersionDialogComponent | typeof TransitionDialogComponent, data: D, labelledBy: string): void {
    const ref = this.dialog.open<VersionView, D, unknown>(component, data, labelledBy);
    ref.closed.subscribe((changed) => {
      if (changed) {
        void this.store.refresh();
      }
    });
  }
}
