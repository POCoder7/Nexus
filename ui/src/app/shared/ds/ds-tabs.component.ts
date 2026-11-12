import { ChangeDetectionStrategy, Component, computed, input, model } from '@angular/core';

export interface DsTab {
  id: string;
  label: string;
}

/** Tabs adapter: WAI-ARIA tabs with arrow-key movement; the caller projects the selected panel. */
@Component({
  selector: 'ds-tabs',
  templateUrl: './ds-tabs.component.html',
  styleUrl: './ds-tabs.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class DsTabsComponent {
  readonly tabs = input.required<DsTab[]>();
  readonly label = input.required<string>();
  readonly idPrefix = input('ds-tab');
  readonly selected = model<string>('');
  protected readonly current = computed(() => this.selected() || this.tabs()[0]?.id);

  protected key(event: KeyboardEvent, index: number): void {
    const tabs = this.tabs();
    let next: number;
    if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
    else if (event.key === 'ArrowLeft') next = (index - 1 + tabs.length) % tabs.length;
    else if (event.key === 'Home') next = 0;
    else if (event.key === 'End') next = tabs.length - 1;
    else return;
    event.preventDefault();
    this.selected.set(tabs[next].id);
    (event.currentTarget as HTMLElement).parentElement?.querySelectorAll<HTMLElement>('[role=tab]')[next]?.focus();
  }
}
