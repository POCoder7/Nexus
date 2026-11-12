import { ScrollingModule } from '@angular/cdk/scrolling';
import { ChangeDetectionStrategy, Component, input, output } from '@angular/core';
import type { WorklistRow } from '../api/generated/models';
import { STRINGS } from '../core/strings';
import { DsBadgeComponent, DsButtonComponent, DsTone } from '../shared/ds';
import { NxInstantPipe } from '../shared/format/nx-date.pipe';

/**
 * `nx-worklist-table` (LLD §3.3, C-3): rows in a CDK virtual viewport (lists can exceed 100 rows, UI_STANDARD §9),
 * status as icon + text, overdue and urgent labelled in words. Presentational: emits open and load more.
 */
@Component({
  selector: 'nx-worklist-table',
  imports: [ScrollingModule, DsBadgeComponent, DsButtonComponent, NxInstantPipe],
  templateUrl: './worklist-table.component.html',
  styleUrl: './worklist-table.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class WorklistTableComponent {
  readonly rows = input.required<WorklistRow[]>();
  readonly loading = input(false);
  readonly hasMore = input(false);
  readonly emptyText = input('');
  readonly rowHeight = input(44);
  readonly open = output<WorklistRow>();
  readonly loadMore = output<void>();
  protected readonly t = STRINGS.worklist;
  protected readonly statuses = STRINGS.timeline.statuses;

  protected tone(row: WorklistRow): DsTone {
    if (row.isOverdue) return 'error';
    if (row.stageStatus === 'claimed') return 'pending';
    if (row.stageStatus === 'completed') return 'success';
    return 'info';
  }

  protected track(_: number, row: WorklistRow): string {
    return row.rowId ?? '';
  }
}
