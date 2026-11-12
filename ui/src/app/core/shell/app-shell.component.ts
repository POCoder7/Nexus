import { NgComponentOutlet } from '@angular/common';
import { ChangeDetectionStrategy, Component, DestroyRef, ElementRef, computed, inject, signal, viewChild } from '@angular/core';
import { NexusApi } from '../../api/nexus-api';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { NavigationEnd, Router, RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';
import { filter } from 'rxjs';
import { TrayStore } from '../../change-request/tray.store';
import { ChangeRequestTrayComponent } from '../../change-request/change-request-tray.component';
import { DsDateInputComponent, DsButtonComponent, DsHeaderComponent, DsToastHostComponent } from '../../shared/ds';
import { formatBusinessDate } from '../../shared/format/nx-date.pipe';
import { environment } from '../../../environments/environment';
import { ContextStore } from '../context.store';
import { DEV_TOOLS } from '../dev/dev-identity.providers';
import { PreferencesStore } from '../preferences.store';
import { STRINGS } from '../strings';

/**
 * Application shell (LLD §12.2, UI_STANDARD §4): header, left navigation, global context bar with the "Viewing as of"
 * date, the historical banner, the tray and the routed page. In a historical view every write control is removed from
 * the DOM and the tray is hidden (LLD §6.3).
 */
@Component({
  selector: 'nx-app-shell',
  imports: [RouterOutlet, RouterLink, RouterLinkActive, NgComponentOutlet, DsHeaderComponent, DsDateInputComponent,
    DsButtonComponent, DsToastHostComponent, ChangeRequestTrayComponent],
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

  protected readonly asOfText = computed(() => formatBusinessDate(this.context.asOf()));
  /** Count badge on Worklist (LLD §12.2): the Assigned view's count, refreshed on navigation. */
  protected readonly worklistCount = signal<number | null>(null);
  private readonly api = inject(NexusApi);

  constructor() {
    inject(PreferencesStore);   // applies the density preference
    const destroy = inject(DestroyRef);
    let lastPath: string | null = null;
    this.router.events.pipe(filter((e) => e instanceof NavigationEnd), takeUntilDestroyed(destroy)).subscribe((e) => {
      const path = (e as NavigationEnd).urlAfterRedirects.split(/[?#]/)[0];
      let route = this.router.routerState.snapshot.root;
      while (route.firstChild) {
        route = route.firstChild;
      }
      this.context.syncFromUrl(route.queryParamMap.get('asOf'));
      this.refreshCount();
      // focus moves to the page heading when the page changes (LLD §12.3); a query parameter change on the same page
      // (selecting a node, a worklist filter, the as-of date) keeps focus where the user is working
      if (lastPath !== null && path !== lastPath) {
        this.focusHeading();
      }
      lastPath = path;
    });
    void this.context.load().then((me) => (me ? this.tray.load() : undefined));
  }

  protected changeAsOf(date: string | null): void {
    void this.context.setAsOf(date);
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
