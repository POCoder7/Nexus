import { ChangeDetectionStrategy, Component, inject, signal } from '@angular/core';
import { NonNullableFormBuilder, ReactiveFormsModule } from '@angular/forms';
import { NexusApi } from '../api/nexus-api';
import type { ValidationRuleEdit, ValidationRuleView } from '../api/generated/models';
import { Announcer } from '../core/announcer';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DIALOG_DATA, DialogRef, DsButtonComponent, DsDialogFrameComponent, DsFieldComponent, DsToast } from '../shared/ds';

export interface RuleForm {
  name: string;
  description: string;
  externalCode: string;
  severity: string;
  mode: string;
  active: boolean;
  expression: string;
}

/**
 * The PATCH body for a rule edit (ADR-046 D5). A database guard sends its labels only: the server refuses anything else
 * for a guard (N2811), so the form never offers it. An empty external code clears it.
 */
export function editBody(rule: ValidationRuleView, f: RuleForm): ValidationRuleEdit {
  const labels: ValidationRuleEdit = { name: f.name.trim(), description: f.description.trim(), externalCode: f.externalCode.trim() };
  if (rule.enforcement === 'guard') {
    return labels;
  }
  return { ...labels, severity: f.severity, mode: f.mode, active: f.active, expression: f.expression };
}

