import { ChangeDetectionStrategy, Component, input, output } from '@angular/core';
import type { RequestEvent } from '../api/generated/models';
import { STRINGS } from '../core/strings';
import { DsButtonComponent } from '../shared/ds';
import { NxInstantPipe } from '../shared/format/nx-date.pipe';
import { eventDetail, eventText } from './audit-text';

/**
 * `nx-request-history` (Phase 5 LLD §18.6, §18.7; AUD-02): everything that happened to a request, oldest first, with who
 * did it and when; notes, comments (an override's reason) and failed policy checks below each event. Presentational.
 */
@Component({
  selector: 'nx-request-history',
  imports: [DsButtonComponent, NxInstantPipe],
  template: `
    <section class="nx-card" aria-labelledby="nx-request-history-title" data-testid="request-history">
      <h2 id="nx-request-history-title">{{ t.title }}</h2>
      @if (events().length === 0 && !loading()) {
        <p class="nx-muted">{{ t.empty }}</p>
      } @else {
        <ol class="events">
          @for (ev of events(); track ev.id) {
            <li [attr.data-event]="ev.type">
              <span class="text">{{ text(ev) }}</span>
              <span class="meta nx-muted">{{ ev.actor ?? t.unknownActor }} · {{ ev.at | nxInstant: timeZone() }}</span>
              @if (detail(ev); as d) {
                <q class="detail">{{ d }}</q>
              }
            </li>
          }
        </ol>
        @if (hasMore()) {
          <ds-button [disabled]="loading()" (pressed)="loadMore.emit()" data-testid="request-history-more">{{ t.showMore }}</ds-button>
        }
      }
    </section>
  `,
  styles: `
    .events { display: flex; flex-direction: column; gap: var(--nx-space-3); margin: 0 0 var(--nx-space-3); padding: 0;
              list-style: none; }
    .events li { display: flex; flex-direction: column; gap: var(--nx-space-1); padding-inline-start: var(--nx-space-3);
                 border-inline-start: var(--nx-border-width) solid var(--nx-color-border-default); }
    .meta { font-size: var(--nx-font-size-label); }
    .detail { font-size: var(--nx-font-size-label); }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class RequestHistoryComponent {
  readonly events = input.required<RequestEvent[]>();
  readonly loading = input(false);
  readonly hasMore = input(false);
  readonly timeZone = input<string | undefined>(undefined);
  readonly loadMore = output<void>();
  protected readonly t = STRINGS.requestHistory;
  protected readonly text = eventText;
  protected readonly detail = eventDetail;
}
