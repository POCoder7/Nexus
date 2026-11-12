import { ChangeDetectionStrategy, Component, OnDestroy, computed, effect, inject, input, signal, untracked } from '@angular/core';
import { Router } from '@angular/router';
import { NexusApi } from '../api/nexus-api';
import type { PropertyValue, SearchHit } from '../api/generated/models';
import { ChangeMode, NodeChangeData, NodeChangeDialogComponent } from './node-change-dialog.component';
import { Announcer } from '../core/announcer';
import { ROW_HEIGHT_PX, SEARCH_DEBOUNCE_MS, SEARCH_MIN_CHARS } from '../core/config';
import { ContextStore } from '../core/context.store';
import { PreferencesStore } from '../core/preferences.store';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DsButtonComponent, DsDialog } from '../shared/ds';
import { AddLeafData, AddLeafDialogComponent, AddLeafResult } from './add-leaf-dialog.component';
import { HierarchyStore } from './hierarchy.store';
import { HierarchyTreeComponent } from './hierarchy-tree.component';
import { NodePanelComponent } from './node-panel.component';
import { NodeStore } from './node.store';

/**
 * Hierarchy workspace (LLD §12.2; HIE-12, SLICE-01 S1-R2/S1-R3): master-detail with the lazy tree on the left and the
 * node panel on the right. The URL carries the hierarchy, the selected node and the as-of date, so a link opens the same
 * view. Changing the as-of date reloads the tree and the panel for that date.
 */
