import { ChangeDetectionStrategy, Component, input } from '@angular/core';
import type { PolicyEvaluationView, StageView } from '../api/generated/models';
import { STRINGS } from '../core/strings';
import { DsBadgeComponent, DsTone } from '../shared/ds';
import { NxInstantPipe } from '../shared/format/nx-date.pipe';

/**
 * `nx-workflow-timeline` (LLD §3.3, UI_STANDARD §5): read-only stages with status as icon + text, decisions, and the
 * commit-policy evaluations (shadow mode says plainly that it had no effect). It is a live region, so status changes
 * are announced.
 */
@Component({
  selector: 'nx-workflow-timeline',
  imports: [DsBadgeComponent, NxInstantPipe],
  templateUrl: './workflow-timeline.component.html',
  styleUrl: './workflow-timeline.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class WorkflowTimelineComponent {
  readonly stages = input.required<StageView[]>();
  readonly evaluations = input<PolicyEvaluationView[]>([]);
  /** Display names for user ids (the request page knows the requester and the signed-in user). */
  readonly names = input<Record<string, string>>({});
  protected readonly t = STRINGS.timeline;

  protected tone(status: string | undefined): DsTone {
    switch (status) {
      case 'completed': return 'success';
      case 'active': case 'claimed': return 'pending';
      case 'rejected': return 'error';
      default: return 'neutral';
    }
  }

  protected status(status: string | undefined): string {
    return this.t.statuses[status ?? ''] ?? status ?? '';
  }

  protected outcome(e: PolicyEvaluationView): string {
    return this.t.outcomes[e.outcome ?? ''] ?? e.outcome ?? '';
  }

  protected who(id: string | undefined): string {
    return (id && this.names()[id]) || (id ? id.slice(0, 8) : '');
  }
}
