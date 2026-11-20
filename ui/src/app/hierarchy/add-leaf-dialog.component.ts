import { ChangeDetectionStrategy, Component, computed, inject, signal } from '@angular/core';
import { toSignal } from '@angular/core/rxjs-interop';
import { FormControl, FormGroup, FormRecord, NonNullableFormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { NexusApi } from '../api/nexus-api';
import type { Finding, FormProperty, HierarchyRule, ItemCommand } from '../api/generated/models';
import { TrayStore } from '../change-request/tray.store';
import { Announcer } from '../core/announcer';
import { ADD_LEAF_MODEL, NODE_KINDS } from '../core/config';
import { ContextStore } from '../core/context.store';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DIALOG_DATA, DialogRef, DsButtonComponent, DsDialogFrameComponent, DsFieldComponent, DsToast } from '../shared/ds';

export interface AddLeafData {
  hierarchyCode: string;
  parentId: string;
  parentName: string;
  businessToday: string;
}

export interface AddLeafResult {
  nodeId: string;
}

interface SummaryError {
  field: string;
  message: string;
}

interface PropertySection {
  category: string;
  properties: FormProperty[];
  required: number;
}

/**
 * Add-leaf dialog (LLD §6.1, §12.2; SLICE-01 S1-R4): a typed reactive form built from the model's submit form. Client
 * checks only help (required fields); the server validates on add and on submit and its words are shown at the field and
 * in a summary that links to each field (UI_STANDARD §6). The leaf goes into the draft request, never into live data.
 *
 * The form lists the properties of this hierarchy only (the server filters them), grouped by category in sections that
 * collapse; sections without a required field start collapsed. A property for leaves only (or for non-leaves only,
 * ADR-046 D2) is offered, and required, only when "This is a leaf" says the new node is one.
 *
 * The hierarchy's rules are listed in words, and Check runs them on the node as filled in, with its properties, in the
 * draft or sandbox it will join, without keeping anything (owner, 2026-11-20); submit still validates the request.
 */
