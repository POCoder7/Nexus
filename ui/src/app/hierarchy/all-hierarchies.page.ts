import { ChangeDetectionStrategy, Component, computed, effect, inject, untracked } from '@angular/core';
import { RouterLink } from '@angular/router';
import type { PropertyValue } from '../api/generated/models';
import { TrayStore } from '../change-request/tray.store';
import { Announcer } from '../core/announcer';
import { ROW_HEIGHT_PX } from '../core/config';
import { ContextStore } from '../core/context.store';
import { PreferencesStore } from '../core/preferences.store';
import { STRINGS } from '../core/strings';
import { DsDialog } from '../shared/ds';
import { formatBusinessDate } from '../shared/format/nx-date.pipe';
import { AddLeafData, AddLeafDialogComponent, AddLeafResult } from './add-leaf-dialog.component';
import { AllHierarchiesStore, parseRowId } from './all-hierarchies.store';
import { HierarchyTreeComponent } from './hierarchy-tree.component';
import { ChangeMode, NodeChangeData, NodeChangeDialogComponent } from './node-change-dialog.component';
import { NodePanelComponent } from './node-panel.component';
import { NodeStore } from './node.store';

/**
 * All hierarchies (Phase 5 LLD §20; HIE-12, VER-01): one tree with the version at its root, the readable hierarchies
 * below it and each hierarchy's nodes below that, loaded when opened. The slice is the context's: a version picture in
 * the URL, or the working version at today. Editing works as in the workspace, in the selected node's own hierarchy:
 * the actions the user's rights there allow, the same dialogs into the same tray, read-only for a historical view;
 * drag and drop moves a node only within its hierarchy.
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
                           [dragEnabled]="!context.isHistorical()" (dropMove)="onDropMove($event)"
                           (expand)="store.expand($event)" (collapse)="store.collapse($event)" (select)="store.select($event)"
                           (loadMore)="store.loadMore($event)" (expandSiblings)="expandSiblings($event)" />
      </section>
      <section class="detail" data-testid="browse-detail">
        @if (store.selection(); as sel) {
          <div class="open-in">
            <a [routerLink]="['/hierarchies', sel.code]" [queryParams]="{ node: sel.nodeId }" queryParamsHandling="merge"
               data-testid="open-in-hierarchy">{{ t.openIn(hierarchyName(sel.code)) }}</a>
          </div>
          <nx-node-panel [detail]="nodeStore.detail()" [path]="nodeStore.path()" [sourceNames]="nodeStore.sourceNames()"
                         [loading]="nodeStore.loading()" [error]="nodeStore.error()" [readOnly]="context.isHistorical()"
                         [canPropose]="canPropose()" [isTop]="store.isTop(sel.code, sel.nodeId)" [hierarchyCode]="sel.code"
                         [slice]="context.slice()" [canEditCategory]="canEditCategory"
                         [changed]="nodeStore.nodeChanged()" [changedCodes]="nodeStore.changedCodes()"
                         (addChild)="addChild()" (requestChange)="openChange($event.mode, $event.property)"
                         (openNode)="openNode($event)"
                         (retry)="nodeStore.load(sel.nodeId, sel.code, context.slice(), context.sandboxParam())" />
        } @else {
          <p class="nx-muted" data-testid="browse-pick">{{ t.pickNode }}</p>
        }
      </section>
    </div>
  `,
  styleUrl: './hierarchy-workspace.page.css',
  styles: `
    .open-in { display: flex; justify-content: flex-end; margin-block-end: var(--nx-space-4); }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class AllHierarchiesPage {
  protected readonly store = inject(AllHierarchiesStore);
  protected readonly nodeStore = inject(NodeStore);
  protected readonly context = inject(ContextStore);
  private readonly prefs = inject(PreferencesStore);
  private readonly announcer = inject(Announcer);
  private readonly dialog = inject(DsDialog);
  private readonly tray = inject(TrayStore);

  protected readonly t = STRINGS.browse;
  protected readonly rowHeight = computed(() => ROW_HEIGHT_PX[this.prefs.density()]);
  /** PROPOSE in the selected node's hierarchy: the panel then offers the same actions as the workspace. */
  protected readonly canPropose = computed(() => {
    const sel = this.store.selection();
    return !!sel && this.context.can('PROPOSE', sel.code);
  });

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
    // a new slice or sandbox reloads the list and forgets the opened trees
    effect(() => {
      const slice = this.context.slice();
      const sandbox = this.context.sandboxParam();
      untracked(() => void this.store.load(slice, sandbox).then(() =>
        this.announcer.polite(STRINGS.hierarchy.loaded(this.t.title))));
    });
    // in a sandbox each change refreshes its overlay on the server, so the opened trees are read again (NEW-08)
    let firstRevision = true;
    effect(() => {
      this.tray.revision();
      if (firstRevision) {
        firstRevision = false;
        return;
      }
      untracked(() => void this.store.refresh());
    });
    // the panel follows the selection, in the selected node's own hierarchy
    effect(() => {
      const sel = this.store.selection();
      const slice = this.context.slice();
      const sandbox = this.context.sandboxParam();
      this.tray.revision();
      untracked(() => (sel ? void this.nodeStore.load(sel.nodeId, sel.code, slice, sandbox) : this.nodeStore.clear()));
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

  /** A link in the panel (a source node, a parent in the path) opens that node in the same hierarchy. */
  protected openNode(nodeId: string): void {
    const sel = this.store.selection();
    if (sel) {
      void this.store.reveal(sel.code, nodeId);
    }
  }

  /** ADR-036 hint for the property grid: may the user edit properties of this category in the node's hierarchy? */
  protected readonly canEditCategory = (category: string | null) => {
    const sel = this.store.selection();
    return !!sel && this.context.canEditCategory(sel.code, category);
  };

  protected openChange(mode: ChangeMode, property?: PropertyValue): void {
    const sel = this.store.selection();
    const node = this.nodeStore.detail();
    const today = this.context.businessToday();
    if (!sel || !node?.nodeId || !today) {
      return;
    }
    this.dialog.open<boolean, NodeChangeData, NodeChangeDialogComponent>(NodeChangeDialogComponent, {
      mode, hierarchyCode: sel.code, businessToday: today, property,
      node: { id: node.nodeId, name: node.name ?? '', description: node.description ?? null },
    }, 'nx-change-title');
  }

  protected addChild(): void {
    const sel = this.store.selection();
    const parent = this.nodeStore.detail();
    const today = this.context.businessToday();
    if (!sel || !parent?.nodeId || !today) {
      return;
    }
    this.dialog.open<AddLeafResult, AddLeafData, AddLeafDialogComponent>(AddLeafDialogComponent,
      { hierarchyCode: sel.code, parentId: parent.nodeId, parentName: parent.name ?? '', businessToday: today }, 'nx-add-leaf-title');
  }

  /**
   * Drag and drop (mouse): "Move to…" with the dropped-on node as the target, for confirmation, as in the workspace. Only
   * within one hierarchy, and never a hierarchy's top node; anything else is refused in words.
   */
  protected onDropMove(e: { nodeId: string; nodeName: string; targetId: string; targetName: string }): void {
    const node = parseRowId(e.nodeId);
    const target = parseRowId(e.targetId);
    const today = this.context.businessToday();
    if (!node || !target || !today) {
      return;
    }
    if (node.code !== target.code || this.store.isTop(node.code, node.nodeId)) {
      this.announcer.assertive(this.t.dropRefused);
      return;
    }
    this.dialog.open<boolean, NodeChangeData, NodeChangeDialogComponent>(NodeChangeDialogComponent, {
      mode: 'move', hierarchyCode: node.code, businessToday: today,
      node: { id: node.nodeId, name: e.nodeName, description: null },
      presetTarget: { nodeId: target.nodeId, name: e.targetName },
    }, 'nx-change-title');
  }
}
