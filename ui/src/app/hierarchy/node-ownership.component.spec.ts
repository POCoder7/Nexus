import { TestBed } from '@angular/core/testing';
import { NexusApi } from '../api/nexus-api';
import { NodeOwnershipComponent } from './node-ownership.component';

/** NEW-02 view: tables are the accessible equivalent of the diagram; stored percentages to two decimals, no calculation. */
describe('NodeOwnershipComponent', () => {
  it('lists owners and holdings with two-decimal percentages and draws the same rows', async () => {
    TestBed.configureTestingModule({
      providers: [{ provide: NexusApi, useValue: {
        owners: async () => ({ items: [{ edgeId: 'e1', otherNodeId: 'o1', otherName: 'Synthetic owner', relation: 'shareholding',
          economicPct: 60, votingPct: 55.5, direct: true, source: 'manual' }] }),
        holdings: async () => ({ items: [{ edgeId: 'e2', otherNodeId: 'h1', otherName: 'Synthetic holding', relation: 'shareholding',
          economicPct: 12.3456, direct: false, source: 'company_registry' }] }),
      } }],
    });
    const fixture = TestBed.createComponent(NodeOwnershipComponent);
    fixture.componentRef.setInput('nodeId', 'n1');
    fixture.componentRef.setInput('nodeName', 'Synthetic node');
    await fixture.whenStable();
    await new Promise((r) => setTimeout(r));
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid=ownership-owners]')!.textContent).toContain('60.00');
    expect(el.querySelector('[data-testid=ownership-owners]')!.textContent).toContain('55.50');
    expect(el.querySelector('[data-testid=ownership-holdings]')!.textContent).toContain('12.35');
    expect(el.querySelector('[data-testid=ownership-holdings]')!.textContent).toContain('reported indirect');
    const svg = el.querySelector('[data-testid=ownership-diagram]')!;
    expect(svg.getAttribute('role')).toBe('img');
    expect(svg.querySelectorAll('rect')).toHaveLength(3);   // owner, node, holding
  });
});
