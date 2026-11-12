import { TestBed } from '@angular/core/testing';
import { ItemListComponent } from './item-list.component';

/** Before/after view (UI_STANDARD §5 diff view): both modes, change kind in words, findings on their item. */
describe('ItemListComponent', () => {
  const items = [
    { id: 'i1', seq: 1, action: 'add_node', nodeId: 'n1', payload: { name: 'Synthetic leaf', isLeaf: true }, before: { parentIds: [] } },
    { id: 'i2', seq: 2, action: 'set_property', nodeId: 'n1', propertyCode: 'S.Seg', payload: { value: 'Retail' }, before: { present: false, value: null } },
    { id: 'i3', seq: 3, action: 'move_node', nodeId: 'n2', targetParentId: 'abcdef12-0000', payload: {}, before: { parentId: 'p', parentIds: ['p'] } },
    { id: 'i4', seq: 4, action: 'clear_property', nodeId: 'n2', propertyCode: 'S.Seg', payload: {}, before: { present: true, value: 'Old' } },
  ];

  async function render() {
    const fixture = TestBed.createComponent(ItemListComponent);
    fixture.componentRef.setInput('items', items);
    fixture.componentRef.setInput('findings', [{ nodeId: 'n2', ruleCode: 'R', message: 'Synthetic finding' }]);
    await fixture.whenStable();
    return fixture;
  }

  it('shows each change kind in words, side by side', async () => {
    const el: HTMLElement = (await render()).nativeElement;
    const kinds = [...el.querySelectorAll('tbody tr')].map((r) => r.getAttribute('data-change'));
    expect(kinds).toEqual(['added', 'modified', 'moved', 'removed']);
    expect(el.querySelector('tbody tr:nth-child(1)')!.textContent).toContain('Added');
    expect(el.querySelector('tbody tr:nth-child(2)')!.textContent).toContain('Not set');
    expect(el.querySelector('tbody tr:nth-child(2)')!.textContent).toContain('Retail');
    expect(el.querySelector('tbody tr:nth-child(4)')!.textContent).toContain('Old');
    expect(el.querySelector('tbody tr:nth-child(3) .finding')!.textContent).toContain('Synthetic finding');
  });

  it('switches to inline with removed and added lines labelled for screen readers', async () => {
    const fixture = await render();
    const el: HTMLElement = fixture.nativeElement;
    [...el.querySelectorAll('button')].find((b) => b.textContent?.trim() === 'Inline')!.click();
    await fixture.whenStable();
    expect(el.querySelectorAll('li')).toHaveLength(4);
    expect(el.querySelector('li:nth-child(2) .line--removed')!.textContent).toContain('Before: Not set');
    expect(el.querySelector('li:nth-child(2) .line--added')!.textContent).toContain('After: Retail');
    expect(el.querySelector('[aria-pressed=true]')!.textContent?.trim()).toBe('Inline');
  });
});
