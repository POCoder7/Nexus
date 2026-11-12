import { ChangeDetectionStrategy, Component, input, output } from '@angular/core';

/** Date input adapter: ISO value; the browser's own picker until the design-system date picker (OD-04). */
@Component({
  selector: 'ds-date-input',
  template: `<label class="ds-date" [for]="inputId()"><span class="ds-date__label">{{ label() }}</span></label>
    <input type="date" [id]="inputId()" [value]="value() ?? ''" [attr.max]="max()" [attr.min]="min()"
           (change)="emit($event)" />`,
  styleUrl: './ds-date-input.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class DsDateInputComponent {
  readonly label = input.required<string>();
  readonly value = input<string | null>(null);
  readonly inputId = input('ds-date');
  readonly min = input<string | null>(null);
  readonly max = input<string | null>(null);
  readonly changed = output<string | null>();

  protected emit(event: Event): void {
    this.changed.emit((event.target as HTMLInputElement).value || null);
  }
}
