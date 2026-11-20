import { nodeLabel } from '../shared/format/node-label';
import { ChangeDetectionStrategy, Component, effect, inject, input, signal, untracked } from '@angular/core';
import { RouterLink } from '@angular/router';
import { NexusApi } from '../api/nexus-api';
import type { HierarchyHit, NodeHit, RequestHit } from '../api/generated/models';
import { Announcer } from '../core/announcer';
import { ContextStore } from '../core/context.store';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DsBadgeComponent, DsButtonComponent } from '../shared/ds';
import { NxInstantPipe } from '../shared/format/nx-date.pipe';

const PAGE = 20;

/**
 * Search results (QRY-03; Phase 5 LLD §17.6.1): hierarchies, nodes and requests the user can see, for `?q=`, at the slice
 * in view. Nodes and requests page with "Show more" (keyset, so nothing is skipped or repeated). A node opens in its
 * hierarchy with the node selected and revealed.
 */
@Component({
  selector: 'nx-search-page',
  imports: [RouterLink, DsButtonComponent, DsBadgeComponent, NxInstantPipe],
  template: `
    <section class="nx-page search">
      <h1>{{ q() ? t.resultsFor(q()!) : t.title }}</h1>
      @if (!q() || q()!.trim().length < 2) {
        <p class="nx-muted">{{ t.noQuery }}</p>
      } @else if (error(); as e) {
        <div class="nx-card" role="alert"><p class="nx-error-text">{{ e.detail }}</p></div>
      } @else if (loaded()) {
        @if (hierarchies().length === 0 && nodes().length === 0 && requests().length === 0) {
          <p class="nx-muted" role="status" data-testid="search-none">{{ t.none }}</p>
        }
        @if (hierarchies().length > 0) {
          <section class="nx-card" aria-labelledby="sr-h" data-testid="search-hierarchies">
            <h2 id="sr-h">{{ t.groups['hierarchies'] }} ({{ hierarchies().length }})</h2>
            <ul>
              @for (h of hierarchies(); track h.code) {
                <li><a [routerLink]="['/hierarchies', h.code]">{{ h.name }}</a> <span class="nx-muted">{{ h.code }}{{ h.purpose ? ' · ' + h.purpose : '' }}</span></li>
              }
            </ul>
          </section>
        }
        @if (nodes().length > 0) {
          <section class="nx-card" aria-labelledby="sr-n" data-testid="search-nodes">
            <h2 id="sr-n">{{ t.groups['nodes'] }}</h2>
            <ul>
              @for (n of nodes(); track n.nodeId + '-' + n.hierarchyCode) {
                <li>
                  <a [routerLink]="['/hierarchies', n.hierarchyCode]" [queryParams]="{ node: n.nodeId }" queryParamsHandling="merge">{{ label(n) }}</a>
                  <span class="nx-muted"> {{ t.inHierarchy(n.hierarchyCode ?? '') }} · {{ n.parentName ? t.under(n.parentName) : t.top }}</span>
                  @if (n.shared) {
                    <ds-badge tone="neutral">{{ t.shared }}</ds-badge>
                  }
                  @if (n.matched === 'identifier') {
                    <ds-badge tone="info">{{ t.matchedIdentifier }}</ds-badge>
                  } @else if (n.matched === 'description') {
                    <span class="nx-muted desc">{{ n.description }}</span>
                  }
                </li>
              }
            </ul>
            @if (nodesCursor()) {
              <ds-button [disabled]="busy()" (pressed)="more('nodes')" data-testid="search-more-nodes">{{ t.showMore }}</ds-button>
            }
          </section>
        }
        @if (requests().length > 0) {
          <section class="nx-card" aria-labelledby="sr-r" data-testid="search-requests">
            <h2 id="sr-r">{{ t.groups['requests'] }}</h2>
            <ul>
              @for (r of requests(); track r.id) {
                <li><a [routerLink]="['/requests', r.id]">{{ r.title }}</a>
                  <span class="nx-muted"> · {{ statuses[r.status ?? ''] ?? r.status }} · {{ r.requestedBy }} · {{ r.createdAt | nxInstant: timeZone() }}</span></li>
              }
            </ul>
            @if (requestsCursor()) {
              <ds-button [disabled]="busy()" (pressed)="more('requests')" data-testid="search-more-requests">{{ t.showMore }}</ds-button>
            }
          </section>
        }
      } @else {
        <div class="nx-skeleton" aria-hidden="true"></div>
      }
    </section>
  `,
  styles: `
    .search { display: flex; flex-direction: column; gap: var(--nx-space-4); }
    .search ul { margin: 0 0 var(--nx-space-3); padding: 0; list-style: none; }
    .search li { display: flex; flex-wrap: wrap; align-items: baseline; gap: var(--nx-space-2); padding: var(--nx-space-2) 0;
                 border-bottom: var(--nx-border-width) solid var(--nx-color-border-default); }
    .search h2 { margin: 0 0 var(--nx-space-2); font-size: var(--nx-font-size-heading-3); }
    .desc { flex-basis: 100%; font-size: var(--nx-font-size-label); }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class SearchPage {
  /** "display name · code" (ADR-046 D1). */
  protected readonly label = nodeLabel;
  readonly q = input<string | undefined>();

  private readonly api = inject(NexusApi);
  private readonly context = inject(ContextStore);
  private readonly announcer = inject(Announcer);
  protected readonly t = STRINGS.search;
  protected readonly statuses = STRINGS.statuses;
  protected readonly timeZone = () => this.context.me()?.businessTimeZone ?? undefined;

  protected readonly hierarchies = signal<HierarchyHit[]>([]);
  protected readonly nodes = signal<NodeHit[]>([]);
  protected readonly requests = signal<RequestHit[]>([]);
  protected readonly nodesCursor = signal<string | null>(null);
  protected readonly requestsCursor = signal<string | null>(null);
  protected readonly loaded = signal(false);
  protected readonly busy = signal(false);
  protected readonly error = signal<UiError | null>(null);

  constructor() {
    effect(() => {
      const q = this.q()?.trim() ?? '';
      const slice = this.context.slice();
      untracked(() => (q.length >= 2 ? void this.load(q, slice) : this.loaded.set(false)));
    });
  }

  private async load(q: string, slice: ReturnType<ContextStore['slice']>): Promise<void> {
    this.loaded.set(false);
    this.error.set(null);
    try {
      const r = await this.api.searchAll(q, slice, PAGE);
      if (this.q()?.trim() !== q) return;
      this.hierarchies.set(r.hierarchies ?? []);
      this.nodes.set(r.nodes?.items ?? []);
      this.nodesCursor.set(r.nodes?.nextCursor ?? null);
      this.requests.set(r.requests?.items ?? []);
      this.requestsCursor.set(r.requests?.nextCursor ?? null);
      this.loaded.set(true);
      this.announcer.polite(this.t.resultsFor(q));
    } catch (e) {
      this.error.set(UiError.from(e));
    }
  }

  protected async more(type: 'nodes' | 'requests'): Promise<void> {
    const q = this.q()?.trim() ?? '';
    this.busy.set(true);
    try {
      if (type === 'nodes') {
        const r = await this.api.searchAll(q, this.context.slice(), PAGE, 'nodes', this.nodesCursor() ?? undefined);
        this.nodes.update((list) => [...list, ...(r.nodes?.items ?? [])]);
        this.nodesCursor.set(r.nodes?.nextCursor ?? null);
      } else {
        const r = await this.api.searchAll(q, this.context.slice(), PAGE, 'requests', this.requestsCursor() ?? undefined);
        this.requests.update((list) => [...list, ...(r.requests?.items ?? [])]);
        this.requestsCursor.set(r.requests?.nextCursor ?? null);
      }
    } catch (e) {
      this.error.set(UiError.from(e));
    } finally {
      this.busy.set(false);
    }
  }
}
