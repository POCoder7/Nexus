import { ChangeDetectionStrategy, Component, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { NexusApi } from '../api/nexus-api';
import type { FormProperty, Impact, ItemCommand, PropertyValue, SearchHit } from '../api/generated/models';
import { TrayStore } from '../change-request/tray.store';
import { Announcer } from '../core/announcer';
import { MAINTAIN_MODEL, NODE_KINDS, SEARCH_MIN_CHARS } from '../core/config';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DIALOG_DATA, DialogRef, DsButtonComponent, DsDialogFrameComponent, DsFieldComponent, DsToast } from '../shared/ds';

export type ChangeMode = 'details' | 'property' | 'place' | 'move' | 'remove' | 'delete' | 'hierarchy';

export interface NodeChangeData {
  mode: ChangeMode;
  hierarchyCode: string | null;
  businessToday: string;
  node?: { id: string; name: string; description: string | null };
  property?: PropertyValue;
}

/**
 * Every steward change other than add-leaf (Phase 3 scope extension): edit details, set or clear a property, place under a
 * second parent, move, remove, delete, and create a hierarchy. Each becomes ONE item of the draft request in the tray;
 * nothing writes live data (UI_STANDARD §6). Remove, delete and move show an impact preview in numbers first and need an
 * explicit confirmation for the wide-impact ones. The server validates on add and again on submit.
 */
