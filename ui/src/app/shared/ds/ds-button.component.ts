import { ChangeDetectionStrategy, Component, input, output } from '@angular/core';

/** Button adapter (LLD §3.4). Verbs on labels (UI_STANDARD §7). */
@Component({
  selector: 'ds-button',
  template: `<button [attr.type]="type()" [class]="'ds-button ds-button--' + variant()" [disabled]="disabled()"
    [attr.aria-describedby]="describedBy() || null" (click)="pressed.emit($event)"><ng-content /></button>`,
  styleUrl: './ds-button.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class DsButtonComponent {
  readonly variant = input<'primary' | 'secondary' | 'link' | 'danger'>('secondary');
  readonly type = input<'button' | 'submit'>('button');
  readonly disabled = input(false);
  readonly describedBy = input<string | null>(null);
  readonly pressed = output<MouseEvent>();
}
