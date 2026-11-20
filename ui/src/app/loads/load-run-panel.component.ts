import { ChangeDetectionStrategy, Component, computed, input, output, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import type { IntakeResult, LoadFinding, LoadRunView } from '../api/generated/models';
import { STRINGS } from '../core/strings';
import { DsBadgeComponent, DsButtonComponent, DsFieldComponent, DsTableDirective } from '../shared/ds';
import { loadActions, planOf, reportOf } from './load-run.model';

/**
 * One data load (ADR-046, Phase 4 LLD §17.8.2), in every state: the files and their checks; prepare; the plan and
 * manifest for the approver; the requests while applying; the result. Presentational: the page loads and acts.
 */
@Component({
  selector: 'nx-load-run-panel',
  imports: [RouterLink, DsBadgeComponent, DsButtonComponent, DsFieldComponent, DsTableDirective],
  template: `
    @if (staged(); as s) {
      <section class="nx-card" aria-labelledby="nx-load-files">
        <h2 id="nx-load-files">{{ t.files.heading }}</h2>
        <ul class="files" data-testid="load-files">
          @for (f of s.staged ?? []; track f.fileName) {
            <li><span class="nx-identifier">{{ f.fileName }}</span> <span class="nx-muted">{{ t.files.staged(f.rows ?? 0) }}</span></li>
          }
          @for (f of s.rejected ?? []; track f.fileName) {
            <li class="nx-error-text"><span class="nx-identifier">{{ f.fileName }}</span> · {{ t.files.rejected }}: {{ f.reason }}</li>
          }
        </ul>
      </section>
    }

    <section class="nx-card" aria-labelledby="nx-load-checks">
      <h2 id="nx-load-checks">{{ t.findings.heading }}</h2>
      @if (errors() > 0) {
        <p class="nx-error-text" role="alert" data-testid="load-errors">{{ t.findings.errors(errors()) }}</p>
      }
      @if (findings().length === 0) {
        <p class="nx-muted">{{ t.findings.none }}</p>
      } @else {
        <div class="scroll" tabindex="0" role="region" [attr.aria-label]="t.findings.heading">
          <table dsTable data-testid="load-findings">
            <thead><tr>
              <th scope="col">{{ t.findings.columns.severity }}</th>
              <th scope="col">{{ t.findings.columns.where }}</th>
              <th scope="col">{{ t.findings.columns.detail }}</th>
            </tr></thead>
            <tbody>
              @for (f of findings(); track $index) {
                <tr [attr.data-severity]="f.severity">
                  <td><ds-badge [tone]="tone(f.severity)">{{ t.findings.severities[f.severity ?? ''] ?? f.severity }}</ds-badge></td>
                  <td class="nx-identifier">{{ f.fileName }}{{ f.lineNo ? ':' + f.lineNo : '' }}</td>
                  <td>{{ f.detail }}</td>
                </tr>
              }
            </tbody>
          </table>
        </div>
      }
    </section>

    @if (!run() && errors() === 0) {
      <section class="nx-card" aria-labelledby="nx-load-prepare">
        <h2 id="nx-load-prepare">{{ t.prepare.heading }}</h2>
        <ds-field [label]="t.prepare.version" for="nx-load-version" [hint]="t.prepare.versionHint">
          <input id="nx-load-version" autocomplete="off" [value]="version()" (input)="version.set($any($event.target).value)"
                 aria-describedby="nx-load-version-hint" />
        </ds-field>
        <ds-button variant="primary" [disabled]="busy()" (pressed)="prepare.emit(version().trim() || null)" data-testid="load-prepare">
          {{ t.prepare.button }}
        </ds-button>
      </section>
    }

    @if (run(); as r) {
      <section class="nx-card" aria-labelledby="nx-load-plan">
        <h2 id="nx-load-plan">{{ t.plan.heading }}
          <ds-badge [tone]="statusTone(r.status)" data-testid="load-status">{{ t.statuses[r.status ?? ''] ?? r.status }}</ds-badge>
        </h2>
        @if (plan(); as p) {
          <p>{{ t.plan.target }}: <strong>{{ p.targetVersion }}</strong></p>
          <ol class="steps" data-testid="load-plan">
            @for (s of p.steps; track s.step) {
              <li>{{ s.label }} <span class="nx-muted">({{ s.count }})</span></li>
            }
          </ol>
          @if (p.skipped.length) {
            <p><strong>{{ t.plan.skipped }}:</strong> {{ p.skipped.join(', ') }}</p>
          }
          @if (p.rules.storedInactive.length) {
            <p><strong>{{ t.plan.inactiveRules }}:</strong> {{ p.rules.storedInactive.join(', ') }}</p>
          }
        }
        <p>{{ t.plan.manifest }}: <span class="nx-identifier manifest" data-testid="load-manifest">{{ r.manifestSha256 }}</span></p>
        <p class="nx-muted">{{ t.plan.manifestHint }}</p>
        <p class="nx-muted">{{ t.plan.preparedBy(r.preparedBy ?? '') }}@if (r.approvedBy) { · {{ t.plan.approvedBy(r.approvedBy) }} }</p>
        <div class="actions">
          @if (r.status === 'prepared') {
            <span class="action">
              <ds-button variant="primary" [disabled]="busy() || !actions().approve" [describedBy]="actions().approveWhyNot ? 'nx-load-why-approve' : null"
                         (pressed)="approve.emit(r.manifestSha256 ?? '')" data-testid="load-approve">{{ t.approve }}</ds-button>
              @if (actions().approveWhyNot; as why) { <span id="nx-load-why-approve" class="why" data-testid="why-not">{{ why }}</span> }
            </span>
          }
          @if (r.status === 'approved') {
            <span class="action">
              <ds-button variant="primary" [disabled]="busy() || !actions().apply" [describedBy]="actions().applyWhyNot ? 'nx-load-why-apply' : null"
                         (pressed)="apply.emit()" data-testid="load-apply">{{ t.apply }}</ds-button>
              @if (actions().applyWhyNot; as why) { <span id="nx-load-why-apply" class="why" data-testid="why-not">{{ why }}</span> }
            </span>
          }
          @if (actions().cancel) {
            <ds-button [disabled]="busy()" (pressed)="cancel.emit()" data-testid="load-cancel">{{ t.cancel }}</ds-button>
          }
        </div>
      </section>

      @if ((r.requests ?? []).length > 0 || r.status === 'applying') {
        <section class="nx-card" aria-labelledby="nx-load-requests">
          <h2 id="nx-load-requests">{{ t.progress.heading }}</h2>
          @if (r.status === 'applying') {
            <p class="nx-muted" role="status">{{ t.progress.applying }}</p>
          }
          <ol class="steps" data-testid="load-requests">
            @for (q of r.requests ?? []; track q.seq) {
              <li><a [routerLink]="['/requests', q.changeRequestId]">{{ q.step }}</a> · {{ q.status }}</li>
            }
          </ol>
        </section>
      }

      @if (r.status === 'applied' || r.status === 'failed') {
        <section class="nx-card" aria-labelledby="nx-load-result" data-testid="load-result">
          <h2 id="nx-load-result">{{ t.report.heading }}</h2>
          @if (report()?.reconciliation; as rec) {
            <p [class.nx-error-text]="!rec.clean" data-testid="load-reconciliation">{{ rec.clean ? t.report.clean : t.report.differences }}</p>
            <ul>
              <li>{{ t.report.values(rec.valuesApplied, rec.valuesStaged) }}</li>
              @for (h of rec.hierarchies; track h.hierarchy) {
                <li>{{ t.report.placements(h.hierarchy, h.placementsApplied, h.placementsStaged) }}</li>
              }
            </ul>
          }
          @if (report()?.access?.skipped?.length) {
            <p><strong>{{ t.report.leftForAdmin }}:</strong></p>
            <ul>
              @for (s of report()!.access!.skipped; track s) { <li>{{ s }}</li> }
            </ul>
          }
          @if (r.error) {
            <p class="nx-error-text" role="alert"><strong>{{ t.report.error }}:</strong> {{ r.error }}</p>
          }
        </section>
      }
    }
  `,
  styles: `
    :host { display: flex; flex-direction: column; gap: var(--nx-space-4); }
    .files, .steps { margin: 0; padding-inline-start: var(--nx-space-5); }
    .scroll { overflow-x: auto; }
    .manifest { word-break: break-all; }
    .actions { display: flex; flex-wrap: wrap; gap: var(--nx-space-3); align-items: flex-start; }
    .nx-card > ds-button { align-self: flex-start; }   /* a button is as wide as its label, not the card */
    .action { display: flex; flex-direction: column; gap: var(--nx-space-1); }
    .why { color: var(--nx-color-text-secondary); font-size: var(--nx-font-size-label); }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class LoadRunPanelComponent {
  /** The upload's result, right after uploading (files staged and rejected). */
  readonly staged = input<IntakeResult | null>(null);
  readonly findings = input<LoadFinding[]>([]);
  readonly run = input<LoadRunView | null>(null);
  /** The signed-in user's login: decides who may approve and apply. */
  readonly login = input<string | null>(null);
  readonly busy = input(false);

  readonly prepare = output<string | null>();
  readonly approve = output<string>();
  readonly apply = output<void>();
  readonly cancel = output<void>();

  protected readonly t = STRINGS.loads;
  protected readonly version = signal('');
  protected readonly errors = computed(() => this.findings().filter((f) => f.severity === 'error').length
    + (this.staged()?.rejected?.length ?? 0));
  protected readonly plan = computed(() => planOf(this.run()));
  protected readonly report = computed(() => reportOf(this.run()));
  protected readonly actions = computed(() => loadActions(this.run(), this.login()));

  protected tone(severity: string | undefined): 'error' | 'warning' | 'neutral' {
    return severity === 'error' ? 'error' : severity === 'warning' ? 'warning' : 'neutral';
  }

  protected statusTone(status: string | undefined): 'success' | 'error' | 'warning' | 'info' | 'neutral' {
    return status === 'applied' ? 'success' : status === 'failed' ? 'error' : status === 'prepared' ? 'warning'
      : status === 'applying' || status === 'approved' ? 'info' : 'neutral';
  }
}
