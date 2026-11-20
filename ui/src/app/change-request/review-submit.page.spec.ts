import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { NexusApi } from '../api/nexus-api';
import { ContextStore } from '../core/context.store';
import { ReviewSubmitPage } from './review-submit.page';
import { TrayStore } from './tray.store';

/** Review and submit: the requester removes changes from their draft, or discards it (owner, 2026-11-20). Synthetic data. */
describe('ReviewSubmitPage', () => {
  function setup(requester = 'me') {
    const removed: string[][] = [];
    const withdrawn: string[] = [];
    let items = [
      { id: 'i1', seq: 1, action: 'add_node', nodeId: 'n1', payload: { name: 'SYNTH', isLeaf: true }, before: {} },
      { id: 'i2', seq: 2, action: 'set_property', nodeId: 'n1', propertyCode: 'SYN_P', payload: { value: 'X' }, before: { present: false } },
      { id: 'i3', seq: 3, action: 'add_node', nodeId: 'n2', payload: { name: 'OTHER', isLeaf: true }, before: {} },
    ];
    const api = {
      request: async () => ({ body: { id: 'cr1', status: 'draft', requesterId: requester, title: 'Synthetic draft' }, etag: '"4"' }),
      items: async () => ({ items }),
      validate: async () => ({ errors: [], warnings: [] }),
    };
    const tray = {
      removeItems: async (_id: string, _etag: string, ids: string[]) => {
        removed.push(ids);
        items = items.filter((i) => !ids.includes(i.id));
        return '"5"';
      },
      withdraw: async (id: string) => {
        withdrawn.push(id);
        return { body: {}, etag: '"6"' };
      },
      reset: () => undefined,
    };
    TestBed.configureTestingModule({
      providers: [provideRouter([{ path: '**', children: [] }]), { provide: NexusApi, useValue: api }, { provide: TrayStore, useValue: tray }],
    });
    TestBed.inject(ContextStore).me.set({ actor: { userId: 'me' } });
    const fixture = TestBed.createComponent(ReviewSubmitPage);
    fixture.componentRef.setInput('id', 'cr1');
    return { fixture, removed, withdrawn, el: fixture.nativeElement as HTMLElement,
      c: fixture.componentInstance as unknown as Record<string, any> };
  }

  it('removes an added node together with the later changes to that node', async () => {
    const { fixture, removed, el } = setup();
    await fixture.whenStable();
    await fixture.whenStable();
    expect(el.querySelectorAll('[data-testid=item-remove]')).toHaveLength(3);
    el.querySelector<HTMLButtonElement>('[data-testid=item-remove]')!.click();
    await fixture.whenStable();
    await fixture.whenStable();
    expect(removed).toEqual([['i2', 'i1']]);   // the property first, then the node it belongs to
    expect(el.querySelectorAll('[data-testid=item-remove]')).toHaveLength(1);
  });

  it('discards the draft only after a confirmation', async () => {
    const { fixture, withdrawn, el } = setup();
    await fixture.whenStable();
    await fixture.whenStable();
    el.querySelector<HTMLButtonElement>('[data-testid=draft-discard] button')!.click();
    await fixture.whenStable();
    expect(withdrawn).toEqual([]);
    expect(el.textContent).toContain('Discard this draft and all its changes?');
    const confirm = el.querySelector<HTMLElement>('[data-testid=draft-discard-confirm]')!;
    (confirm.querySelector('button') ?? confirm).click();
    await fixture.whenStable();
    expect(withdrawn).toEqual(['cr1']);
  });

  it("offers neither on someone else's draft", async () => {
    const { fixture, el } = setup('someone-else');
    await fixture.whenStable();
    await fixture.whenStable();
    expect(el.querySelectorAll('[data-testid=item-remove]')).toHaveLength(0);
    expect(el.querySelector('[data-testid=draft-discard]')).toBeNull();
  });
});
