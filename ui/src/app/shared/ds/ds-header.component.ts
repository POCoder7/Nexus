import { ChangeDetectionStrategy, Component, input } from '@angular/core';

/**
 * Application header adapter (UI_STANDARD §4). The brand slot stays empty until the design system's header component
 * provides it (OD-02); Nexus never recreates brand marks.
 */
@Component({
  selector: 'ds-header',
  template: `<header class="ds-header">
    <span class="ds-header__brand" data-slot="brand"></span>
    <span class="ds-header__app">{{ appName() }}</span>
    @if (environment()) {
      <span class="ds-header__env">{{ environment() }}</span>
    }
    <span class="ds-header__spacer"></span>
    <ng-content />
  </header>`,
  styleUrl: './ds-header.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class DsHeaderComponent {
  readonly appName = input.required<string>();
  readonly environment = input<string | null>(null);
}
