import { TestBed } from '@angular/core/testing';
import { NodePanelComponent } from './node-panel.component';

/** LLD §6.3 and §12.2: write controls are absent in historical views; unavailable actions say why. */
describe('NodePanelComponent', () => {
  async function render(inputs: Record<string, unknown>) {
    const fixture = TestBed.createComponent(NodePanelComponent);
    for (const [k, v] of Object.entries(inputs)) {
      fixture.componentRef.setInput(k, v);
    }
    await fixture.whenStable();
    return fixture.nativeElement as HTMLElement;
  }
  const limb = { nodeId: 'n1', name: 'Synthetic limb', kind: 'structural', allowsChildren: true, properties: [] };
  const leaf = { ...limb, name: 'Synthetic leaf', allowsChildren: false };
  const addChild = (el: HTMLElement) => [...el.querySelectorAll('button')].find((b) => b.textContent?.trim() === 'Add child');

  it('offers "Add child" on a limb when the user may propose', async () => {
    expect(addChild(await render({ detail: limb, canPropose: true }))).toBeDefined();
  });

  it('removes "Add child" from the DOM in a historical view', async () => {
    const el = await render({ detail: limb, canPropose: true, readOnly: true });
    expect(addChild(el)).toBeUndefined();
    expect(el.querySelector('[data-testid=add-child-reason]')).toBeNull();
  });

  it('says why a leaf cannot have children', async () => {
    const el = await render({ detail: leaf, canPropose: true });
    expect(el.querySelector('[data-testid=add-child-reason]')!.textContent).toContain("Leaf nodes can't have children.");
  });

  it('says why when the user cannot propose here', async () => {
    const el = await render({ detail: limb, canPropose: false });
    expect(el.querySelector('[data-testid=add-child-reason]')!.textContent).toContain("You can't propose changes in this hierarchy.");
  });
});
