import { ChangeDetectionStrategy, Component, Injectable, inject, signal } from '@angular/core';

/** Toast adapter: confirmations only (UI_STANDARD §6); anything that needs action goes inline or to the worklist. */
@Injectable({ providedIn: 'root' })
export class DsToast {
  readonly message = signal<string | null>(null);
  private timer: ReturnType<typeof setTimeout> | null = null;

  confirm(message: string): void {
    this.message.set(message);
    if (this.timer) {
      clearTimeout(this.timer);
    }
    this.timer = setTimeout(() => this.message.set(null), 5000);
  }
}

@Component({
  selector: 'ds-toast-host',
  template: `<div class="ds-toast" role="status" aria-live="polite">
    @if (toast.message(); as m) {
      <span><span aria-hidden="true">✓ </span>{{ m }}</span>
    }
  </div>`,
  styleUrl: './ds-toast.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class DsToastHostComponent {
  protected readonly toast = inject(DsToast);
}
