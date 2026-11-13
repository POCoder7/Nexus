import { ChangeDetectionStrategy, Component, computed, inject, signal } from '@angular/core';
import { toSignal } from '@angular/core/rxjs-interop';
import { FormControl, NonNullableFormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { NexusApi, etagOfRevision, newIdempotencyKey } from '../api/nexus-api';
import type { VersionView } from '../api/generated/models';
import { Announcer } from '../core/announcer';
import { VERSION_BASES_LIMIT } from '../core/config';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DIALOG_DATA, DialogRef, DsButtonComponent, DsDialogFrameComponent, DsFieldComponent, DsToast } from '../shared/ds';
import { formatBusinessDate } from '../shared/format/nx-date.pipe';

/** Create a version, or edit one (its name and description only: the date and base are fixed once created). */
export type VersionDialogData = { mode: 'create' } | { mode: 'edit'; version: VersionView };

interface SummaryError {
  field: string;
  message: string;
}

const NAME_MAX = 100;   // the server's limit (VersionService.MAX_NAME); the server checks it again

/**
 * New-version and edit-version dialog (Phase 3 LLD V.6; VER-01). The server validates; its words are shown at the field and
 * in a summary that links to each field (UI_STANDARD §6). A copy names its base; leaving the date empty uses the base's
 * date, so the copy shows the same picture. One idempotency key per dialog, so a repeated click creates one version.
 */
@Component({
  selector: 'nx-version-dialog',
  imports: [ReactiveFormsModule, DsDialogFrameComponent, DsFieldComponent, DsButtonComponent],
  templateUrl: './version-dialog.component.html',
  styleUrl: './version-dialog.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class VersionDialogComponent {
  protected readonly data = inject<VersionDialogData>(DIALOG_DATA);
  private readonly ref = inject<DialogRef<VersionView>>(DialogRef);
  private readonly api = inject(NexusApi);
  private readonly toast = inject(DsToast);
  private readonly announcer = inject(Announcer);
  private readonly fb = inject(NonNullableFormBuilder);
  private readonly key = newIdempotencyKey();

  protected readonly t = STRINGS.versions.dialog;
  protected readonly common = STRINGS.common;
  protected readonly titleId = 'nx-version-dialog-title';
  protected readonly editing = this.data.mode === 'edit' ? this.data.version : null;
  protected readonly bases = signal<VersionView[]>([]);
  protected readonly basesError = signal<UiError | null>(null);
  protected readonly serverError = signal<UiError | null>(null);
  protected readonly serverFieldErrors = signal<Record<string, string>>({});
  protected readonly submitted = signal(false);
  protected readonly saving = signal(false);

  protected readonly form = this.fb.group({
    name: this.fb.control(this.editing?.name ?? '', [Validators.required, Validators.maxLength(NAME_MAX)]),
    businessAsOf: this.fb.control(''),
    baseVersion: this.fb.control(''),
    description: this.fb.control(this.editing?.description ?? ''),
  });

  private readonly baseName = toSignal(this.form.controls.baseVersion.valueChanges, { initialValue: '' });
  /** With a base chosen the date may stay empty: the server then uses the base's date. */
  protected readonly baseDate = computed(() => this.bases().find((b) => b.name === this.baseName())?.businessAsOf ?? null);
  protected readonly dateHint = computed(() => {
    const date = this.baseDate();
    return date ? this.t.businessAsOfFromBase(this.baseName(), formatBusinessDate(date)) : this.t.businessAsOfHint;
  });

  constructor() {
    if (!this.editing) {
      this.api.versions(undefined, undefined, VERSION_BASES_LIMIT).then(
        (page) => this.bases.set(page.items ?? []),
        (e: unknown) => this.basesError.set(UiError.from(e)),
      );
    }
  }

  protected fieldId(name: string): string {
    return `nx-version-${name}`;
  }

  protected errorFor(name: 'name' | 'businessAsOf' | 'baseVersion' | 'description'): string | null {
    const server = this.serverFieldErrors()[name];
    if (server) {
      return server;
    }
    const control = this.form.controls[name] as FormControl<string>;
    if (!this.submitted()) {
      return null;
    }
    if (name === 'businessAsOf' && !this.editing && !control.value && !this.form.controls.baseVersion.value) {
      return this.common.required;   // only a copy may leave the date to its base
    }
    if (control.valid) {
      return null;
    }
    if (control.hasError('required')) {
      return this.common.required;
    }
    return control.hasError('maxlength') ? this.common.tooLong : null;
  }

  protected describedBy(name: 'name' | 'businessAsOf' | 'baseVersion' | 'description', hasHint: boolean): string | null {
    const ids = [hasHint ? `${this.fieldId(name)}-hint` : null, this.errorFor(name) ? `${this.fieldId(name)}-error` : null];
    return ids.filter((x) => x).join(' ') || null;
  }

  protected summary(): SummaryError[] {
    const labels = { name: this.t.name, businessAsOf: this.t.businessAsOf, baseVersion: this.t.base, description: this.t.description };
    return (Object.keys(labels) as (keyof typeof labels)[])
      .map((field) => ({ field, error: this.errorFor(field) }))
      .filter((x) => !!x.error)
      .map((x) => ({ field: x.field, message: `${labels[x.field]}: ${x.error}` }));
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
    if (this.summary().length > 0) {
      this.announcer.assertive(this.t.errorSummary);
      queueMicrotask(() => document.getElementById('nx-version-summary')?.focus());
      return;
    }
    const v = this.form.getRawValue();
    this.saving.set(true);
    try {
      const saved = this.editing
        ? await this.api.updateVersion(this.editing.name ?? '', etagOfRevision(this.editing.revision),
          { name: v.name.trim(), description: v.description.trim() })
        : await this.api.createVersion({ name: v.name.trim(), businessAsOf: v.businessAsOf || undefined,
          baseVersion: v.baseVersion || undefined, description: v.description.trim() || undefined }, this.key);
      const text = this.editing ? STRINGS.versions.saved(saved.body.name ?? '') : STRINGS.versions.created(saved.body.name ?? '');
      this.toast.confirm(text);
      this.announcer.polite(text);
      this.ref.close(saved.body);
    } catch (e) {
      const error = UiError.from(e);
      const fields: Record<string, string> = {};
      for (const fe of error.fieldErrors) {
        fields[fe.field] = fe.message;
      }
      if (error.status === 409) {
        fields['name'] = this.t.duplicate;
      }
      this.serverFieldErrors.set(fields);
      this.serverError.set(Object.keys(fields).length ? null : error);
      this.announcer.assertive(Object.keys(fields).length ? this.t.errorSummary : error.detail);
      queueMicrotask(() => document.getElementById('nx-version-summary')?.focus());
    } finally {
      this.saving.set(false);
    }
  }
}
