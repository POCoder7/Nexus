import { ChangeDetectionStrategy, Component, input, signal } from '@angular/core';
import { STRINGS } from '../../core/strings';

/** An identifier in the identifier style with a copy action (UI_STANDARD §7). */
@Component({
  selector: 'nx-copy-id',
  template: `<span class="nx-identifier">{{ value() }}</span>
    <button type="button" class="copy" (click)="copy()" [attr.aria-label]="t.copy + ' ' + value()">
      {{ copied() ? t.copied : t.copy }}
    </button>`,
  styleUrl: './copy-id.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class CopyIdComponent {
  readonly value = input.required<string>();
  protected readonly t = STRINGS.common;
  protected readonly copied = signal(false);

  protected copy(): void {
    navigator.clipboard?.writeText(this.value()).then(
      () => {
        this.copied.set(true);
        setTimeout(() => this.copied.set(false), 2000);
      },
      () => undefined,
    );
  }
}