@Component({
  selector: 'nx-node-change-dialog',
  imports: [FormsModule, DsDialogFrameComponent, DsFieldComponent, DsButtonComponent],
  templateUrl: './node-change-dialog.component.html',
  styleUrl: './node-change-dialog.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class NodeChangeDialogComponent {
  protected readonly data = inject<NodeChangeData>(DIALOG_DATA);
  private readonly ref = inject<DialogRef<boolean>>(DialogRef);
  private readonly api = inject(NexusApi);
  private readonly tray = inject(TrayStore);
  private readonly toast = inject(DsToast);
  private readonly announcer = inject(Announcer);

  protected readonly t = STRINGS.change;
  protected readonly common = STRINGS.common;
  protected readonly kinds = NODE_KINDS;
  protected readonly kindLabels = STRINGS.addLeaf.kinds;
  protected readonly purposes = Object.keys(STRINGS.change.purposes);
  protected readonly titleId = 'nx-change-title';

  // fields (template-driven; every check that matters is the server's)
  protected readonly name = signal(this.data.node?.name ?? '');
  protected readonly description = signal(this.data.node?.description ?? '');
  protected readonly value = signal(this.currentText());
  protected readonly clear = signal(false);
  protected readonly cascade = signal(false);
  protected readonly confirmed = signal(false);
  protected readonly code = signal('');
  protected readonly purpose = signal('management');
  protected readonly topName = signal('');
  protected readonly topKind = signal('structural');
  protected readonly allowShared = signal(false);

  protected readonly formProperty = signal<FormProperty | null>(null);
  protected readonly impact = signal<Impact | null>(null);
  protected readonly targetQuery = signal('');
  protected readonly targets = signal<SearchHit[]>([]);
  protected readonly target = signal<SearchHit | null>(null);
  protected readonly error = signal<UiError | null>(null);
  protected readonly localError = signal<string | null>(null);
  protected readonly saving = signal(false);
  private searchTimer: ReturnType<typeof setTimeout> | null = null;

  protected readonly title = computed(() => {
    const n = this.data.node?.name ?? '';
    switch (this.data.mode) {
      case 'details': return this.t.titles.details(n);
      case 'property': return this.t.titles.property(this.data.property?.label ?? '', n);
      case 'place': return this.t.titles.place(n);
      case 'move': return this.t.titles.move(n);
      case 'remove': return this.t.titles.remove(n);
      case 'delete': return this.t.titles.delete(n);
      default: return this.t.titles.hierarchy;
    }
  });
  protected readonly needsConfirm = computed(() => this.data.mode === 'remove' || this.data.mode === 'delete');
  protected readonly lockedDate = computed(() => (this.tray.hasDraft() ? this.tray.request()?.effectiveFrom ?? null : null));

  constructor() {
    const { mode, hierarchyCode, node } = this.data;
    if (mode === 'property' && hierarchyCode) {
      // list values and type come from the model's submit form (the property grid does not carry them)
      this.api.submitForm(MAINTAIN_MODEL, hierarchyCode).then(
        (f) => this.formProperty.set((f.properties ?? []).find((p) => p.code === this.data.property?.code) ?? null),
        () => this.formProperty.set(null),
      );
    }
    if ((mode === 'remove' || mode === 'delete' || mode === 'move') && hierarchyCode && node) {
      this.api.impact(hierarchyCode, node.id, {}).then((i) => this.impact.set(i), (e) => this.error.set(UiError.from(e)));
    }
  }

  protected fieldId(name: string): string {
    return `nx-change-${name}`;
  }

  protected close(): void {
    this.ref.close(false);
  }

  // ------------------------------------------------------------------ target picker (place, move)

  protected onTargetQuery(text: string): void {
    this.targetQuery.set(text);
    this.target.set(null);
    if (this.searchTimer) {
      clearTimeout(this.searchTimer);
    }
    if (text.trim().length < SEARCH_MIN_CHARS || !this.data.hierarchyCode) {
      this.targets.set([]);
      return;
    }
    this.searchTimer = setTimeout(() => {
      this.api.search(this.data.hierarchyCode!, text.trim(), {}, 10).then(
        (page) => this.targets.set((page.items ?? []).filter((h) => h.nodeId !== this.data.node?.id)),
        (e) => this.error.set(UiError.from(e)),
      );
    }, 300);
  }

  protected chooseTarget(hit: SearchHit): void {
    this.target.set(hit);
    this.targets.set([]);
    this.targetQuery.set(hit.name ?? '');
  }

  protected targetPath(hit: SearchHit): string {
    return (hit.path ?? []).slice(0, -1).map((p) => p.name).join(' › ');
  }

  // ------------------------------------------------------------------ build the item

  private currentText(): string {
    const v = this.data.property?.value as unknown;
    if (this.data.property?.provenance !== 'stored' || v === null || v === undefined) {
      return '';
    }
    return typeof v === 'string' ? v : JSON.stringify(v);
  }

  /** The typed value as JSON for the property's data type (the server validates type and list membership). */
  private typedValue(): unknown {
    const raw = this.value().trim();
    switch (this.data.property?.dataType) {
      case 'integer':
      case 'decimal':
        return raw === '' ? null : Number(raw);
      case 'boolean':
        return raw === 'true';
      default:
        return raw;
    }
  }

  private build(): { command: ItemCommand; title: string } | null {
    const { mode, hierarchyCode, node, property } = this.data;
    const r = this.t.requestTitles;
    switch (mode) {
      case 'details': {
        const payload: Record<string, unknown> = {};
        if (this.name().trim() !== node!.name) payload['name'] = this.name().trim();
        if ((this.description().trim() || null) !== (node!.description || null)) payload['description'] = this.description().trim() || null;
        if (!this.name().trim()) {
          this.localError.set(`${this.t.name}: ${this.common.required}`);
          return null;
        }
        if (Object.keys(payload).length === 0) {
          this.localError.set(this.t.nothingChanged);
          return null;
        }
        return { command: { action: 'update_node', hierarchyCode: hierarchyCode!, nodeId: node!.id, payload }, title: r.details(node!.name) };
      }
      case 'property':
        if (this.clear()) {
          return { command: { action: 'clear_property', hierarchyCode: hierarchyCode!, nodeId: node!.id, propertyCode: property!.code, payload: {} },
            title: r.clearProperty(property!.label ?? property!.code!, node!.name) };
        }
        return { command: { action: 'set_property', hierarchyCode: hierarchyCode!, nodeId: node!.id, propertyCode: property!.code,
          payload: { value: this.typedValue() } }, title: r.setProperty(property!.label ?? property!.code!, node!.name) };
      case 'place':
      case 'move': {
        const target = this.target();
        if (!target?.nodeId) {
          this.localError.set(`${this.t.target}: ${this.common.required}`);
          return null;
        }
        return { command: { action: mode === 'place' ? 'insert_node' : 'move_node', hierarchyCode: hierarchyCode!, nodeId: node!.id,
          targetParentId: target.nodeId, payload: {} },
          title: mode === 'place' ? r.place(node!.name, target.name ?? '') : r.move(node!.name, target.name ?? '') };
      }
      case 'remove':
        return { command: { action: 'remove_node', hierarchyCode: hierarchyCode!, nodeId: node!.id, payload: { cascade: this.cascade() } },
          title: r.remove(node!.name) };
      case 'delete':
        return { command: { action: 'delete_node', hierarchyCode: hierarchyCode!, nodeId: node!.id, payload: {} }, title: r.delete(node!.name) };
      default:
        if (!this.code().trim() || !this.name().trim() || !this.topName().trim()) {
          this.localError.set(`${this.t.code}, ${this.t.name}, ${this.t.topNodeName}: ${this.common.required}`);
          return null;
        }
        return { command: { action: 'add_hierarchy', payload: { code: this.code().trim(), name: this.name().trim(), purpose: this.purpose(),
          allowSharedNodes: this.allowShared(), topNode: { nodeKind: this.topKind(), name: this.topName().trim() } } },
          title: r.hierarchy(this.code().trim()) };
    }
  }

  protected async save(): Promise<void> {
    this.localError.set(null);
    this.error.set(null);
    if (this.needsConfirm() && !this.confirmed()) {
      this.localError.set(this.t.confirmRequired);
      this.announcer.assertive(this.t.confirmRequired);
      return;
    }
    const built = this.build();
    if (!built) {
      this.announcer.assertive(this.localError() ?? '');
      return;
    }
    this.saving.set(true);
    try {
      await this.tray.addChange(built.command, built.title, this.lockedDate() ?? this.data.businessToday);
      this.toast.confirm(STRINGS.addLeaf.added);
      this.announcer.polite(STRINGS.addLeaf.added);
      this.ref.close(true);
    } catch (e) {
      const error = UiError.from(e);
      this.error.set(error);
      this.announcer.assertive(error.detail);
    } finally {
      this.saving.set(false);
    }
  }
}
