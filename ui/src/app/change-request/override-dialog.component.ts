import { ChangeDetectionStrategy, Component, inject, signal } from '@angular/core';
import { NexusApi, newIdempotencyKey } from '../api/nexus-api';
import { Announcer } from '../core/announcer';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DIALOG_DATA, DialogRef, DsButtonComponent, DsDialogFrameComponent, DsFieldComponent } from '../shared/ds';

export interface OverrideDialogData {
  stageId: string;
  stageLabel: string;
}

/** The decision sent and the stage outcome the server returned. */
export interface OverrideResult {
  decision: 'approve' | 'reject';
  outcome: string;
}

/**
 * Workflow override (ADR-042 D4; Phase 5 LLD §19.7): an ADMIN decides a stage in place of its approvers. Offered only
 * when the server says it would accept it (`youCanOverride`); the dialog states what the override passes over and that
 * it is logged, and requires a reason. The server decides; its words are shown when it refuses.
 */
@Component({
  selector: 'nx-override-dialog',
  imports: [DsDialogFrameComponent, DsFieldComponent, DsButtonComponent],
  template: `
    <ds-dialog-frame [title]="t.title(data.stageLabel)" [titleId]="titleId" [closeLabel]="common.close" (closed)="close()">
      <div class="body">
        <p class="warning" data-testid="override-warning"><span aria-hidden="true">⚠ </span>{{ t.warning }}</p>
        <ds-field [label]="t.reason" for="nx-override-reason" [error]="reasonError()">
          <textarea id="nx-override-reason" rows="3" data-testid="override-reason" [value]="reason()"
                    (input)="reason.set($any($event.target).value)" [attr.aria-invalid]="!!reasonError()"
                    [attr.aria-describedby]="reasonError() ? 'nx-override-reason-error' : null"></textarea>
        </ds-field>
        @if (error(); as e) {
          <div class="nx-error-text" role="alert" data-testid="override-error">
            <p>{{ e.detail }}</p>
            @if (e.correlationId) {
              <p class="nx-muted">{{ common.correlationId }}: <span class="nx-identifier">{{ e.correlationId }}</span></p>
            }
          </div>
        }
      </div>
      <ng-container dialog-actions>
        <ds-button (pressed)="close()">{{ common.cancel }}</ds-button>
        <ds-button variant="danger" [disabled]="saving()" (pressed)="send('reject')" data-testid="override-reject">{{ t.reject }}</ds-button>
        <ds-button variant="primary" [disabled]="saving()" (pressed)="send('approve')" data-testid="override-approve">{{ t.approve }}</ds-button>
      </ng-container>
    </ds-dialog-frame>
  `,
  styles: `
    .body { display: flex; flex-direction: column; gap: var(--nx-space-4); }
    p { margin: 0; }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class OverrideDialogComponent {
  protected readonly data = inject<OverrideDialogData>(DIALOG_DATA);
  private readonly ref = inject<DialogRef<OverrideResult>>(DialogRef);
  private readonly api = inject(NexusApi);
  private readonly announcer = inject(Announcer);

  protected readonly t = STRINGS.override;
  protected readonly common = STRINGS.common;
  protected readonly titleId = 'nx-override-title';
  protected readonly reason = signal('');
  protected readonly reasonError = signal<string | null>(null);
  protected readonly saving = signal(false);
  protected readonly error = signal<UiError | null>(null);

  protected close(): void {
    this.ref.close();
  }

  protected async send(decision: 'approve' | 'reject'): Promise<void> {
    const reason = this.reason().trim();
    if (reason.length < 10) {
      this.reasonError.set(this.t.reasonRequired);
      this.announcer.assertive(this.t.reasonRequired);
      return;
    }
    this.reasonError.set(null);
    this.saving.set(true);
    this.error.set(null);
    try {
      const result = await this.api.overrideStage(this.data.stageId, decision, reason, newIdempotencyKey());
      this.ref.close({ decision, outcome: result.stageOutcome ?? '' });
    } catch (e) {
      const error = UiError.from(e);
      this.error.set(error);
      this.announcer.assertive(error.detail);
    } finally {
      this.saving.set(false);
    }
  }
}
