import { ChangeDetectionStrategy, Component, OnDestroy, computed, effect, inject, input, signal, untracked } from '@angular/core';
import { NexusApi, newIdempotencyKey } from '../api/nexus-api';
import type { ChangeRequestView, InstanceView, ItemView } from '../api/generated/models';
import { Announcer } from '../core/announcer';
import { ContextStore } from '../core/context.store';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DsBadgeComponent, DsToast, DsTone } from '../shared/ds';
import { CopyIdComponent } from '../shared/format/copy-id.component';
import { NxDatePipe } from '../shared/format/nx-date.pipe';
import { DecisionIntent, DecisionPanelComponent } from './decision-panel.component';
import { ItemListComponent } from './item-list.component';
import { WorkflowTimelineComponent } from './workflow-timeline.component';

/**
 * Request detail (LLD §12.2; SLICE-01 S1-R5, S1-R6; GOV-12 label): header, items, the workflow timeline with policy
 * evaluations and the decision panel. The engine advances stages asynchronously after a decision, so the page refreshes
 * the instance for a short while afterwards.
 */
@Component({
  selector: 'nx-request-page',
  imports: [ItemListComponent, WorkflowTimelineComponent, DecisionPanelComponent, DsBadgeComponent, CopyIdComponent, NxDatePipe],
  templateUrl: './request.page.html',
  styleUrl: './request.page.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class RequestPage implements OnDestroy {
  readonly id = input.required<string>();

  private readonly api = inject(NexusApi);
  private readonly context = inject(ContextStore);
  private readonly toast = inject(DsToast);
  private readonly announcer = inject(Announcer);
  protected readonly t = STRINGS.request;
  protected readonly statuses = STRINGS.statuses;
  protected readonly common = STRINGS.common;

  protected readonly request = signal<ChangeRequestView | null>(null);
  protected readonly items = signal<ItemView[]>([]);
  protected readonly instance = signal<InstanceView | null>(null);
  protected readonly error = signal<UiError | null>(null);
  protected readonly deciding = signal(false);
  protected readonly decisionError = signal<UiError | null>(null);
  private poll: ReturnType<typeof setTimeout> | null = null;

  protected readonly openStage = computed(() =>
    (this.instance()?.stages ?? []).find((s) => s.status === 'active' || s.status === 'claimed') ?? null);
  protected readonly isMine = computed(() => this.request()?.requesterId === this.context.userId());
  protected readonly names = computed<Record<string, string>>(() => {
    const me = this.context.userId();
    return me ? { [me]: `${this.context.displayName()} (${this.t.you})` } : {};
  });
  protected readonly committedByPolicy = computed(() => {
    if (this.request()?.decisionBasis !== 'approved_policy') {
      return null;
    }
    return (this.instance()?.policyEvaluations ?? []).find((e) => e.outcome === 'auto_committed')?.policyCode ?? '';
  });

  constructor() {
    effect(() => {
      const id = this.id();
      untracked(() => void this.load(id));
    });
  }

  ngOnDestroy(): void {
    if (this.poll) {
      clearTimeout(this.poll);
    }
  }

  protected tone(status: string | undefined): DsTone {
    switch (status) {
      case 'applied': return 'success';
      case 'rejected': case 'apply_failed': return 'error';
      case 'withdrawn': return 'neutral';
      case 'draft': return 'info';
      default: return 'pending';
    }
  }

  protected async load(id: string): Promise<void> {
    try {
      const [{ body }, items] = await Promise.all([this.api.request(id), this.api.items(id)]);
      this.request.set(body);
      this.items.set(items.items ?? []);
      this.instance.set(body.workflowInstanceId ? await this.api.instance(body.workflowInstanceId) : null);
      this.error.set(null);
      // just submitted: the engine opens the first stage shortly after, so follow it until a stage is open
      if (!this.poll && this.instance() && !this.openStage() && ['submitted', 'in_review'].includes(body.status ?? '')) {
        this.followEngine(null, 20);
      }
    } catch (e) {
      this.error.set(UiError.from(e));
    }
  }

  protected async decide(intent: DecisionIntent): Promise<void> {
    this.deciding.set(true);
    this.decisionError.set(null);
    try {
      await this.api.decideStage(intent.stageId, intent.decision, intent.comment, newIdempotencyKey());
      this.toast.confirm(STRINGS.decision.decided);
      this.announcer.polite(STRINGS.decision.decided);
      await this.load(this.id());
      this.followEngine(intent.stageId, 15);
    } catch (e) {
      this.decisionError.set(UiError.from(e));
    } finally {
      this.deciding.set(false);
    }
  }

  /**
   * The engine moves the request on asynchronously; refresh until the decided stage (or, after submit, no stage) is
   * replaced by the next open stage or the request closes.
   */
  private followEngine(stageId: string | null, attempts: number): void {
    if (this.poll) {
      clearTimeout(this.poll);   // one refresh chain at a time
    }
    if (attempts <= 0) {
      this.poll = null;
      return;
    }
    this.poll = setTimeout(async () => {
      await this.load(this.id());
      const stillOpen = stageId !== null && this.openStage()?.instanceStageId === stageId;
      const closed = ['applied', 'rejected', 'withdrawn', 'apply_failed'].includes(this.request()?.status ?? '');
      if (stillOpen || (!closed && !this.openStage())) {
        this.followEngine(stageId, attempts - 1);
      } else {
        this.poll = null;
        this.announcer.polite(this.statuses[this.request()?.status ?? ''] ?? '');
      }
    }, 1000);
  }
}