@Component({
  selector: 'nx-add-leaf-dialog',
  imports: [ReactiveFormsModule, DsDialogFrameComponent, DsFieldComponent, DsButtonComponent],
  templateUrl: './add-leaf-dialog.component.html',
  styleUrl: './add-leaf-dialog.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class AddLeafDialogComponent {
  protected readonly data = inject<AddLeafData>(DIALOG_DATA);
  private readonly ref = inject<DialogRef<AddLeafResult>>(DialogRef);
  private readonly api = inject(NexusApi);
  private readonly tray = inject(TrayStore);
  private readonly toast = inject(DsToast);
  private readonly announcer = inject(Announcer);
  private readonly fb = inject(NonNullableFormBuilder);
  private readonly context = inject(ContextStore);

  protected readonly t = STRINGS.addLeaf;
  protected readonly common = STRINGS.common;
  protected readonly kinds = NODE_KINDS;
  protected readonly titleId = 'nx-add-leaf-title';
  protected readonly formProperties = signal<FormProperty[]>([]);
  protected readonly loadError = signal<UiError | null>(null);
  protected readonly serverError = signal<UiError | null>(null);
  protected readonly submitted = signal(false);
  protected readonly saving = signal(false);
  protected readonly serverFieldErrors = signal<Record<string, string>>({});
  /** The hierarchy's rules (this hierarchy's own first), and the result of the last Check, cleared when the form changes. */
  protected readonly rules = signal<HierarchyRule[]>([]);
  protected readonly rulesOpen = signal(true);
  protected readonly checking = signal(false);
  protected readonly checkResult = signal<{ errors: Finding[]; warnings: Finding[] } | null>(null);
  protected readonly checkError = signal<UiError | null>(null);
  protected readonly findingText = STRINGS.sandbox.finding;

  /** A draft fixes the effective date for all its items; a new draft starts on business today. */
  protected readonly lockedDate = computed(() => (this.tray.hasDraft() ? this.tray.request()?.effectiveFrom ?? null : null));

  protected readonly form = new FormGroup({
    name: this.fb.control('', [Validators.required, Validators.maxLength(200)]),
    displayName: this.fb.control('', [Validators.maxLength(200)]),
    description: this.fb.control(''),
    nodeKind: this.fb.control<string>('legal_entity'),
    isLeaf: this.fb.control(true),
    effectiveFrom: this.fb.control(this.data.businessToday, Validators.required),
    properties: new FormRecord<FormControl<string>>({}),
  });

  protected readonly gridText = STRINGS.properties;
  protected readonly isLeafChecked = toSignal(this.form.controls.isLeaf.valueChanges, { initialValue: this.form.controls.isLeaf.value });

  /** The properties that apply to the node as described: all of them, less those for the other kind of node. */
  protected readonly applicable = computed(() => this.formProperties().filter((p) => this.applies(p, this.isLeafChecked())));
  /** Whether some properties are hidden because they are for the other kind of node. */
  protected readonly someHidden = computed(() => this.applicable().length < this.formProperties().length);

  protected readonly sections = computed<PropertySection[]>(() => {
    const byCategory = new Map<string, FormProperty[]>();
    for (const p of this.applicable()) {
      const c = p.category ?? this.gridText.uncategorised;
      byCategory.set(c, [...(byCategory.get(c) ?? []), p]);
    }
    return [...byCategory.entries()]
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([category, properties]) => ({ category, properties, required: properties.filter((p) => p.required).length }));
  });

  /** Collapsed categories; set when the form loads (sections without a required field), then the user's choice. */
  protected readonly collapsed = signal<ReadonlySet<string>>(new Set());
  protected readonly allExpanded = computed(() => this.sections().every((s) => !this.collapsed().has(s.category)));
  protected readonly allCollapsed = computed(() => this.sections().every((s) => this.collapsed().has(s.category)));

  constructor() {
    const locked = this.lockedDate();
    if (locked) {
      this.form.controls.effectiveFrom.setValue(locked);
      this.form.controls.effectiveFrom.disable();
    }
    this.api.submitForm(ADD_LEAF_MODEL, this.data.hierarchyCode).then(
      (f) => {
        const props = (f.properties ?? []).filter((p) => !p.readOnly);
        for (const p of props) {
          // empty, not pre-filled: a value the user leaves alone keeps its default provenance instead of becoming stored
          this.form.controls.properties.addControl(p.code!, this.fb.control('', p.required ? [Validators.required] : []));
        }
        this.formProperties.set(props);
        this.syncApplicable(this.form.controls.isLeaf.value);
        this.collapsed.set(new Set(this.sections().filter((s) => s.required === 0).map((s) => s.category)));
      },
      (e: unknown) => this.loadError.set(UiError.from(e)),
    );
    this.form.controls.isLeaf.valueChanges.subscribe((leaf) => this.syncApplicable(leaf));
    this.api.hierarchyRules(this.data.hierarchyCode).then(
      (rules) => this.rules.set([...rules].sort((a, b) => Number(!!b.thisHierarchyOnly) - Number(!!a.thisHierarchyOnly)
        || (a.code ?? '').localeCompare(b.code ?? ''))),
      () => undefined,   // the list is a help: Check and submit still apply the rules
    );
    this.form.valueChanges.subscribe(() => {
      this.checkResult.set(null);   // the result was for what the form held then
      this.checkError.set(null);
    });
  }

  private applies(p: FormProperty, leaf: boolean): boolean {
    return !p.nodeFilter || p.nodeFilter === 'any' || p.nodeFilter === (leaf ? 'leaf' : 'limb');
  }

  /** A property that does not apply is disabled: not validated, and its value not sent. */
  private syncApplicable(leaf: boolean): void {
    for (const p of this.formProperties()) {
      const control = this.form.controls.properties.controls[p.code!];
      if (this.applies(p, leaf)) {
        control?.enable({ emitEvent: false });
      } else {
        control?.disable({ emitEvent: false });
      }
    }
  }

  protected isExpanded(category: string): boolean {
    return !this.collapsed().has(category);
  }

  protected toggle(category: string): void {
    const next = new Set(this.collapsed());
    if (!next.delete(category)) {
      next.add(category);
    }
    this.collapsed.set(next);
  }

  protected expandAll(): void {
    this.collapsed.set(new Set());
  }

  protected collapseAll(): void {
    this.collapsed.set(new Set([...this.collapsed(), ...this.sections().map((s) => s.category)]));
  }

  protected sectionCount(s: PropertySection): string {
    const count = this.gridText.categoryCount(s.properties.length);
    return s.required > 0 ? `${count.slice(0, -1)}, ${this.t.requiredCount(s.required)})` : count;
  }

  protected sectionId(category: string): string {
    return this.fieldId(`section-${category}`);
  }

  /** Opens the sections that hold a field in error, so every message in the summary can be reached. */
  private expandErrors(): void {
    const next = new Set(this.collapsed());
    for (const s of this.sections()) {
      if (s.properties.some((p) => this.errorFor(p.code!, this.form.controls.properties.controls[p.code!] as FormControl<unknown>))) {
        next.delete(s.category);
      }
    }
    this.collapsed.set(next);
  }

  protected fieldId(name: string): string {
    return `nx-add-leaf-${name.replace(/[^A-Za-z0-9_-]/g, '_')}`;
  }

  /** "Default: <value>" for a property with a default, shown as the field hint. */
  protected defaultHint(p: FormProperty): string | null {
    return p.defaultValue === null || p.defaultValue === undefined ? null
      : this.t.defaultHint(typeof p.defaultValue === 'string' ? p.defaultValue : JSON.stringify(p.defaultValue));
  }

  protected kindLabel(kind: string): string {
    return this.t.kinds[kind] ?? kind;
  }

  protected errorFor(name: string, control: FormControl<unknown> | undefined): string | null {
    const server = this.serverFieldErrors()[name];
    if (server) {
      return server;
    }
    if (!control || !this.submitted() || control.valid) {
      return null;
    }
    if (control.hasError('required')) {
      return this.common.required;
    }
    return control.hasError('maxlength') ? this.common.tooLong : null;
  }

  protected summary(): SummaryError[] {
    const out: SummaryError[] = [];
    const add = (field: string, label: string, control: FormControl<unknown> | undefined) => {
      const e = this.errorFor(field, control);
      if (e) {
        out.push({ field, message: `${label}: ${e}` });
      }
    };
    add('name', this.t.name, this.form.controls.name as FormControl<unknown>);
    add('displayName', this.t.displayName, this.form.controls.displayName as FormControl<unknown>);
    for (const p of this.applicable()) {
      add(p.code!, p.label ?? p.code!, this.form.controls.properties.controls[p.code!] as FormControl<unknown>);
    }
    return out;
  }

  protected focusField(field: string, event: Event): void {
    event.preventDefault();
    const section = this.sections().find((s) => s.properties.some((p) => p.code === field));
    if (section && !this.isExpanded(section.category)) {
      this.toggle(section.category);
    }
    setTimeout(() => document.getElementById(this.fieldId(field))?.focus());   // after the section renders
  }

  /** The node and its property values as the request would get them. */
  private newNode(): { item: ItemCommand; properties: { code: string; value: string }[] } {
    const v = this.form.getRawValue();
    return {
      item: {
        action: 'add_node', hierarchyCode: this.data.hierarchyCode, targetParentId: this.data.parentId,
        payload: { nodeKind: v.nodeKind, name: v.name.trim(), displayName: v.displayName.trim() || undefined,
          description: v.description.trim() || undefined, isLeaf: v.isLeaf } as ItemCommand['payload'],
      },
      // the enabled controls only: a property for the other kind of node is not sent (getRawValue includes disabled ones)
      properties: Object.entries(this.form.controls.properties.value)
        .filter((e): e is [string, string] => e[1] !== undefined && e[1] !== '')
        .map(([code, value]) => ({ code, value })),
    };
  }

  /** Runs the hierarchy's rules on the node as filled in, in the draft or sandbox it would join; nothing is kept. */
  protected async check(): Promise<void> {
    if (!this.form.controls.name.value.trim()) {
      this.submitted.set(true);
      document.getElementById(this.fieldId('name'))?.focus();
      return;
    }
    const { item, properties } = this.newNode();
    this.checking.set(true);
    this.checkError.set(null);
    try {
      const report = await this.api.checkItem({
        requestId: this.context.sandboxParam() ?? this.tray.request()?.id ?? undefined,
        versionName: this.context.workingVersion() ?? undefined,
        effectiveFrom: this.form.getRawValue().effectiveFrom,
        item,
        properties,
      });
      const result = { errors: report.errors ?? [], warnings: report.warnings ?? [] };
      this.checkResult.set(result);
      this.announcer.polite(result.errors.length ? this.t.checkFound(result.errors.length) : this.t.checkOk);
    } catch (e) {
      const error = UiError.from(e);
      this.checkError.set(error);
      this.announcer.assertive(error.detail);
    } finally {
      this.checking.set(false);
    }
  }

  protected close(): void {
    this.ref.close();
  }

  protected async save(): Promise<void> {
    this.submitted.set(true);
    this.serverFieldErrors.set({});
    this.serverError.set(null);
    if (this.form.invalid) {
      this.expandErrors();
      this.announcer.assertive(this.t.errorSummary);
      queueMicrotask(() => document.getElementById('nx-add-leaf-summary')?.focus());
      return;
    }
    const v = this.form.getRawValue();
    const { properties } = this.newNode();
    this.saving.set(true);
    try {
      const result = await this.tray.addLeaf({
        hierarchyCode: this.data.hierarchyCode,
        parentId: this.data.parentId,
        parentName: this.data.parentName,
        name: v.name.trim(),
        displayName: v.displayName.trim() || null,
        description: v.description.trim() || null,
        nodeKind: v.nodeKind,
        isLeaf: v.isLeaf,
        effectiveFrom: v.effectiveFrom,
        properties,
      });
      this.toast.confirm(this.t.added);
      this.announcer.polite(this.t.added);
      this.ref.close({ nodeId: result.nodeId });
    } catch (e) {
      const error = UiError.from(e);
      // map server field errors (e.g. "payload.name") to the form's fields; everything else goes to the summary
      const fields: Record<string, string> = {};
      for (const fe of error.fieldErrors) {
        fields[fe.field.replace(/^payload\./, '')] = fe.message;
      }
      this.serverFieldErrors.set(fields);
      this.serverError.set(Object.keys(fields).length ? null : error);
      this.announcer.assertive(error.detail);
    } finally {
      this.saving.set(false);
    }
  }
}
