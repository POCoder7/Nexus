import { ChangeDetectionStrategy, Component, inject, signal } from '@angular/core';
import { NexusApi, etagOfRevision } from '../api/nexus-api';
import type { VersionView } from '../api/generated/models';
import { Announcer } from '../core/announcer';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DIALOG_DATA, DialogRef, DsButtonComponent, DsDialogFrameComponent, DsFieldComponent, DsToast } from '../shared/ds';

export interface TransitionDialogData {
  version: VersionView;
  to: string;
}

/**
 * Transition confirmation (Phase 3 LLD V.6; VER-02): names the action, states its effect, takes an optional reason and
 * sends the transition with If-Match. The server decides (four eyes, open requests, people only) and its words are shown.
 */
@Component({
  selector: 'nx-transition-dialog',
  imports: [DsDialogFrameComponent, DsFieldComponent, DsButtonComponent],
  template: `
    <ds-dialog-frame [title]="t.title(verb, data.version.name ?? '')" [titleId]="titleId" [closeLabel]="common.close" (closed)="close()">
      <div class="body">
        <p data-testid="transition-effect">{{ t.effects[data.to] }}</p>
        <ds-field [label]="t.reason" for="nx-transition-reason">
          <textarea id="nx-transition-reason" rows="2" [value]="reason()" (input)="reason.set($any($event.target).value)"></textarea>
        </ds-field>
        @if (error(); as e) {
          <div class="nx-error-text" role="alert" data-testid="transition-error">
            <p>{{ e.detail }}</p>
            @if (e.correlationId) {
              <p class="nx-muted">{{ common.correlationId }}: <span class="nx-identifier">{{ e.correlationId }}</span></p>
            }
          </div>
        }
      </div>
      <ng-container dialog-actions>
        <ds-button (pressed)="close()">{{ common.cancel }}</ds-button>
        <ds-button [variant]="danger ? 'danger' : 'primary'" [disabled]="saving()" (pressed)="confirm()" data-testid="transition-confirm">
          {{ t.confirm(verb) }}
        </ds-button>
      </ng-container>
    </ds-dialog-frame>
  `,
  styles: `
    .body { display: flex; flex-direction: column; gap: var(--nx-space-4); }
    p { margin: 0; }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class TransitionDialogComponent {
  protected readonly data = inject<TransitionDialogData>(DIALOG_DATA);
  private readonly ref = inject<DialogRef<VersionView>>(DialogRef);
  private readonly api = inject(NexusApi);
  private readonly toast = inject(DsToast);
  private readonly announcer = inject(Announcer);

  protected readonly t = STRINGS.versions.confirm;
  protected readonly common = STRINGS.common;
  protected readonly titleId = 'nx-transition-title';
  protected readonly verb = STRINGS.versions.verbs[this.data.to] ?? this.data.to;
  /** Finalize and expire cannot be undone, so their button reads as destructive. */
  protected readonly danger = this.data.to === 'finalized' || this.data.to === 'expired';
  protected readonly reason = signal('');
  protected readonly saving = signal(false);
  protected readonly error = signal<UiError | null>(null);

  protected close(): void {
    this.ref.close();
  }

  protected async confirm(): Promise<void> {
    this.saving.set(true);
    this.error.set(null);
    try {
      const { body } = await this.api.transitionVersion(this.data.version.name ?? '', etagOfRevision(this.data.version.revision),
        this.data.to, this.reason().trim() || undefined);
      const text = STRINGS.versions.moved(body.name ?? '', STRINGS.versions.statusWords[body.status ?? ''] ?? body.status ?? '');
      this.toast.confirm(text);
      this.announcer.polite(text);
      this.ref.close(body);
    } catch (e) {
      const error = UiError.from(e);
      this.error.set(error);
      this.announcer.assertive(error.detail);
    } finally {
      this.saving.set(false);
    }
  }
}
