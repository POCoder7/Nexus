import { NgComponentOutlet } from '@angular/common';
import { ChangeDetectionStrategy, Component, DestroyRef, ElementRef, computed, inject, signal, viewChild } from '@angular/core';
import { NexusApi } from '../../api/nexus-api';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { NavigationEnd, Router, RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';
import { filter } from 'rxjs';
import { TrayStore } from '../../change-request/tray.store';
import { ChangeRequestTrayComponent } from '../../change-request/change-request-tray.component';
import { DsDateInputComponent, DsButtonComponent, DsHeaderComponent, DsToast, DsToastHostComponent } from '../../shared/ds';
import { VersionPickerComponent } from '../../version/version-picker.component';
import { environment } from '../../../environments/environment';
import { Announcer } from '../announcer';
import { ContextStore } from '../context.store';
import { DEV_TOOLS } from '../dev/dev-identity.providers';
import { PreferencesStore } from '../preferences.store';
import { STRINGS } from '../strings';
import { UiError } from '../ui-error';

/**
 * Application shell (LLD §12.2, UI_STANDARD §4): header, left navigation, global context bar with the "Viewing as of"
 * date, the working-version picker (Phase 3 LLD V.6), the historical or picture banner, the tray and the routed page. In a
 * historical view every write control is removed from the DOM and the tray is hidden (LLD §6.3).
 */
@Component({
  selector: 'nx-app-shell',
  imports: [RouterOutlet, RouterLink, RouterLinkActive, NgComponentOutlet, DsHeaderComponent, DsDateInputComponent,
    DsButtonComponent, DsToastHostComponent, ChangeRequestTrayComponent, VersionPickerComponent],
  templateUrl: './app-shell.component.html',
  styleUrl: './app-shell.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class AppShellComponent {
  protected readonly t = STRINGS;
  protected readonly context = inject(ContextStore);
  protected readonly tray = inject(TrayStore);
  protected readonly devPicker = DEV_TOOLS.picker;
  protected readonly envName = environment.name;
  private readonly router = inject(Router);
  private readonly main = viewChild.required<ElementRef<HTMLElement>>('main');

  private readonly prefs = inject(PreferencesStore);   // injecting it also applies the density preference
  private readonly toast = inject(DsToast);
  private readonly announcer = inject(Announcer);
  protected readonly versionBusy = signal(false);
  protected readonly versionError = signal<UiError | null>(null);
  /** The open draft's version while it differs from the working version chosen in the context bar. */
  protected readonly trayOtherVersion = computed(() => {
    const draft = this.tray.request()?.versionName ?? null;
    return draft && draft !== this.context.workingVersion() ? draft : null;
  });
  /** Count badge on Worklist (LLD §12.2): the Assigned view's count, refreshed on navigation. */
  protected readonly worklistCount = signal<number | null>(null);
  private readonly api = inject(NexusApi);

  constructor() {
    const destroy = inject(DestroyRef);
    let lastPath: string | null = null;
    this.router.events.pipe(filter((e) => e instanceof NavigationEnd), takeUntilDestroyed(destroy)).subscribe((e) => {
      const path = (e as NavigationEnd).urlAfterRedirects.split(/[?#]/)[0];
      let route = this.router.routerState.snapshot.root;
      while (route.firstChild) {
        route = route.firstChild;
      }
      const q = route.queryParamMap;
      this.context.syncFromUrl(q.get('asOf'), q.get('recordedAsOf'), q.get('version'));
      this.refreshCount();
      // focus moves to the page heading when the page changes (LLD §12.3); a query parameter change on the same page
      // (selecting a node, a worklist filter, the as-of date) keeps focus where the user is working
      if (lastPath !== null && path !== lastPath) {
        this.focusHeading();
      }
      lastPath = path;
    });
    void this.context.load().then((me) => {
      if (me) {
        void this.tray.load();
        void this.context.loadWorkingVersions();
      }
    });
  }

  protected changeAsOf(date: string | null): void {
    void this.context.setAsOf(date);
  }

  /** Saves the chosen working version as a preference (ADR-037); the next draft is raised in it. */
  protected async chooseVersion(name: string): Promise<void> {
    this.versionBusy.set(true);
    this.versionError.set(null);
    try {
      await this.prefs.saveWorkingVersion(name);
      const text = this.t.context.versionSaved(name);
      this.toast.confirm(text);
      this.announcer.polite(text);
    } catch (e) {
      const error = UiError.from(e);
      this.versionError.set(error);
      this.announcer.assertive(error.detail);
      void this.context.loadWorkingVersions();   // the version may have left working since the list was read
    } finally {
      this.versionBusy.set(false);
    }
  }

  protected review(): void {
    const id = this.tray.request()?.id;
    if (id) {
      void this.router.navigate(['/requests', id, 'review']);
    }
  }

  private refreshCount(): void {
    void this.context.load().then((me) => {
      if (me) {
        this.api.worklist('assigned', undefined, undefined, 1).then(
          (page) => this.worklistCount.set(page.counts?.['assigned'] ?? 0),
          () => this.worklistCount.set(null),
        );
      }
    });
  }

  private focusHeading(): void {
    setTimeout(() => {
      const heading = this.main().nativeElement.querySelector<HTMLElement>('h1');
      if (heading) {
        heading.setAttribute('tabindex', '-1');
        heading.focus();
      }
    });
  }
}
