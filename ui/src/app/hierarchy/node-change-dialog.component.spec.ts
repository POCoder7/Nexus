import { TestBed } from '@angular/core/testing';
import { NexusApi } from '../api/nexus-api';
import type { ItemCommand } from '../api/generated/models';
import { TrayStore } from '../change-request/tray.store';
import { DIALOG_DATA, DialogRef } from '../shared/ds';
import { NodeChangeData, NodeChangeDialogComponent } from './node-change-dialog.component';

/** Scope extension: each change becomes one governed item; wide-impact changes need confirmation (UI_STANDARD §6). */
describe('NodeChangeDialogComponent', () => {
  const node = { id: 'n1', name: 'Synthetic node', description: 'Old text' };

  async function render(data: Partial<NodeChangeData>) {
    const added: { command: ItemCommand; title: string }[] = [];
    const closed: unknown[] = [];
    TestBed.configureTestingModule({
      providers: [
        { provide: DIALOG_DATA, useValue: { hierarchyCode: 'SYN_H', businessToday: '2031-05-17', node, ...data } },
        { provide: DialogRef, useValue: { close: (v: unknown) => closed.push(v) } },
        { provide: NexusApi, useValue: {
          impact: async () => ({ descendants: 12, placements: 1, isTop: false, descendantsCapped: false }),
          submitForm: async () => ({ properties: [] }),
          search: async () => ({ items: [] }),
        } },
        { provide: TrayStore, useValue: {
          hasDraft: () => false, request: () => null,
          addChange: async (command: ItemCommand, title: string) => {
            added.push({ command, title });
            return {};
          },
        } },
      ],
    });
    const fixture = TestBed.createComponent(NodeChangeDialogComponent);
    await fixture.whenStable();
    const c = fixture.componentInstance as unknown as Record<string, any>;
    return { fixture, c, added, closed, el: fixture.nativeElement as HTMLElement };
  }

  it('sends only the changed fields of Edit details', async () => {
    const { c, added, closed } = await render({ mode: 'details' });
    c['description'].set('New text');
    await c['save']();
    expect(added).toEqual([{ command: { action: 'update_node', hierarchyCode: 'SYN_H', nodeId: 'n1', payload: { description: 'New text' } },
      title: 'Edit Synthetic node' }]);
    expect(closed).toEqual([true]);
  });

  it('shows the impact in numbers and refuses to remove without confirmation', async () => {
    const { fixture, c, added, el } = await render({ mode: 'remove' });
    await fixture.whenStable();
    expect(el.querySelector('[data-testid=impact]')!.textContent).toContain('12 nodes below it');
    await c['save']();
    expect(added).toHaveLength(0);
    expect(c['localError']()).toBe('Confirm to continue.');
    c['confirmed'].set(true);
    c['cascade'].set(true);
    await c['save']();
    expect(added[0].command).toEqual({ action: 'remove_node', hierarchyCode: 'SYN_H', nodeId: 'n1', payload: { cascade: true } });
  });

  it('clears a stored value instead of setting it when asked', async () => {
    const { c, added } = await render({ mode: 'property', property: { code: 'S.Seg', label: 'Segment', provenance: 'stored', value: 'Retail' as never, dataType: 'string' } });
    expect(c['value']()).toBe('Retail');
    c['clear'].set(true);
    await c['save']();
    expect(added[0].command.action).toBe('clear_property');
    expect(added[0].title).toBe('Clear Segment on Synthetic node');
  });

  it('needs a target before a move', async () => {
    const { c, added } = await render({ mode: 'move' });
    await c['save']();
    expect(added).toHaveLength(0);
    c['chooseTarget']({ nodeId: 'p2', name: 'Other parent', path: [] });
    await c['save']();
    expect(added[0].command).toEqual(expect.objectContaining({ action: 'move_node', targetParentId: 'p2' }));
    expect(added[0].title).toBe('Move Synthetic node to Other parent');
  });

  it('builds a new hierarchy item', async () => {
    const { c, added } = await render({ mode: 'hierarchy', hierarchyCode: null, node: undefined });
    c['code'].set('SYN_NEW');
    c['name'].set('Synthetic new');
    c['topName'].set('Synthetic new top');
    await c['save']();
    expect(added[0].command).toEqual({ action: 'add_hierarchy', payload: { code: 'SYN_NEW', name: 'Synthetic new', purpose: 'management',
      allowSharedNodes: false, topNode: { nodeKind: 'structural', name: 'Synthetic new top' } } });
  });
});