/** Edit one rule of the catalogue (ADMIN). Server field errors show at the field and in a summary (UI_STANDARD §6). */
@Component({
  selector: 'nx-rule-dialog',
  imports: [ReactiveFormsModule, DsDialogFrameComponent, DsFieldComponent, DsButtonComponent],
  template: `
    <ds-dialog-frame [title]="t.title(rule.externalCode || rule.code || '')" [titleId]="titleId" [closeLabel]="common.close"
                     (closed)="close()">
      <form class="form" [formGroup]="form" (ngSubmit)="save()" novalidate>
        @if (summary().length > 0 || serverError()) {
          <div id="nx-rule-summary" class="summary" role="alert" tabindex="-1" data-testid="rule-summary">
            @if (summary().length > 0) {
              <p>{{ t.errorSummary }}</p>
              <ul>
                @for (e of summary(); track e) {
                  <li>{{ e }}</li>
                }
              </ul>
            }
            @if (serverError(); as se) {
              <p>{{ se.detail }}</p>
            }
          </div>
        }
        @if (guard) {
          <p class="nx-muted" data-testid="rule-guard-note">{{ t.guardNote }}</p>
        }
        <ds-field [label]="t.name" for="nx-rule-name" [error]="fieldErrors()['name'] ?? null">
          <input id="nx-rule-name" formControlName="name" autocomplete="off" />
        </ds-field>
        <ds-field [label]="t.externalCode" for="nx-rule-external" [hint]="t.externalCodeHint" [error]="fieldErrors()['externalCode'] ?? null">
          <input id="nx-rule-external" formControlName="externalCode" autocomplete="off" aria-describedby="nx-rule-external-hint" />
        </ds-field>
        <ds-field [label]="t.description" for="nx-rule-description" [error]="fieldErrors()['description'] ?? null">
          <textarea id="nx-rule-description" formControlName="description" rows="2"></textarea>
        </ds-field>
        @if (!guard) {
          <ds-field [label]="t.severity" for="nx-rule-severity" [error]="fieldErrors()['severity'] ?? null">
            <select id="nx-rule-severity" formControlName="severity">
              @for (s of severities; track s) {
                <option [value]="s">{{ rulesText.severities[s] }}</option>
              }
            </select>
          </ds-field>
          <ds-field [label]="t.mode" for="nx-rule-mode" [error]="fieldErrors()['mode'] ?? null">
            <select id="nx-rule-mode" formControlName="mode">
              @for (m of modes; track m) {
                <option [value]="m">{{ rulesText.modes[m] }}</option>
              }
            </select>
          </ds-field>
          <label class="check"><input type="checkbox" formControlName="active" data-testid="rule-active" /> {{ t.active }}</label>
          <ds-field [label]="t.expression" for="nx-rule-expression" [hint]="t.expressionHint" [error]="fieldErrors()['expression'] ?? null">
            <textarea id="nx-rule-expression" class="nx-identifier" formControlName="expression" rows="5"
                      aria-describedby="nx-rule-expression-hint"></textarea>
          </ds-field>
        }
      </form>
      <ng-container dialog-actions>
        <ds-button (pressed)="close()">{{ common.cancel }}</ds-button>
        <ds-button variant="primary" [disabled]="saving()" (pressed)="save()" data-testid="rule-save">{{ t.save }}</ds-button>
      </ng-container>
    </ds-dialog-frame>
  `,
  styles: `
    .form { display: flex; flex-direction: column; gap: var(--nx-space-4); }
    .summary { padding: var(--nx-space-4); border: var(--nx-border-width) solid var(--nx-color-status-error);
               border-radius: var(--nx-radius-1); color: var(--nx-color-status-error); }
    .summary p, .summary ul { margin: 0; }
    .check { display: flex; gap: var(--nx-space-2); align-items: center; }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class RuleDialogComponent {
  protected readonly rule = inject<ValidationRuleView>(DIALOG_DATA);
  private readonly ref = inject<DialogRef<ValidationRuleView>>(DialogRef);
  private readonly api = inject(NexusApi);
  private readonly toast = inject(DsToast);
  private readonly announcer = inject(Announcer);
  private readonly fb = inject(NonNullableFormBuilder);

  protected readonly t = STRINGS.rules.dialog;
  protected readonly rulesText = STRINGS.rules;
  protected readonly common = STRINGS.common;
  protected readonly titleId = 'nx-rule-dialog-title';
  protected readonly guard = this.rule.enforcement === 'guard';
  protected readonly severities = ['error', 'warning', 'info'];
  protected readonly modes = ['real_time', 'import', 'both'];
  protected readonly saving = signal(false);
  protected readonly serverError = signal<UiError | null>(null);
  protected readonly fieldErrors = signal<Record<string, string>>({});
  protected readonly summary = signal<string[]>([]);

  protected readonly form = this.fb.group({
    name: this.fb.control(this.rule.name ?? ''),
    description: this.fb.control(this.rule.description ?? ''),
    externalCode: this.fb.control(this.rule.externalCode ?? ''),
    severity: this.fb.control(this.rule.severity ?? 'error'),
    mode: this.fb.control(this.rule.mode ?? 'both'),
    active: this.fb.control(this.rule.active !== false),
    expression: this.fb.control(this.rule.expression ?? ''),
  });

  protected close(): void {
    this.ref.close();
  }

  protected async save(): Promise<void> {
    this.serverError.set(null);
    this.fieldErrors.set({});
    this.summary.set([]);
    this.saving.set(true);
    try {
      const saved = await this.api.editValidationRule(this.rule.code ?? '', editBody(this.rule, this.form.getRawValue()));
      const text = STRINGS.rules.saved(saved.externalCode || saved.code || '');
      this.toast.confirm(text);
      this.announcer.polite(text);
      this.ref.close(saved);
    } catch (e) {
      const error = UiError.from(e);
      const fields: Record<string, string> = {};
      for (const fe of error.fieldErrors) {
        fields[fe.field] = fe.message;
      }
      this.fieldErrors.set(fields);
      this.summary.set(Object.entries(fields).map(([f, m]) => `${f}: ${m}`));
      this.serverError.set(Object.keys(fields).length ? null : error);
      this.announcer.assertive(Object.keys(fields).length ? this.t.errorSummary : error.detail);
      queueMicrotask(() => document.getElementById('nx-rule-summary')?.focus());
    } finally {
      this.saving.set(false);
    }
  }
}
