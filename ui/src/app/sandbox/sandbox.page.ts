import { ChangeDetectionStrategy, Component, computed, effect, inject, input, signal, untracked } from '@angular/core';
import { Router, RouterLink } from '@angular/router';
import { ItemListComponent } from '../change-request/item-list.component';
import { Announcer } from '../core/announcer';
import { ContextStore } from '../core/context.store';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DsBadgeComponent, DsButtonComponent, DsToast } from '../shared/ds';
import { formatBusinessDate, formatInstant } from '../shared/format/nx-date.pipe';
import { SandboxConflictsComponent } from './sandbox-conflicts.component';
import { SandboxStore } from './sandbox.store';

/**
 * One sandbox (NEW-08, Phase 5 LLD §5, §12): what it changes (the before/after view, `nx-item-list`), the changes its
 * preview leaves out, its conflicts with Rebase and Remove change, and Submit as request or Discard. Viewers see it
 * read-only; only the owner changes it, and the server decides.
 */
@Component({
  selector: 'nx-sandbox-page',
  imports: [ItemListComponent, SandboxConflictsComponent, DsButtonComponent, DsBadgeComponent, RouterLink],
  providers: [SandboxStore],
  template: `
    <section class="nx-page">
      @if (store.error(); as e) {
        <h1>{{ t.listTitle }}</h1>
        <div class="nx-card" role="alert">
          <p class="nx-error-text">{{ e.detail }}</p>
          <ds-button (pressed)="store.load(id())">{{ common.retry }}</ds-button>
        </div>
      } @else if (store.sandbox(); as s) {
        <div class="head">
          <h1 data-testid="sandbox-title">{{ t.pageTitle(s.name ?? '') }}</h1>
          <ds-badge [tone]="store.isOpen() ? 'info' : 'neutral'" data-testid="sandbox-status">
            {{ s.kind === 'request' ? statuses['submitted'] : (t.status[s.status ?? ''] ?? s.status) }}
          </ds-badge>
        </div>
        <dl class="facts">
          <div><dt>{{ t.facts.effective }}</dt><dd>{{ date(s.effectiveFrom) }}</dd></div>
          <div><dt>{{ t.facts.base }}</dt><dd>{{ instant(s.baseRecordedAt) }}</dd></div>
          <div><dt>{{ t.facts.changes }}</dt><dd data-testid="sandbox-item-count">{{ s.itemCount }}</dd></div>
        </dl>

        @if (s.kind === 'request') {
          <p role="status">{{ t.becameRequest }} <a [routerLink]="['/requests', s.id]">{{ t.viewRequest }}</a></p>
        }
        @if (store.isOpen()) {
          <div class="actions">
            <a [routerLink]="['/hierarchies']" [queryParams]="{ sandbox: s.id }" data-testid="sandbox-open-workspace">{{ t.openInWorkspace }}</a>
            @if (store.canChange()) {
              <ds-button variant="primary" [disabled]="store.busy() || store.items().length === 0 || store.conflicts().length > 0"
                         [describedBy]="'nx-submit-hint'" (pressed)="submit()" data-testid="sandbox-submit">{{ t.submit }}</ds-button>
              @if (confirmDiscard()) {
                <span role="group" class="confirm" [attr.aria-label]="t.discard">
                  <span>{{ t.discardConfirm }}</span>
                  <ds-button variant="danger" [disabled]="store.busy()" (pressed)="discard()" data-testid="sandbox-discard-confirm">{{ t.discard }}</ds-button>
                  <ds-button variant="link" (pressed)="confirmDiscard.set(false)">{{ common.cancel }}</ds-button>
                </span>
              } @else {
                <ds-button [disabled]="store.busy()" (pressed)="confirmDiscard.set(true)" data-testid="sandbox-discard">{{ t.discard }}</ds-button>
              }
            }
          </div>
          @if (store.canChange()) {
            <p id="nx-submit-hint" class="nx-muted">{{ store.conflicts().length > 0 ? t.hasConflicts : t.submitHint }}</p>
          }
        }
        @if (actionError(); as e) {
          <p class="nx-error-text" role="alert" data-testid="sandbox-action-error">{{ e.detail }}</p>
        }

        @if (store.isOpen()) {
          <nx-sandbox-conflicts [conflicts]="store.conflicts()" [canChange]="store.canChange()" [busy]="store.busy()"
                                (rebase)="rebase()" (remove)="remove($event)" />
        }

        <section aria-labelledby="nx-sandbox-items">
          <h2 id="nx-sandbox-items">{{ t.items }}</h2>
          @if (store.failures().length > 0) {
            <div class="nx-card failures" role="note" data-testid="sandbox-failures">
              <p>{{ t.failing(store.failures().length) }}</p>
              <ul>
                @for (f of store.failures(); track f.itemId) {
                  <li>{{ t.failure(f.seq ?? 0, f.message ?? f.errorCode ?? '') }}</li>
                }
              </ul>
            </div>
          }
          @if (store.items().length === 0) {
            <p class="nx-muted">{{ t.noItems }}</p>
          } @else {
            <nx-item-list [items]="store.items()" [label]="t.items" />
          }
        </section>
      } @else {
        <h1>{{ t.listTitle }}</h1>
        <p class="nx-muted" role="status">{{ common.loading }}</p>
      }
    </section>
  `,
  styles: `
    .head { display: flex; flex-wrap: wrap; align-items: center; gap: var(--nx-space-4); }
    .head h1 { margin: 0; }
    .facts { display: flex; flex-wrap: wrap; gap: var(--nx-space-6); margin: var(--nx-space-4) 0; }
    .facts dt { font-size: var(--nx-font-size-label); color: var(--nx-color-text-secondary); }
    .facts dd { margin: 0; }
    .actions { display: flex; flex-wrap: wrap; align-items: center; gap: var(--nx-space-4); }
    .confirm { display: inline-flex; flex-wrap: wrap; align-items: center; gap: var(--nx-space-3); }
    .failures ul { margin: var(--nx-space-2) 0 0; }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class SandboxPage {
  /** Route parameter (component input binding). */
  readonly id = input.required<string>();

  protected readonly store = inject(SandboxStore);
  private readonly context = inject(ContextStore);
  private readonly router = inject(Router);
  private readonly toast = inject(DsToast);
  private readonly announcer = inject(Announcer);
  protected readonly t = STRINGS.sandbox;
  protected readonly common = STRINGS.common;
  protected readonly statuses = STRINGS.statuses as Record<string, string>;
  protected readonly confirmDiscard = signal(false);
  protected readonly actionError = signal<UiError | null>(null);
  private readonly zone = computed(() => this.context.me()?.businessTimeZone ?? undefined);

  constructor() {
    effect(() => {
      const id = this.id();
      untracked(() => void this.store.load(id));
    });
  }

  protected date(d: string | undefined): string {
    return formatBusinessDate(d ?? null);
  }

  protected instant(i: string | undefined): string {
    return i ? formatInstant(i, this.zone()) : '—';
  }

  protected async rebase(): Promise<void> {
    await this.run(() => this.store.rebase(), this.t.rebased);
  }

  protected async remove(itemId: string): Promise<void> {
    const seq = this.store.items().find((i) => i.id === itemId)?.seq ?? 0;
    await this.run(() => this.store.removeItem(itemId), this.t.removed(seq));
  }

  protected async submit(): Promise<void> {
    await this.run(async () => {
      const request = await this.store.submit();
      await this.router.navigate(['/requests', request.id]);
    }, this.t.submitted);
  }

  protected async discard(): Promise<void> {
    const name = this.store.sandbox()?.name ?? '';
    await this.run(async () => {
      await this.store.discard();
      this.confirmDiscard.set(false);
      await this.router.navigate(['/sandboxes']);
    }, this.t.discarded(name));
  }

  private async run(action: () => Promise<void>, done: string): Promise<void> {
    this.actionError.set(null);
    try {
      await action();
      this.toast.confirm(done);
      this.announcer.polite(done);
    } catch (e) {
      const error = UiError.from(e);
      this.actionError.set(error);
      this.announcer.assertive(error.detail);
    }
  }
}
