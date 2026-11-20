import { TestBed } from '@angular/core/testing';
import { Router, provideRouter } from '@angular/router';
import { NexusApi } from '../../api/nexus-api';
import { ContextStore } from '../context.store';
import { PreferencesStore } from '../preferences.store';
import { HeaderSearchComponent } from './header-search.component';

/** Phase 5 LLD §21.1: the header search (synthetic data). */
describe('HeaderSearchComponent', () => {
  async function render() {
    const api = {
      hierarchies: async () => ({ items: [{ code: 'SYN_H', name: 'Synthetic hierarchy' }] }),
      search: async () => ({ items: [{ nodeId: 'n1', name: 'Synthetic leaf' }] }),
    };
    TestBed.configureTestingModule({
      providers: [provideRouter([{ path: '**', children: [] }]), { provide: NexusApi, useValue: api },
        { provide: ContextStore, useValue: { slice: () => ({}) } },
        { provide: PreferencesStore, useValue: { lastHierarchy: () => null } }],
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
    return { el, type, router: TestBed.inject(Router) };
  }

  it('opens a request by its id', async () => {
    const { type, router } = await render();
    const go = vi.spyOn(router, 'navigate').mockResolvedValue(true);
    await type('11111111-2222-3333-4444-555555555555');
    expect(go).toHaveBeenCalledWith(['/requests', '11111111-2222-3333-4444-555555555555']);
  });

  it('says why a search is too short, and lists results naming the hierarchy searched', async () => {
    const { el, type } = await render();
    await type('a');
    expect(el.textContent).toContain('Type at least');
    await type('Synthetic');
    expect(el.querySelector('[data-testid=home-search-results]')!.textContent).toContain('Synthetic leaf');
    expect(el.textContent).toContain('Node names in Synthetic hierarchy');
  });
});
