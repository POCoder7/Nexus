import { LiveAnnouncer } from '@angular/cdk/a11y';
import { Injectable, inject } from '@angular/core';

/** One place for live-region announcements (UI_STANDARD §8): loads, validation results, status changes. */
@Injectable({ providedIn: 'root' })
export class Announcer {
  private readonly live = inject(LiveAnnouncer);

  polite(message: string): void {
    void this.live.announce(message, 'polite');
  }

  assertive(message: string): void {
    void this.live.announce(message, 'assertive');
  }
}
