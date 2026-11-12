import { ChangeDetectionStrategy, Component, computed, inject, signal } from '@angular/core';
import { FormControl, FormGroup, FormRecord, NonNullableFormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { NexusApi } from '../api/nexus-api';
import type { FormProperty } from '../api/generated/models';
import { TrayStore } from '../change-request/tray.store';
import { Announcer } from '../core/announcer';
import { ADD_LEAF_MODEL, NODE_KINDS } from '../core/config';
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

/**
 * Add-leaf dialog (LLD §6.1, §12.2; SLICE-01 S1-R4): a typed reactive form built from the model's submit form. Client
 * checks only help (required fields); the server validates on add and on submit and its words are shown at the field and
 * in a summary that links to each field (UI_STANDARD §6). The leaf goes into the draft request, never into live data.
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

  /** A draft fixes the effective date for all its items; a new draft starts on business today. */
  protected readonly lockedDate = computed(() => (this.tray.hasDraft() ? this.tray.request()?.effectiveFrom ?? null : null));

  protected readonly form = new FormGroup({
    name: this.fb.control('', [Validators.required, Validators.maxLength(200)]),
    description: this.fb.control(''),
    nodeKind: this.fb.control<string>('legal_entity'),
    isLeaf: this.fb.control(true),
    effectiveFrom: this.fb.control(this.data.businessToday, Validators.required),
    properties: new FormRecord<FormControl<string>>({}),
  });

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
      },
      (e: unknown) => this.loadError.set(UiError.from(e)),
    );
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
    for (const p of this.formProperties()) {
      add(p.code!, p.label ?? p.code!, this.form.controls.properties.controls[p.code!] as FormControl<unknown>);
    }
    return out;
  }

  protected focusField(field: string, event: Event): void {
    event.preventDefault();
    document.getElementById(this.fieldId(field))?.focus();
  }

  protected close(): void {
    this.ref.close();
  }

  protected async save(): Promise<void> {
    this.submitted.set(true);
    this.serverFieldErrors.set({});
    this.serverError.set(null);
    if (this.form.invalid) {
      this.announcer.assertive(this.t.errorSummary);
      queueMicrotask(() => document.getElementById('nx-add-leaf-summary')?.focus());
      return;
    }
    const v = this.form.getRawValue();
    this.saving.set(true);
    try {
      const result = await this.tray.addLeaf({
        hierarchyCode: this.data.hierarchyCode,
        parentId: this.data.parentId,
        parentName: this.data.parentName,
        name: v.name.trim(),
        description: v.description.trim() || null,
        nodeKind: v.nodeKind,
        isLeaf: v.isLeaf,
        effectiveFrom: v.effectiveFrom,
        properties: Object.entries(v.properties).filter(([, value]) => value !== '').map(([code, value]) => ({ code, value })),
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
