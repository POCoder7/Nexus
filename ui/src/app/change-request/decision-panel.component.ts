import { ChangeDetectionStrategy, Component, input, output, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import type { StageView } from '../api/generated/models';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DsButtonComponent, DsFieldComponent } from '../shared/ds';

export interface DecisionIntent {
  stageId: string;
  decision: 'approve' | 'reject';
  comment?: string;
}

/**
 * Decision panel (LLD §12.2; SLICE-01 S1-R5). Whether the user can act comes from the server (`youCanAct`); when they
 * cannot, the panel shows the server's reason in words (e.g. "You submitted this request") rather than hiding the action
 * silently (UI_STANDARD §6). Reject needs a comment.
 */
@Component({
  selector: 'nx-decision-panel',
  imports: [FormsModule, DsButtonComponent, DsFieldComponent],
  templateUrl: './decision-panel.component.html',
  styleUrl: './decision-panel.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class DecisionPanelComponent {
  readonly stage = input<StageView | null>(null);
  /** The server's sentence when the user cannot act (from a refused decision or the request's state). */
  readonly reason = input<string | null>(null);
  readonly busy = input(false);
  readonly error = input<UiError | null>(null);
  readonly decide = output<DecisionIntent>();

  protected readonly t = STRINGS.decision;
  protected readonly comment = signal('');
  protected readonly commentError = signal<string | null>(null);

  protected approveLabel(): string {
    return this.stage()?.type === 'commit' ? this.t.commit : this.t.approve;
  }

  protected send(decision: 'approve' | 'reject'): void {
    const stage = this.stage();
    if (!stage?.instanceStageId) {
      return;
    }
    const comment = this.comment().trim();
    if (decision === 'reject' && !comment) {
      this.commentError.set(this.t.commentRequired);
      return;
    }
    this.commentError.set(null);
    this.decide.emit({ stageId: stage.instanceStageId, decision, comment: comment || undefined });
  }
}
