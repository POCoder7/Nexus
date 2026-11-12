import { ChangeDetectionStrategy, Component, inject, signal } from '@angular/core';
import { Density, PreferencesStore, StartPage } from '../core/preferences.store';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DsToast } from '../shared/ds';

/** Preferences (LLD §12.1, OD-27): start page and density, saved server-side as soon as they change. */
@Component({
  selector: 'nx-settings-page',
  templateUrl: './settings.page.html',
  styleUrl: './settings.page.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class SettingsPage {
  protected readonly prefs = inject(PreferencesStore);
  private readonly toast = inject(DsToast);
  protected readonly t = STRINGS.settings;
  protected readonly startPages: StartPage[] = ['home', 'hierarchies', 'worklist'];
  protected readonly densities: Density[] = ['compact', 'comfortable'];
  protected readonly error = signal<UiError | null>(null);

  protected async save(change: { startPage?: StartPage; density?: Density }): Promise<void> {
    this.error.set(null);
    try {
      await this.prefs.save(change);
      this.toast.confirm(this.t.saved);
    } catch (e) {
      this.error.set(UiError.from(e));
    }
  }
}
