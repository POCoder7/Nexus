import { ChangeDetectionStrategy, Component, input, output } from '@angular/core';
import { STRINGS } from '../core/strings';
import { DsButtonComponent } from '../shared/ds';

/**
 * `nx-change-request-tray` (LLD §3.3, UI_STANDARD §5): always visible while a draft exists; says plainly that nothing
 * changes until governance approves. Presentational only.
 */
@Component({
  selector: 'nx-change-request-tray',
  imports: [DsButtonComponent],
  templateUrl: './change-request-tray.component.html',
  styleUrl: './change-request-tray.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class ChangeRequestTrayComponent {
  readonly count = input.required<number>();
  readonly failedCount = input(0);
  readonly busy = input(false);
  /** The draft's version, set only while it differs from the working version chosen in the context bar (Phase 3 LLD V.6). */
  readonly otherVersion = input<string | null>(null);
  readonly review = output<void>();
  readonly retry = output<void>();
  protected readonly t = STRINGS.tray;
}
