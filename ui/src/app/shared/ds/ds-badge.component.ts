import { ChangeDetectionStrategy, Component, computed, input } from '@angular/core';

export type DsTone = 'info' | 'success' | 'warning' | 'error' | 'pending' | 'neutral';

const ICONS: Record<DsTone, string> = { info: 'ℹ', success: '✓', warning: '!', error: '✕', pending: '◷', neutral: '•' };

/** Status badge adapter: always an icon and text, never colour alone (UI_STANDARD §6, §8). */
@Component({
  selector: 'ds-badge',
  template: `<span [class]="'ds-badge ds-badge--' + tone()"><span class="ds-badge__icon" aria-hidden="true">{{ icon() }}</span><ng-content /></span>`,
  styleUrl: './ds-badge.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class DsBadgeComponent {
  readonly tone = input<DsTone>('neutral');
  protected readonly icon = computed(() => ICONS[this.tone()]);
}
