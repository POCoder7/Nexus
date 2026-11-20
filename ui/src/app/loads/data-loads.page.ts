import { ChangeDetectionStrategy, Component, inject, signal } from '@angular/core';
import { Router, RouterLink } from '@angular/router';
import { NexusApi } from '../api/nexus-api';
import type { LoadRunView } from '../api/generated/models';
import { Announcer } from '../core/announcer';
import { ContextStore } from '../core/context.store';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DsBadgeComponent, DsButtonComponent, DsFieldComponent, DsTableDirective } from '../shared/ds';
import { NxInstantPipe } from '../shared/format/nx-date.pipe';

/**
 * Admin › Data loads (ADR-046, Phase 4 LLD §17.8.2): upload a new load (CSV files or one zip), and the loads so far.
 * Uploading stages and checks the files, then opens the load.
 */
@Component({
  selector: 'nx-data-loads-page',
  imports: [RouterLink, DsBadgeComponent, DsButtonComponent, DsFieldComponent, DsTableDirective, NxInstantPipe],
  template: `
    <section class="nx-page">
      <h1>{{ t.title }}</h1>
      <p class="nx-muted">{{ t.intro }}</p>

      <section class="nx-card" aria-labelledby="nx-loads-upload">
        <h2 id="nx-loads-upload">{{ t.upload.heading }}</h2>
        <ds-field [label]="t.upload.label" for="nx-loads-files" [hint]="t.upload.hint" [error]="uploadError()">
          <input id="nx-loads-files" type="file" multiple accept=".csv,.zip,text/csv,application/zip"
                 aria-describedby="nx-loads-files-hint" (change)="choose($event)" data-testid="load-files-input" />
        </ds-field>
        <ds-button variant="primary" [disabled]="uploading()" (pressed)="upload()" data-testid="load-upload">
          {{ uploading() ? t.upload.uploading : t.upload.button }}
        </ds-button>
      </section>

      <section class="nx-card" aria-labelledby="nx-loads-history">
        <h2 id="nx-loads-history">{{ t.history.heading }}</h2>
        @if (error(); as e) {
          <p class="nx-error-text" role="alert">{{ e.detail }}</p>
        } @else if (runs().length === 0 && !loading()) {
          <p class="nx-muted" role="status">{{ t.history.empty }}</p>
        } @else {
          <div class="scroll" tabindex="0" role="region" [attr.aria-label]="t.history.tableLabel">
            <table dsTable [attr.aria-busy]="loading()" data-testid="load-history">
              <caption class="nx-visually-hidden">{{ t.history.tableLabel }}</caption>
              <thead><tr>
                <th scope="col">{{ t.history.columns.prepared }}</th>
                <th scope="col">{{ t.history.columns.status }}</th>
                <th scope="col">{{ t.history.columns.version }}</th>
                <th scope="col">{{ t.history.columns.preparedBy }}</th>
                <th scope="col">{{ t.history.columns.approvedBy }}</th>
              </tr></thead>
              <tbody>
                @for (r of runs(); track r.id) {
                  <tr>
                    <th scope="row"><a [routerLink]="['/admin/data-loads', r.id]">{{ r.preparedAt | nxInstant: timeZone() }}</a></th>
                    <td><ds-badge [tone]="r.status === 'applied' ? 'success' : r.status === 'failed' ? 'error' : 'neutral'">
                      {{ t.statuses[r.status ?? ''] ?? r.status }}</ds-badge></td>
                    <td>{{ r.targetVersion }}</td>
                    <td>{{ r.preparedBy }}</td>
                    <td>{{ r.approvedBy ?? '—' }}</td>
                  </tr>
                }
              </tbody>
            </table>
          </div>
          @if (next()) {
            <ds-button [disabled]="loading()" (pressed)="more()">{{ t.history.more }}</ds-button>
          }
        }
      </section>
    </section>
  `,
  styles: `
    .nx-card { margin-block: var(--nx-space-4); display: flex; flex-direction: column; gap: var(--nx-space-3); align-items: flex-start; }
    .scroll { overflow-x: auto; width: 100%; }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class DataLoadsPage {
  private readonly api = inject(NexusApi);
  private readonly router = inject(Router);
  private readonly announcer = inject(Announcer);
  private readonly context = inject(ContextStore);
  protected readonly t = STRINGS.loads;
  protected readonly runs = signal<LoadRunView[]>([]);
  protected readonly next = signal<string | null>(null);
  protected readonly loading = signal(false);
  protected readonly error = signal<UiError | null>(null);
  protected readonly uploading = signal(false);
  protected readonly uploadError = signal<string | null>(null);
  protected readonly timeZone = () => this.context.me()?.businessTimeZone ?? undefined;
  private files: File[] = [];

  constructor() {
    void this.fetch(undefined);
  }

  protected choose(event: Event): void {
    this.files = Array.from((event.target as HTMLInputElement).files ?? []);
    this.uploadError.set(null);
  }

  protected async upload(): Promise<void> {
    if (this.files.length === 0) {
      this.uploadError.set(this.t.upload.noFiles);
      return;
    }
    this.uploading.set(true);
    this.uploadError.set(null);
    try {
      const staged = await this.api.uploadLoadFiles(this.files);
      this.announcer.polite(this.t.findings.heading);
      await this.router.navigate(['/admin/data-loads', staged.loadId], { state: { staged } });
    } catch (e) {
      this.uploadError.set(UiError.from(e).detail);
    } finally {
      this.uploading.set(false);
    }
  }

  protected more(): void {
    void this.fetch(this.next() ?? undefined);
  }

  private async fetch(cursor: string | undefined): Promise<void> {
    this.loading.set(true);
    try {
      const page = await this.api.loadRuns(cursor);
      this.runs.update((r) => [...r, ...(page.items ?? [])]);
      this.next.set(page.nextCursor ?? null);
    } catch (e) {
      this.error.set(UiError.from(e));
    } finally {
      this.loading.set(false);
    }
  }
}
