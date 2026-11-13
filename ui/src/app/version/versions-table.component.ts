import { ChangeDetectionStrategy, Component, input, output } from '@angular/core';
import type { VersionTransition, VersionView } from '../api/generated/models';
import { STRINGS } from '../core/strings';
import { DsBadgeComponent, DsButtonComponent, DsTableDirective, DsTone } from '../shared/ds';
import { NxDatePipe, NxInstantPipe } from '../shared/format/nx-date.pipe';

export interface TransitionChoice {
  version: VersionView;
  to: string;
}

const TONES: Record<string, DsTone> = { working: 'info', submitted: 'pending', finalized: 'success', expired: 'neutral' };

/**
 * `nx-versions-table` (Phase 3 LLD V.6): one row per version with its status as icon and word. "Open picture" is always
 * offered. Version administrators also get each transition and Edit exactly as the server lists them; a refused one is
 * disabled and the server's reason is shown as text next to it (and described to assistive technology). Presentational.
 */
@Component({
  selector: 'nx-versions-table',
  imports: [DsBadgeComponent, DsButtonComponent, DsTableDirective, NxDatePipe, NxInstantPipe],
  templateUrl: './versions-table.component.html',
  styleUrl: './versions-table.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class VersionsTableComponent {
  readonly rows = input.required<VersionView[]>();
  readonly loading = input(false);
  readonly hasMore = input(false);
  readonly emptyText = input('');
  /** Holder of ADMIN_VERSION: show the transitions and Edit. Only a hint; the server decides. */
  readonly canAdmin = input(false);
  readonly timeZone = input<string | undefined>(undefined);
  readonly openPicture = output<VersionView>();
  readonly transition = output<TransitionChoice>();
  readonly edit = output<VersionView>();
  readonly loadMore = output<void>();
  protected readonly t = STRINGS.versions;

  protected tone(status: string | undefined): DsTone {
    return TONES[status ?? ''] ?? 'neutral';
  }

  protected verb(tr: VersionTransition): string {
    return this.t.verbs[tr.to ?? ''] ?? tr.to ?? '';
  }

  /** A stable id for the reason next to a refused action, so the disabled button can point at it. */
  protected whyId(index: number, what: string): string {
    return `nx-version-${index}-${what}-why`;
  }
}
