import { ChangeDetectionStrategy, Component, input, output, signal } from '@angular/core';
import type { NodeDetail, NodeRef, PropertyValue } from '../api/generated/models';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DsBadgeComponent, DsButtonComponent, DsTabsComponent } from '../shared/ds';
import { PropertyGridComponent } from './property-grid.component';

/**
 * Node panel (LLD §12.2): attributes, Properties and Relationships tabs (History and Ownership wait for their phases),
 * and "Add child" for limbs. Whether the action is offered is a hint from the server's permissions; when it is not, the
 * panel says why instead of hiding it silently (UI_STANDARD §6). In a historical view the action is not rendered at all.
 */
@Component({
  selector: 'nx-node-panel',
  imports: [DsTabsComponent, DsButtonComponent, DsBadgeComponent, PropertyGridComponent],
  templateUrl: './node-panel.component.html',
  styleUrl: './node-panel.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class NodePanelComponent {
  readonly detail = input<NodeDetail | null>(null);
  readonly path = input<NodeRef[]>([]);
  readonly sourceNames = input<Record<string, string>>({});
  readonly loading = input(false);
  readonly error = input<UiError | null>(null);
  readonly readOnly = input(false);
  readonly canPropose = input(false);
  readonly addChild = output<void>();
  /** Every other change (scope extension); the container opens the dialog. */
  readonly requestChange = output<{ mode: 'details' | 'place' | 'move' | 'remove' | 'delete' | 'property'; property?: PropertyValue }>();
  protected readonly c = STRINGS.change;
  readonly isTop = input(false);
  readonly openNode = output<string>();
  readonly retry = output<void>();

  protected readonly t = STRINGS.hierarchy;
  protected readonly common = STRINGS.common;
  protected readonly tab = signal('properties');
  protected readonly tabs = [
    { id: 'properties', label: STRINGS.hierarchy.tabs.properties },
    { id: 'relationships', label: STRINGS.hierarchy.tabs.relationships },
  ];
}
