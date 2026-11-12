import { ComponentFixture, TestBed } from '@angular/core/testing';
import { FlatTreeRow } from './tree.model';
import { HierarchyTreeComponent } from './hierarchy-tree.component';

/** Keyboard behaviour of the WAI-ARIA tree (LLD §7.1, UI_STANDARD §8). Synthetic rows. */
describe('HierarchyTreeComponent', () => {
  const node = (id: string, name: string, depth: number, parentId: string | null, hasChildren = false, expanded = false): FlatTreeRow =>
    ({ kind: 'node', key: id, id, parentId, name, depth, hasChildren, expanded, shared: false, active: true, pinned: false });
  const rows: FlatTreeRow[] = [
    node('top', 'Top', 0, null, true, true),
    node('a', 'Alpha', 1, 'top', true, false),
    node('b', 'Beta', 1, 'top'),
    node('c', 'Bravo', 1, 'top'),
    { kind: 'more', key: 'top#more', parentId: 'top', depth: 1 },
  ];
  let fixture: ComponentFixture<HierarchyTreeComponent>;
  let tree: HTMLElement;
  const events: string[] = [];

  beforeEach(async () => {
    events.length = 0;
    fixture = TestBed.createComponent(HierarchyTreeComponent);
    fixture.componentRef.setInput('rows', rows);
    fixture.componentRef.setInput('label', 'Synthetic tree');
    const c = fixture.componentInstance;
    c.expand.subscribe((id) => events.push(`expand:${id}`));
    c.collapse.subscribe((id) => events.push(`collapse:${id}`));
    c.select.subscribe((id) => events.push(`select:${id}`));
    c.loadMore.subscribe((id) => events.push(`more:${id}`));
    c.expandSiblings.subscribe((id) => events.push(`siblings:${id}`));
    await fixture.whenStable();
    tree = fixture.nativeElement.querySelector('[role=tree]');
  });

  const press = async (key: string) => {
    tree.dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true }));
    fixture.detectChanges();
    await fixture.whenStable();
  };
  const active = () => tree.getAttribute('aria-activedescendant');

  it('is a labelled tree that keeps focus on itself', () => {
    expect(tree.getAttribute('aria-label')).toBe('Synthetic tree');
    expect(tree.getAttribute('tabindex')).toBe('0');
    expect(active()).toBe('nx-tree-top');
  });

  it('moves with arrows, Home and End', async () => {
    await press('ArrowDown');
    expect(active()).toBe('nx-tree-a');
    await press('End');
    expect(active()).toBe('nx-tree-top_more');
    await press('Home');
    expect(active()).toBe('nx-tree-top');
  });

  it('expands with → on a collapsed node and collapses with ← on an expanded one', async () => {
    await press('ArrowDown');
    await press('ArrowRight');
    await press('ArrowUp');
    await press('ArrowLeft');
    expect(events).toEqual(['expand:a', 'collapse:top']);
  });

  it('← on a child moves to its parent', async () => {
    await press('ArrowDown');
    await press('ArrowDown');
    await press('ArrowLeft');
    expect(active()).toBe('nx-tree-top');
  });

  it('Enter selects a node and loads the next page on the "show next" row', async () => {
    await press('ArrowDown');
    await press('Enter');
    await press('End');
    await press('Enter');
    expect(events).toEqual(['select:a', 'more:top']);
  });

  it('types ahead over visible rows and cycles through matches', async () => {
    await press('b');
    expect(active()).toBe('nx-tree-b');
    await new Promise((r) => setTimeout(r, 650));
    await press('b');
    expect(active()).toBe('nx-tree-c');
  });

  it('treats Space as part of a type-ahead that has started, not as select', async () => {
    await press('B');
    await press('r');
    await press(' ');
    expect(events).toEqual([]);   // nothing selected
    expect(active()).toBe('nx-tree-c');   // "Br" → Bravo
  });

  it('* expands the siblings of the focused node', async () => {
    await press('ArrowDown');
    await press('*');
    expect(events).toEqual(['siblings:top']);
  });
});
