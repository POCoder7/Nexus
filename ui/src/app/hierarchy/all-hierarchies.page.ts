import { ChangeDetectionStrategy, Component, computed, effect, inject, untracked } from '@angular/core';
import { RouterLink } from '@angular/router';
import { Announcer } from '../core/announcer';
import { ROW_HEIGHT_PX } from '../core/config';
import { ContextStore } from '../core/context.store';
import { PreferencesStore } from '../core/preferences.store';
import { STRINGS } from '../core/strings';
import { formatBusinessDate } from '../shared/format/nx-date.pipe';
import { AllHierarchiesStore } from './all-hierarchies.store';
import { HierarchyTreeComponent } from './hierarchy-tree.component';
import { NodePanelComponent } from './node-panel.component';
import { NodeStore } from './node.store';

/**
 * All hierarchies (Phase 5 LLD §20; HIE-12, VER-01): one tree with the version at its root, the readable hierarchies
 * below it and each hierarchy's nodes below that, loaded when opened. The slice is the context's: a version picture in
 * the URL, or the working version at today. The node panel is read-only here; "Open in …" edits in the workspace.
 */
@Component({
  selector: 'nx-all-hierarchies-page',
  imports: [HierarchyTreeComponent, NodePanelComponent, RouterLink],
  providers: [AllHierarchiesStore, NodeStore],
  template: `
    <div class="workspace">
      <section class="master" [attr.aria-label]="t.treeLabel">
        <h1 class="title">{{ t.title }}</h1>
        <nx-hierarchy-tree class="tree" [rows]="store.visibleRows()" [selectedId]="store.selectedId()" [label]="t.treeLabel"
                           [rowHeight]="rowHeight()" idPrefix="nx-all-tree"
                           (expand)="store.expand($event)" (collapse)="store.collapse($event)" (select)="store.select($event)"
                           (loadMore)="store.loadMore($event)" (expandSiblings)="expandSiblings($event)" />
      </section>
      <section class="detail" data-testid="browse-detail">
        @if (store.selection(); as sel) {
          <div class="open-in">
            <p class="nx-muted">{{ t.readOnlyNote }}</p>
            <a [routerLink]="['/hierarchies', sel.code]" [queryParams]="{ node: sel.nodeId }" queryParamsHandling="merge"
               data-testid="open-in-hierarchy">{{ t.openIn(hierarchyName(sel.code)) }}</a>
          </div>
          <nx-node-panel [detail]="nodeStore.detail()" [path]="nodeStore.path()" [sourceNames]="nodeStore.sourceNames()"
                         [loading]="nodeStore.loading()" [error]="nodeStore.error()" [readOnly]="true" [canPropose]="false"
                         [isTop]="store.isTop(sel.code, sel.nodeId)" [hierarchyCode]="sel.code" [slice]="context.slice()"
                         (retry)="nodeStore.load(sel.nodeId, sel.code, context.slice())" />
        } @else {
          <p class="nx-muted" data-testid="browse-pick">{{ t.pickNode }}</p>
        }
      </section>
    </div>
  `,
  styleUrl: './hierarchy-workspace.page.css',
  styles: `
    .open-in { display: flex; flex-wrap: wrap; align-items: baseline; justify-content: space-between;
               gap: var(--nx-space-3); margin-block-end: var(--nx-space-4); }
    .open-in p { margin: 0; }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class AllHierarchiesPage {
  protected readonly store = inject(AllHierarchiesStore);
  protected readonly nodeStore = inject(NodeStore);
  protected readonly context = inject(ContextStore);
  private readonly prefs = inject(PreferencesStore);
  private readonly announcer = inject(Announcer);

  protected readonly t = STRINGS.browse;
  protected readonly rowHeight = computed(() => ROW_HEIGHT_PX[this.prefs.density()]);

  /** The root: the version picture in the URL, else the working version, with its status and business date. */
  private readonly rootLabel = computed(() => {
    const picture = this.context.versionParam();
    const name = picture ?? this.context.workingVersion() ?? this.t.noVersion;
    const status = picture ? this.context.versionStatus() : this.context.workingVersion() ? 'working' : null;
    const words = status ? STRINGS.versions.statusWords[status] ?? status : null;
    return this.t.rootLabel(name, words, formatBusinessDate(this.context.asOf()));
  });

  constructor() {
    effect(() => this.store.rootLabel.set(this.rootLabel()));
    // the slice is the URL's (a version picture or today): a new slice reloads the list and forgets the opened trees
    effect(() => {
      const slice = this.context.slice();
      untracked(() => void this.store.load(slice).then(() =>
        this.announcer.polite(STRINGS.hierarchy.loaded(this.t.title))));
    });
    // the panel follows the selection, in the selected node's own hierarchy
    effect(() => {
      const sel = this.store.selection();
      const slice = this.context.slice();
      untracked(() => (sel ? void this.nodeStore.load(sel.nodeId, sel.code, slice) : this.nodeStore.clear()));
    });
  }

  protected hierarchyName(code: string): string {
    return this.store.hierarchies().find((h) => h.code === code)?.name ?? code;
  }

  protected expandSiblings(parentId: string | null): void {
    // `*` expands the focused row's siblings: for a hierarchy row that is every hierarchy, for the root nothing
    for (const id of parentId === null ? [] : this.store.siblingsOf(parentId)) {
      void this.store.expand(id);
    }
  }
}