@Component({
  selector: 'nx-hierarchy-workspace-page',
  imports: [HierarchyTreeComponent, NodePanelComponent, DsButtonComponent],
  providers: [HierarchyStore, NodeStore],
  templateUrl: './hierarchy-workspace.page.html',
  styleUrl: './hierarchy-workspace.page.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class HierarchyWorkspacePage implements OnDestroy {
  /** Route parameter and query parameter (component input binding). */
  readonly code = input.required<string>();
  readonly node = input<string | undefined>();

  protected readonly store = inject(HierarchyStore);
  protected readonly nodeStore = inject(NodeStore);
  protected readonly context = inject(ContextStore);
  private readonly prefs = inject(PreferencesStore);
  private readonly api = inject(NexusApi);
  private readonly router = inject(Router);
  private readonly dialog = inject(DsDialog);
  private readonly announcer = inject(Announcer);

  protected readonly t = STRINGS.hierarchy;
  protected readonly common = STRINGS.common;
  protected readonly rowHeight = computed(() => ROW_HEIGHT_PX[this.prefs.density()]);
  protected readonly canPropose = computed(() => this.context.can('PROPOSE', this.code()));

  protected readonly query = signal('');
  protected readonly hits = signal<SearchHit[]>([]);
  protected readonly searchMessage = signal<string | null>(null);
  protected readonly activeHit = signal(-1);
  private searchTimer: ReturnType<typeof setTimeout> | null = null;

  constructor() {
    // (re)open when the hierarchy or the slice changes
    effect(() => {
      const code = this.code();
      const slice = this.context.slice();
      untracked(() => {
        void this.store.open(code, slice).then(() => {
          const h = this.store.hierarchy();
          if (h) {
            this.context.hierarchyName.set(h.name ?? code);
            this.announcer.polite(this.t.loaded(h.name ?? code));
            if (!this.context.isHistorical()) {
              this.prefs.rememberHierarchy(code);
            }
          }
          const target = this.node();
          if (target) {
            void this.store.reveal(target);
          }
        });
      });
    });
    // the panel follows the selection
    effect(() => {
      const id = this.store.selectedId();
      const slice = this.context.slice();
      const code = this.code();
      untracked(() => (id ? void this.nodeStore.load(id, code, slice) : this.nodeStore.clear()));
    });
  }

  ngOnDestroy(): void {
    this.context.hierarchyName.set(null);
  }

  protected onSelect(id: string): void {
    this.store.select(id);
    void this.router.navigate([], { queryParams: { node: id }, queryParamsHandling: 'merge', replaceUrl: true });
  }

  protected expandSiblings(parentId: string | null): void {
    for (const id of this.store.siblingsOf(parentId)) {
      void this.store.expand(id);
    }
  }

  protected openNode(id: string): void {
    void this.store.reveal(id).then((ok) => ok && this.onSelect(id));
  }

  // ------------------------------------------------------------------ in-tree search (LLD §7.2)

  protected onQuery(value: string): void {
    this.query.set(value);
    this.activeHit.set(-1);
    if (this.searchTimer) {
      clearTimeout(this.searchTimer);
    }
    const text = value.trim();
    if (text.length === 0) {
      this.hits.set([]);
      this.searchMessage.set(null);
      return;
    }
    if (text.length < SEARCH_MIN_CHARS) {
      this.hits.set([]);
      this.searchMessage.set(this.t.searchTooShort);
      return;
    }
    this.searchTimer = setTimeout(() => this.runSearch(text), SEARCH_DEBOUNCE_MS);
  }

  protected onSearchKey(event: KeyboardEvent): void {
    const hits = this.hits();
    if (event.key === 'ArrowDown' && hits.length) {
      this.activeHit.set(Math.min(this.activeHit() + 1, hits.length - 1));
    } else if (event.key === 'ArrowUp' && hits.length) {
      this.activeHit.set(Math.max(this.activeHit() - 1, 0));
    } else if (event.key === 'Enter') {
      const hit = hits[Math.max(this.activeHit(), 0)];
      if (hit) {
        this.choose(hit);
      }
    } else if (event.key === 'Escape') {
      this.hits.set([]);
    } else {
      return;
    }
    event.preventDefault();
  }

  protected async choose(hit: SearchHit): Promise<void> {
    this.hits.set([]);
    this.searchMessage.set(null);
    const ok = await this.store.reveal(hit.nodeId!, hit.name);
    if (ok) {
      this.onSelect(hit.nodeId!);
      this.announcer.polite(this.t.showing(hit.name ?? ''));
      queueMicrotask(() => document.querySelector<HTMLElement>('[data-testid=hierarchy-tree]')?.focus());
    }
  }

  protected hitPath(hit: SearchHit): string {
    return (hit.path ?? []).slice(0, -1).map((p) => p.name).join(' › ');
  }

  private async runSearch(text: string): Promise<void> {
    try {
      const page = await this.api.search(this.code(), text, this.context.slice());
      if (text !== this.query().trim()) {
        return;
      }
      this.hits.set(page.items ?? []);
      this.searchMessage.set((page.items ?? []).length ? null : this.t.searchNoResults);
    } catch (e) {
      this.hits.set([]);
      this.searchMessage.set(UiError.from(e).detail);
    }
  }

  // ------------------------------------------------------------------ other changes (scope extension)

  protected openChange(mode: ChangeMode, property?: PropertyValue): void {
    const node = this.nodeStore.detail();
    const today = this.context.businessToday();
    if (!node?.nodeId || !today) {
      return;
    }
    this.dialog.open<boolean, NodeChangeData, NodeChangeDialogComponent>(NodeChangeDialogComponent, {
      mode, hierarchyCode: this.code(), businessToday: today, property,
      node: { id: node.nodeId, name: node.name ?? '', description: node.description ?? null },
    }, 'nx-change-title');
  }

  // ------------------------------------------------------------------ add a leaf (LLD §6.1)

  protected addChild(): void {
    const parent = this.nodeStore.detail();
    const today = this.context.businessToday();
    if (!parent?.nodeId || !today) {
      return;
    }
    this.dialog.open<AddLeafResult, AddLeafData, AddLeafDialogComponent>(AddLeafDialogComponent,
      { hierarchyCode: this.code(), parentId: parent.nodeId, parentName: parent.name ?? '', businessToday: today }, 'nx-add-leaf-title');
  }
}
