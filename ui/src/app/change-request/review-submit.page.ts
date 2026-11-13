import { ChangeDetectionStrategy, Component, computed, effect, inject, input, signal, untracked } from '@angular/core';
import { Router, RouterLink } from '@angular/router';
import { NexusApi } from '../api/nexus-api';
import type { ChangeRequestView, Finding, ItemView, VersionView } from '../api/generated/models';
import { Announcer } from '../core/announcer';
import { ContextStore } from '../core/context.store';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DsButtonComponent, DsFieldComponent, DsToast } from '../shared/ds';
import { NxDatePipe, formatBusinessDate } from '../shared/format/nx-date.pipe';
import { ItemListComponent } from './item-list.component';
import { TrayStore } from './tray.store';

/**
 * Review and submit (LLD §6.1, §12.2; SLICE-01 S1-R4): the draft's items, then the server's validation. Errors block
 * submission and warnings do not (UI_STANDARD §6); the summary links to each item. Submit sends `If-Match`.
 *
 * When submit is refused because the request's version is not working (`version.not_working`, N2703; Phase 3 LLD V.6),
 * the page shows the server's words and offers to move the draft to a working version or to withdraw it.
 */
@Component({
  selector: 'nx-review-submit-page',
  imports: [ItemListComponent, DsButtonComponent, DsFieldComponent, RouterLink, NxDatePipe],
  templateUrl: './review-submit.page.html',
  styleUrl: './review-submit.page.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class ReviewSubmitPage {
  readonly id = input.required<string>();

  private readonly api = inject(NexusApi);
  private readonly tray = inject(TrayStore);
  private readonly router = inject(Router);
  private readonly toast = inject(DsToast);
  private readonly announcer = inject(Announcer);
  private readonly context = inject(ContextStore);
  protected readonly t = STRINGS.review;
  protected readonly common = STRINGS.common;

  protected readonly request = signal<ChangeRequestView | null>(null);
  protected readonly items = signal<ItemView[]>([]);
  protected readonly errors = signal<Finding[]>([]);
  protected readonly warnings = signal<Finding[]>([]);
  protected readonly validating = signal(false);
  protected readonly validated = signal(false);
  protected readonly submitting = signal(false);
  protected readonly error = signal<UiError | null>(null);
  /** Submit was refused because the version is not working: offer "Move to version…" and "Withdraw". */
  protected readonly notWorking = signal(false);
  protected readonly moveTarget = signal('');
  protected readonly moving = signal(false);
  /** Working versions other than the request's own, to move the draft to. */
  protected readonly targets = computed(() => this.context.workingVersions().filter((v) => v.name !== this.request()?.versionName));
  private etag = '';

  constructor() {
    effect(() => {
      const id = this.id();
      untracked(() => void this.load(id));
    });
  }

  protected async load(id: string): Promise<void> {
    this.error.set(null);
    this.notWorking.set(false);
    try {
      const [{ body, etag }, items] = await Promise.all([this.api.request(id), this.api.items(id)]);
      this.request.set(body);
      this.items.set(items.items ?? []);
      this.etag = etag;
      if (body.status === 'draft') {
        await this.validate(id);
      }
    } catch (e) {
      this.error.set(UiError.from(e));
    }
  }

  protected async validate(id: string): Promise<void> {
    this.validating.set(true);
    try {
      const report = await this.api.validate(id);
      this.errors.set(report.errors ?? []);
      this.warnings.set(report.warnings ?? []);
      this.validated.set(true);
      this.announcer.polite((report.errors ?? []).length ? `${this.t.errors}: ${(report.errors ?? []).length}` : this.t.noFindings);
    } catch (e) {
      this.error.set(UiError.from(e));
    } finally {
      this.validating.set(false);
    }
  }

  protected async submit(): Promise<void> {
    this.submitting.set(true);
    this.error.set(null);
    try {
      await this.api.submit(this.id(), this.etag);
      this.tray.reset();
      this.toast.confirm(this.t.submitted);
      this.announcer.polite(this.t.submitted);
      await this.router.navigate(['/requests', this.id()]);
    } catch (e) {
      const error = UiError.from(e);
      const body = error.body as { errors?: Finding[]; warnings?: Finding[] } | null;
      if (error.status === 422 && Array.isArray(body?.errors)) {
        this.errors.set(body!.errors ?? []);
        this.warnings.set(body!.warnings ?? []);
      }
      this.error.set(error);
      if (error.code === 'version.not_working') {
        this.notWorking.set(true);
        void this.context.loadWorkingVersions();
      }
      if (error.status === 412) {
        await this.load(this.id());
      }
    } finally {
      this.submitting.set(false);
    }
  }

  protected optionText(v: VersionView): string {
    return STRINGS.context.versionOption(v.name ?? '', formatBusinessDate(v.businessAsOf));
  }

  /** Moves the draft to the chosen working version, then checks it again there. */
  protected async move(): Promise<void> {
    const target = this.moveTarget();
    if (!target) {
      return;
    }
    this.moving.set(true);
    try {
      const moved = await this.tray.moveTo(this.id(), this.etag, target);
      this.request.set(moved.body);
      this.etag = moved.etag;
      this.notWorking.set(false);
      this.error.set(null);
      this.moveTarget.set('');
      const text = this.t.moved(target);
      this.toast.confirm(text);
      this.announcer.polite(text);
      await this.validate(this.id());
    } catch (e) {
      const error = UiError.from(e);
      this.error.set(error);
      this.announcer.assertive(error.detail);
      if (error.status === 412) {
        await this.load(this.id());
      }
    } finally {
      this.moving.set(false);
    }
  }

  /** Withdraws the draft; the request page then shows it as withdrawn. */
  protected async withdraw(): Promise<void> {
    this.moving.set(true);
    try {
      await this.tray.withdraw(this.id(), this.etag);
      this.toast.confirm(this.t.withdrawn);
      this.announcer.polite(this.t.withdrawn);
      await this.router.navigate(['/requests', this.id()]);
    } catch (e) {
      const error = UiError.from(e);
      this.error.set(error);
      this.announcer.assertive(error.detail);
    } finally {
      this.moving.set(false);
    }
  }
}
