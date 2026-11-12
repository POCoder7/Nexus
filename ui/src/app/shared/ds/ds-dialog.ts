import { DIALOG_DATA, Dialog, DialogRef } from '@angular/cdk/dialog';
import { ChangeDetectionStrategy, Component, Injectable, Type, inject, input, output } from '@angular/core';

export { DIALOG_DATA, DialogRef };

/**
 * Dialog adapter (LLD §3.4) on the CDK dialog: focus is trapped, Escape closes, and focus returns to the trigger on close
 * (UI_STANDARD §8, LLD §12.3).
 */
@Injectable({ providedIn: 'root' })
export class DsDialog {
  private readonly dialog = inject(Dialog);

  open<R, D, C>(component: Type<C>, data: D, labelledBy: string): DialogRef<R, C> {
    return this.dialog.open<R, D, C>(component, {
      data,
      ariaLabelledBy: labelledBy,
      restoreFocus: true,
      autoFocus: 'first-tabbable',
      hasBackdrop: true,
      maxWidth: '40rem',
      width: '90vw',
    });
  }
}

/** The frame every dialog uses: title, scrollable content, actions. */
@Component({
  selector: 'ds-dialog-frame',
  template: `<section class="ds-dialog">
    <header class="ds-dialog__head">
      <h2 [id]="titleId()">{{ title() }}</h2>
      <button type="button" class="ds-dialog__close" [attr.aria-label]="closeLabel()" (click)="closed.emit()">✕</button>
    </header>
    <div class="ds-dialog__body"><ng-content /></div>
    <footer class="ds-dialog__actions"><ng-content select="[dialog-actions]" /></footer>
  </section>`,
  styleUrl: './ds-dialog.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class DsDialogFrameComponent {
  readonly title = input.required<string>();
  readonly titleId = input.required<string>();
  readonly closeLabel = input('Close');
  readonly closed = output<void>();
}
