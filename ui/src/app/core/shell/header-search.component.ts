import { nodeLabel } from '../../shared/format/node-label';
import { ChangeDetectionStrategy, Component, ElementRef, HostListener, inject, signal } from '@angular/core';
import { Router, RouterLink } from '@angular/router';
import { NexusApi } from '../../api/nexus-api';
import type { SearchResults } from '../../api/generated/models';
import { Announcer } from '../announcer';
import { ContextStore } from '../context.store';
import { STRINGS } from '../strings';
import { UiError } from '../ui-error';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HIERARCHIES_SHOWN = 3;
const NODES_SHOWN = 5;
const REQUESTS_SHOWN = 3;

/**
 * `nx-header-search` (Phase 5 LLD §21.1, §17.6.1; QRY-03): "Find a node or request" in the header, on every page. A
 * request id opens the request; other text searches hierarchies, nodes and requests the user can see, across every
 * hierarchy, at the slice in view. The list shows the first few of each group and "See all results" (the Search page).
 * Escape or a click outside closes it.
 */
@Component({
  selector: 'nx-header-search',
  imports: [RouterLink],
  template: `
    <form class="hs" role="search" (submit)="search($event)">
      <label for="nx-header-search" class="nx-visually-hidden">{{ h.searchLabel }}</label>
      <input id="nx-header-search" type="search" autocomplete="off" [placeholder]="h.searchPlaceholder" [value]="query()"
             (input)="query.set($any($event.target).value)" />
      <button type="submit" class="hs__button">{{ h.search }}</button>
      @if (open()) {
        <div class="hs__results" role="region" [attr.aria-label]="t.title">
          @if (error(); as e) {
            <p class="nx-error-text" role="status">{{ e }}</p>
          } @else if (results(); as r) {
            @if (empty(r)) {
              <p class="nx-muted" role="status">{{ t.none }}</p>
            } @else {
              @if ((r.hierarchies ?? []).length > 0) {
                <h3>{{ t.groups['hierarchies'] }}</h3>
                <ul>
                  @for (x of (r.hierarchies ?? []).slice(0, hierarchiesShown); track x.code) {
                    <li><a [routerLink]="['/hierarchies', x.code]" [queryParams]="context.workspaceParams()" (click)="close()">{{ x.name }} <span class="nx-muted">({{ x.code }})</span></a></li>
                  }
                </ul>
              }
              @if ((r.nodes?.items ?? []).length > 0) {
                <h3>{{ t.groups['nodes'] }}</h3>
                <ul data-testid="home-search-results">
                  @for (n of (r.nodes?.items ?? []).slice(0, nodesShown); track n.nodeId + '-' + n.hierarchyCode) {
                    <li>
                      <a [routerLink]="['/hierarchies', n.hierarchyCode]" [queryParams]="{ node: n.nodeId }" queryParamsHandling="merge"
                         (click)="close()">{{ label(n) }}</a>
                      <span class="nx-muted"> {{ t.inHierarchy(n.hierarchyCode ?? '') }}</span>
                    </li>
                  }
                </ul>
              }
              @if ((r.requests?.items ?? []).length > 0) {
                <h3>{{ t.groups['requests'] }}</h3>
                <ul>
                  @for (q of (r.requests?.items ?? []).slice(0, requestsShown); track q.id) {
                    <li><a [routerLink]="['/requests', q.id]" (click)="close()">{{ q.title }}</a>
                      <span class="nx-muted"> · {{ statuses[q.status ?? ''] ?? q.status }}</span></li>
                  }
                </ul>
              }
              <a class="hs__all" routerLink="/search" [queryParams]="{ q: query().trim() }" (click)="close()" data-testid="search-see-all">
                {{ t.seeAll }} →</a>
            }
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
    .hs__results h3 { margin: var(--nx-space-2) 0 var(--nx-space-1); font-size: var(--nx-font-size-label);
                      color: var(--nx-color-text-secondary); }
    .hs__results ul { margin: 0; padding: 0; list-style: none; }
    .hs__results li { padding: var(--nx-space-1) 0; }
    .hs__results p { margin: 0; }
    .hs__all { display: inline-block; margin-top: var(--nx-space-3); }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class HeaderSearchComponent {
  /** "display name · code" (ADR-046 D1). */
  protected readonly label = nodeLabel;
  private readonly api = inject(NexusApi);
  private readonly router = inject(Router);
  protected readonly context = inject(ContextStore);
  private readonly announcer = inject(Announcer);
  private readonly host = inject(ElementRef<HTMLElement>);
  protected readonly h = STRINGS.home;
  protected readonly t = STRINGS.search;
  protected readonly statuses = STRINGS.statuses;
  protected readonly hierarchiesShown = HIERARCHIES_SHOWN;
  protected readonly nodesShown = NODES_SHOWN;
  protected readonly requestsShown = REQUESTS_SHOWN;

  protected readonly query = signal('');
  protected readonly results = signal<SearchResults | null>(null);
  protected readonly error = signal<string | null>(null);
  protected readonly open = signal(false);

  protected async search(event: Event): Promise<void> {
    event.preventDefault();
    const text = this.query().trim();
    this.error.set(null);
    this.results.set(null);
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
      const r = await this.api.searchAll(text, this.context.slice(), NODES_SHOWN);
      this.results.set(r);
      this.announcer.polite(this.empty(r) ? this.t.none : this.t.resultsFor(text));
    } catch (e) {
      this.error.set(UiError.from(e).detail);
    }
    this.open.set(true);
  }

  protected empty(r: SearchResults): boolean {
    return !(r.hierarchies ?? []).length && !(r.nodes?.items ?? []).length && !(r.requests?.items ?? []).length;
  }

  protected close(): void {
    this.open.set(false);
  }

  @HostListener('keydown.escape')
  protected onEscape(): void {
    this.open.set(false);
  }

  @HostListener('document:click', ['$event'])
  protected onDocumentClick(event: MouseEvent): void {
    if (!this.host.nativeElement.contains(event.target as Node)) this.open.set(false);
  }
}
