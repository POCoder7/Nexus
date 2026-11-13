import { ChangeDetectionStrategy, Component, computed, input, output } from '@angular/core';
import type { VersionView } from '../api/generated/models';
import { STRINGS } from '../core/strings';
import { formatBusinessDate } from '../shared/format/nx-date.pipe';

/**
 * `nx-version-picker` (Phase 3 LLD V.6; VER-01): the context-bar choice of the working version new requests are raised in.
 * A native select of working versions, each named with its business date. The current choice stays in the list even when
 * it is not on the first page. Presentational: emits the chosen name; the shell saves it as a preference.
 */
@Component({
  selector: 'nx-version-picker',
  template: `
    <label class="label" [for]="inputId()">{{ t.version }}</label>
    @if (options().length === 0) {
      <span data-testid="context-version">{{ t.noVersion }}</span>
    } @else {
      <select [id]="inputId()" data-testid="context-version" [disabled]="busy()" [attr.aria-describedby]="inputId() + '-hint'"
              (change)="choose($any($event.target).value)">
        @for (v of options(); track v.name) {
          <option [value]="v.name" [selected]="v.name === value()">{{ optionText(v) }}</option>
        }
      </select>
      <span class="nx-visually-hidden" [id]="inputId() + '-hint'">{{ t.versionHint }}</span>
    }
  `,
  styles: `
    :host { display: inline-flex; align-items: center; gap: var(--nx-space-3); }
    .label { font-size: var(--nx-font-size-label); color: var(--nx-color-text-secondary); }
    select {
      padding: var(--nx-space-1) var(--nx-space-3);
      border: var(--nx-border-width) solid var(--nx-color-border-strong);
      border-radius: var(--nx-radius-1);
      background: var(--nx-color-surface-raised);
      color: var(--nx-color-text-primary);
    }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class VersionPickerComponent {
  readonly versions = input.required<VersionView[]>();
  readonly value = input<string | null>(null);
  readonly busy = input(false);
  readonly inputId = input('nx-working-version');
  readonly chosen = output<string>();
  protected readonly t = STRINGS.context;

  /** The working versions, with the current choice added when the first page does not include it. */
  protected readonly options = computed<VersionView[]>(() => {
    const list = this.versions();
    const current = this.value();
    return current && !list.some((v) => v.name === current) ? [{ name: current }, ...list] : list;
  });

  protected optionText(v: VersionView): string {
    return v.businessAsOf ? this.t.versionOption(v.name ?? '', formatBusinessDate(v.businessAsOf)) : v.name ?? '';
  }

  protected choose(name: string): void {
    if (name && name !== this.value()) {
      this.chosen.emit(name);
    }
  }
}
