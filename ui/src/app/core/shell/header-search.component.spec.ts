import { TestBed } from '@angular/core/testing';
import { Router, provideRouter } from '@angular/router';
import { NexusApi } from '../../api/nexus-api';
import { ContextStore } from '../context.store';
import { HeaderSearchComponent } from './header-search.component';

/** Phase 5 LLD §21.1, §17.6.1: the header search across hierarchies (synthetic data). */
describe('HeaderSearchComponent', () => {
  async function render(results: object) {
    const api = { searchAll: vi.fn(async () => results) };
    TestBed.configureTestingModule({
      providers: [provideRouter([{ path: '**', children: [] }]), { provide: NexusApi, useValue: api },
        { provide: ContextStore, useValue: { slice: () => ({}), workspaceParams: () => ({}) } }],
    });
    const fixture = TestBed.createComponent(HeaderSearchComponent);
    await fixture.whenStable();
    const el = fixture.nativeElement as HTMLElement;
    const type = async (text: string) => {
      const input = el.querySelector('input')!;
      input.value = text;
      input.dispatchEvent(new Event('input'));
      el.querySelector('form')!.dispatchEvent(new Event('submit'));
      await new Promise((r) => setTimeout(r));
      await fixture.whenStable();
    };
    return { el, type, api, router: TestBed.inject(Router) };
  }

  it('opens a request by its id without searching', async () => {
    const { type, router, api } = await render({});
    const go = vi.spyOn(router, 'navigate').mockResolvedValue(true);
    await type('11111111-2222-3333-4444-555555555555');
    expect(go).toHaveBeenCalledWith(['/requests', '11111111-2222-3333-4444-555555555555']);
    expect(api.searchAll).not.toHaveBeenCalled();
  });

  it('says why a search is too short, and lists hierarchies, nodes and requests with "See all results"', async () => {
    const { el, type } = await render({
      q: 'syn',
      hierarchies: [{ code: 'SYN_H', name: 'Synthetic hierarchy' }],
      nodes: { items: [{ nodeId: 'n1', name: 'Synthetic leaf', hierarchyCode: 'SYN_H' }] },
      requests: { items: [{ id: 'r1', title: 'Synthetic request', status: 'submitted' }] },
    });
    await type('a');
    expect(el.textContent).toContain('Type at least');
    await type('syn');
    const text = el.textContent!.replace(/\s+/g, ' ');
    expect(text).toContain('Synthetic hierarchy (SYN_H)');
    expect(el.querySelector('[data-testid=home-search-results]')!.textContent).toContain('Synthetic leaf');
    expect(text).toContain('in SYN_H');
    expect(text).toContain('Synthetic request');
    expect(el.querySelector('[data-testid=search-see-all]')).not.toBeNull();
  });

  it('says so when nothing matches', async () => {
    const { el, type } = await render({ q: 'zz', hierarchies: [], nodes: { items: [] }, requests: { items: [] } });
    await type('zz');
    expect(el.textContent).toContain('No matches.');
  });
});
