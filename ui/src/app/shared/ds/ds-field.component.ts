import { ChangeDetectionStrategy, Component, input } from '@angular/core';

/**
 * Form field adapter: label, required marker, hint and error around a projected native control. The control itself
 * carries `id`, `aria-describedby` and `aria-invalid`, so the field works with typed reactive forms unchanged.
 */
@Component({
  selector: 'ds-field',
  templateUrl: './ds-field.component.html',
  styleUrl: './ds-field.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class DsFieldComponent {
  readonly label = input.required<string>();
  readonly for = input.required<string>();
  readonly required = input(false);
  readonly hint = input<string | null>(null);
  readonly error = input<string | null>(null);
  readonly requiredText = input('Required');
}
