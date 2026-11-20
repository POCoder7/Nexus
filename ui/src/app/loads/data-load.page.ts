import { ChangeDetectionStrategy, Component, DestroyRef, effect, inject, input, signal, untracked } from '@angular/core';
import { Router, RouterLink } from '@angular/router';
import { NexusApi } from '../api/nexus-api';
import type { IntakeResult, LoadFinding, LoadRunView } from '../api/generated/models';
import { Announcer } from '../core/announcer';
import { LOAD_POLL_MS } from '../core/config';
import { ContextStore } from '../core/context.store';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DsToast } from '../shared/ds';
import { LoadRunPanelComponent } from './load-run-panel.component';

/**
 * One data load (ADR-046, Phase 4 LLD §17.8.2): its checks, prepare, approval by a second ADMIN, apply in the
 * background (this page polls), and the result. A load that has not been prepared yet has no run: the page shows its
 * checks and the Prepare step.
 */
@Component({
  selector: 'nx-data-load-page',
  imports: [RouterLink, LoadRunPanelComponent],
  template: `
    <section class="nx-page">
      <p><a routerLink="/admin/data-loads">{{ t.title }}</a></p>
      <h1>{{ t.detailTitle }}</h1>
      @if (error(); as e) {
        <p class="nx-error-text" role="alert">{{ e.detail }}</p>
      }
      <nx-load-run-panel [staged]="staged()" [findings]="findings()" [run]="run()" [login]="login()" [busy]="busy()"
                         (prepare)="prepare($event)" (approve)="approve($event)" (apply)="apply()" (cancel)="cancel()" />
    </section>
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class DataLoadPage {
  readonly id = input.required<string>();

  private readonly api = inject(NexusApi);
  private readonly announcer = inject(Announcer);
  private readonly toast = inject(DsToast);
  private readonly context = inject(ContextStore);
  protected readonly t = STRINGS.loads;
  protected readonly staged = signal<IntakeResult | null>(
    (inject(Router).getCurrentNavigation()?.extras.state?.['staged'] as IntakeResult | undefined)
    ?? (globalThis.history?.state?.staged as IntakeResult | undefined) ?? null);   // the upload's result, when we came from it
  protected readonly findings = signal<LoadFinding[]>([]);
  protected readonly run = signal<LoadRunView | null>(null);
  protected readonly busy = signal(false);
  protected readonly error = signal<UiError | null>(null);
  protected readonly login = () => this.context.me()?.actor?.login ?? null;
  private poll: ReturnType<typeof setTimeout> | null = null;

  constructor() {
    effect(() => {
      const id = this.id();
      untracked(() => void this.load(id));
    });
    inject(DestroyRef).onDestroy(() => this.stopPolling());
  }

  private async load(id: string): Promise<void> {
    this.error.set(null);
    try {
      this.findings.set(this.staged()?.findings ?? await this.api.loadFindings(id));
      this.run.set(await this.api.loadRun(id).catch((e: unknown) => {
        if (UiError.from(e).status === 404) {
          return null;   // staged but not prepared yet
        }
        throw e;
      }));
      this.follow();
    } catch (e) {
      this.error.set(UiError.from(e));
    }
  }

  protected prepare(version: string | null): void {
    void this.act(() => this.api.prepareLoadRun(this.id(), version ?? undefined), this.t.done.prepared, async () => {
      this.findings.set(await this.api.loadFindings(this.id()));
    });
  }

  protected approve(manifest: string): void {
    void this.act(() => this.api.approveLoadRun(this.id(), manifest), this.t.done.approved);
  }

  protected apply(): void {
    void this.act(() => this.api.applyLoadRun(this.id()), null);
  }

  protected cancel(): void {
    void this.act(() => this.api.cancelLoadRun(this.id()), this.t.done.cancelled);
  }

  private async act(call: () => Promise<LoadRunView>, done: string | null, after?: () => Promise<void>): Promise<void> {
    this.busy.set(true);
    this.error.set(null);
    try {
      this.run.set(await call());
      if (done) {
        this.toast.confirm(done);
        this.announcer.polite(done);
      }
      this.follow();
    } catch (e) {
      const error = UiError.from(e);
      this.error.set(error);
      this.announcer.assertive(error.detail);
      if (after) {
        await after().catch(() => undefined);   // prepare refused: show the findings that explain why
      }
    } finally {
      this.busy.set(false);
    }
  }

  /** While a run is applying, read it again every LOAD_POLL_MS; announce the outcome once. */
  private follow(): void {
    this.stopPolling();
    if (this.run()?.status !== 'applying') {
      return;
    }
    this.poll = setTimeout(async () => {
      try {
        const run = await this.api.loadRun(this.id());
        this.run.set(run);
        if (run.status === 'applied' || run.status === 'failed') {
          const text = run.status === 'applied' ? this.t.done.applied : this.t.done.failed;
          this.announcer.polite(text);
          if (run.status === 'applied') {
            this.toast.confirm(text);
          }
        }
      } catch (e) {
        this.error.set(UiError.from(e));
        return;
      }
      this.follow();
    }, LOAD_POLL_MS);
  }

  private stopPolling(): void {
    if (this.poll) {
      clearTimeout(this.poll);
      this.poll = null;
    }
  }
}
