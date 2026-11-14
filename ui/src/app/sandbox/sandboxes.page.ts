import { ChangeDetectionStrategy, Component, computed, inject, signal } from '@angular/core';
import { Router, RouterLink } from '@angular/router';
import { Announcer } from '../core/announcer';
import { ContextStore } from '../core/context.store';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DsButtonComponent, DsDateInputComponent, DsFieldComponent, DsTableDirective, DsToast } from '../shared/ds';
import { formatBusinessDate, formatInstant } from '../shared/format/nx-date.pipe';
import { SandboxStore } from './sandbox.store';

/**
 * Sandboxes (NEW-08, Phase 5 LLD §12): the user's open sandboxes and "New sandbox". A new sandbox opens in the hierarchy
 * workspace in sandbox mode, where changes become its items. The server limits how many can be open at once.
 */
@Component({
  selector: 'nx-sandboxes-page',
  imports: [DsButtonComponent, DsDateInputComponent, DsFieldComponent, DsTableDirective, RouterLink],
  providers: [SandboxStore],
  template: `
    <section class="nx-page">
      <h1>{{ t.listTitle }}</h1>
      <p class="nx-muted">{{ t.listIntro }}</p>

      @if (canPropose()) {
        <form class="nx-card create" (submit)="$event.preventDefault(); create()" [attr.aria-label]="t.newTitle">
          <h2>{{ t.newTitle }}</h2>
          <ds-field [label]="t.name" for="nx-sandbox-name" [required]="true" [requiredText]="common.required" [error]="nameError()">
            <input id="nx-sandbox-name" autocomplete="off" [value]="name()" (input)="name.set($any($event.target).value)"
                   [attr.aria-invalid]="!!nameError()" data-testid="sandbox-name" />
          </ds-field>
          <ds-date-input inputId="nx-sandbox-from" [label]="t.effectiveFrom" [value]="effectiveFrom()"
                         [min]="context.businessToday()" (changed)="effectiveFrom.set($event)" />
          <ds-button variant="primary" type="submit" [disabled]="busy()" data-testid="sandbox-create">{{ t.create }}</ds-button>
          @if (error(); as e) {
            <p class="nx-error-text" role="alert" data-testid="sandbox-create-error">{{ e.detail }}</p>
          }
        </form>
      }

      @if (context.mySandboxes().length === 0) {
        <p class="nx-muted" data-testid="no-sandboxes">{{ t.none }}</p>
      } @else {
        <table dsTable [attr.aria-label]="t.tableLabel" data-testid="sandboxes-table">
          <thead>
            <tr>
              <th scope="col">{{ t.columns.name }}</th>
              <th scope="col">{{ t.columns.changes }}</th>
              <th scope="col">{{ t.columns.conflicts }}</th>
              <th scope="col">{{ t.columns.effective }}</th>
              <th scope="col">{{ t.columns.created }}</th>
              <th scope="col"><span class="nx-visually-hidden">{{ t.openInWorkspace }}</span></th>
            </tr>
          </thead>
          <tbody>
            @for (s of context.mySandboxes(); track s.id) {
              <tr>
                <td><a [routerLink]="['/sandboxes', s.id]">{{ s.name }}</a></td>
                <td>{{ s.itemCount }}</td>
                <td>{{ s.conflictCount }}</td>
                <td>{{ date(s.effectiveFrom) }}</td>
                <td>{{ instant(s.createdAt) }}</td>
                <td><a [routerLink]="['/hierarchies']" [queryParams]="{ sandbox: s.id }">{{ t.openInWorkspace }}<span class="nx-visually-hidden">: {{ s.name }}</span></a></td>
              </tr>
            }
          </tbody>
        </table>
      }
    </section>
  `,
  styles: `
    .create { display: flex; flex-wrap: wrap; align-items: flex-end; gap: var(--nx-space-4); margin: var(--nx-space-5) 0; }
    .create h2 { flex-basis: 100%; margin: 0; }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class SandboxesPage {
  protected readonly context = inject(ContextStore);
  private readonly store = inject(SandboxStore);
  private readonly router = inject(Router);
  private readonly toast = inject(DsToast);
  private readonly announcer = inject(Announcer);
  protected readonly t = STRINGS.sandbox;
  protected readonly common = STRINGS.common;

  protected readonly name = signal('');
  protected readonly effectiveFrom = signal<string | null>(null);
  protected readonly busy = signal(false);
  protected readonly error = signal<UiError | null>(null);
  protected readonly nameError = signal<string | null>(null);
  protected readonly canPropose = computed(() => this.context.can('PROPOSE'));
  private readonly zone = computed(() => this.context.me()?.businessTimeZone ?? undefined);

  constructor() {
    void this.context.loadSandboxes();
  }

  protected date(d: string | undefined): string {
    return formatBusinessDate(d ?? null);
  }

  protected instant(i: string | undefined): string {
    return i ? formatInstant(i, this.zone()) : '—';
  }

  /** Creates the sandbox and opens it in the workspace (the hierarchies route opens the last hierarchy used). */
  protected async create(): Promise<void> {
    const name = this.name().trim();
    this.nameError.set(name ? null : this.t.nameRequired);
    if (!name) {
      return;
    }
    this.busy.set(true);
    this.error.set(null);
    try {
      const from = this.effectiveFrom() ?? this.context.businessToday() ?? '';
      const s = await this.store.create(name, from);
      const done = this.t.created(name);
      this.toast.confirm(done);
      this.announcer.polite(done);
      await this.router.navigate(['/hierarchies'], { queryParams: { sandbox: s.id } });
    } catch (e) {
      const error = UiError.from(e);
      this.error.set(error);
      this.announcer.assertive(error.detail);
    } finally {
      this.busy.set(false);
    }
  }
}
