import { ChangeDetectionStrategy, Component, ElementRef, HostListener, inject, signal } from '@angular/core';
import { Router } from '@angular/router';
import { NexusApi } from '../../api/nexus-api';
import type { SearchHit } from '../../api/generated/models';
import { Announcer } from '../announcer';
import { ContextStore } from '../context.store';
import { PreferencesStore } from '../preferences.store';
import { STRINGS } from '../strings';
import { UiError } from '../ui-error';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * `nx-header-search` (Phase 5 LLD §21.1): "Find a node or request" in the header, on every page. A request id opens the
 * request; other text searches node names in the last hierarchy used, or the first one the user can read (search across
 * hierarchies is QRY-03, not built yet, and the hint says which hierarchy is searched). Results open below the box;
 * Escape or a click outside closes them.
 */
@Component({
  selector: 'nx-header-search',
  template: `
    <form class="hs" role="search" (submit)="search($event)">
      <label for="nx-header-search" class="nx-visually-hidden">{{ t.searchLabel }}</label>
      <input id="nx-header-search" type="search" autocomplete="off" [placeholder]="t.searchPlaceholder" [value]="query()"
             (input)="query.set($any($event.target).value)" aria-describedby="nx-header-search-hint" />
      <button type="submit" class="hs__button">{{ t.search }}</button>
      <span id="nx-header-search-hint" class="nx-visually-hidden">{{ t.searchHint(hierarchyName()) }}</span>
      @if (open()) {
        <div class="hs__results" role="region" [attr.aria-label]="t.searchLabel">
          @if (error(); as e) {
            <p class="nx-error-text" role="status">{{ e }}</p>
          } @else if (hits().length === 0) {
            <p class="nx-muted" role="status">{{ t.noResults }}</p>
          } @else {
            <p class="nx-muted hs__in">{{ t.searchedIn(hierarchyName() ?? '') }}</p>
            <ul data-testid="home-search-results">
              @for (h of hits(); track h.nodeId) {
                <li><a href="#" (click)="$event.preventDefault(); openHit(h)">{{ h.name }}</a></li>
              }
            </ul>
          }
        </div>
      }
    </form>
  `,
  styles: `
    :host { position: relative; flex: 1 1 18rem; max-width: 32rem; }
    .hs { display: flex; gap: var(--nx-space-2); }
    .hs input { flex: 1; min-width: 0; padding: var(--nx-space-2) var(--nx-space-3);
                border: var(--nx-border-width) solid var(--nx-color-border-strong); border-radius: var(--nx-radius-1); }
    .hs__button { padding: var(--nx-space-2) var(--nx-space-4); border: 0; border-radius: var(--nx-radius-1);
                  background: var(--nx-color-action-primary); color: var(--nx-color-text-inverse); cursor: pointer; }
    .hs__results { position: absolute; top: 100%; left: 0; right: 0; z-index: var(--nx-z-dropdown); margin-top: var(--nx-space-1);
                   padding: var(--nx-space-3); border: var(--nx-border-width) solid var(--nx-color-border-strong);
                   background: var(--nx-color-surface-raised); box-shadow: var(--nx-elevation-2); }
    .hs__results ul { margin: 0; padding: 0; list-style: none; }
    .hs__results li a { display: block; padding: var(--nx-space-2); }
    .hs__results p { margin: 0 0 var(--nx-space-2); }
    .hs__in { font-size: var(--nx-font-size-label); }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class HeaderSearchComponent {
  private readonly api = inject(NexusApi);
  private readonly router = inject(Router);
  private readonly context = inject(ContextStore);
  private readonly prefs = inject(PreferencesStore);
  private readonly announcer = inject(Announcer);
  private readonly host = inject(ElementRef<HTMLElement>);
  protected readonly t = STRINGS.home;

  protected readonly query = signal('');
  protected readonly hits = signal<SearchHit[]>([]);
  protected readonly error = signal<string | null>(null);
  protected readonly open = signal(false);
  /** The hierarchy searched: the last one used, else the first readable one (looked up on the first search). */
  protected readonly hierarchyName = signal<string | null>(null);
  private hierarchyCode: string | null = null;

  protected async search(event: Event): Promise<void> {
    event.preventDefault();
    const text = this.query().trim();
    this.error.set(null);
    this.hits.set([]);
    if (UUID.test(text)) {
      this.open.set(false);
      await this.router.navigate(['/requests', text]);
      return;
    }
    if (text.length < 2) {
      this.error.set(STRINGS.hierarchy.searchTooShort);
      this.open.set(true);
      return;
    }
    try {
      const code = await this.target();
      if (!code) {
        this.error.set(this.t.hierarchiesEmpty);
        this.open.set(true);
        return;
      }
      const page = await this.api.search(code, text, this.context.slice(), 10);
      this.hits.set(page.items ?? []);
      this.announcer.polite((page.items ?? []).length ? `${(page.items ?? []).length}` : this.t.noResults);
    } catch (e) {
      this.error.set(UiError.from(e).detail);
    }
    this.open.set(true);
  }

  protected openHit(hit: SearchHit): void {
    this.open.set(false);
    void this.router.navigate(['/hierarchies', this.hierarchyCode], { queryParams: { node: hit.nodeId }, queryParamsHandling: 'merge' });
  }

  @HostListener('keydown.escape')
  protected onEscape(): void {
    this.open.set(false);
  }

  @HostListener('document:click', ['$event'])
  protected onDocumentClick(event: MouseEvent): void {
    if (!this.host.nativeElement.contains(event.target as Node)) this.open.set(false);
  }

  private async target(): Promise<string | null> {
    const last = this.prefs.lastHierarchy();
    if (last && last !== this.hierarchyCode) {
      this.hierarchyCode = last;
      this.hierarchyName.set(last);
    }
    if (!this.hierarchyCode) {
      const first = (await this.api.hierarchies()).items?.[0];
      this.hierarchyCode = first?.code ?? null;
      this.hierarchyName.set(first?.name ?? first?.code ?? null);
    }
    return this.hierarchyCode;
  }
}
