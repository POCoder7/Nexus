import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { NexusApi } from '../api/nexus-api';
import { ContextStore } from '../core/context.store';
import { DataLoadPage } from './data-load.page';

/** The page prepares the load when the panel's Prepare is pressed, and shows the prepared run. */
describe('DataLoadPage', () => {
  it('calls prepare and shows the plan', async () => {
    const calls: string[] = [];
    const api = {
      loadFindings: async () => [],
      loadRun: async () => { throw { status: 404 }; },
      prepareLoadRun: async (id: string) => {
        calls.push(id);
        return { id, status: 'prepared', preparedBy: 'u_admin', manifestSha256: 'a'.repeat(64), requests: [],
                 plan: { targetVersion: 'V', steps: [], counts: {}, rules: { guardsRelabelled: 0, withExpression: 0, storedInactive: [] }, skipped: [] } };
      },
    };
    TestBed.configureTestingModule({
      providers: [provideRouter([]), { provide: NexusApi, useValue: api },
        { provide: ContextStore, useValue: { me: () => ({ actor: { login: 'u_admin' } }) } }],
    });
    const fixture = TestBed.createComponent(DataLoadPage);
    fixture.componentRef.setInput('id', 'load-1');
    fixture.detectChanges();
    await fixture.whenStable();
    fixture.detectChanges();
    (fixture.nativeElement.querySelector('[data-testid=load-prepare] button') as HTMLButtonElement).click();
    await fixture.whenStable();
    fixture.detectChanges();
    expect(calls).toEqual(['load-1']);
    expect(fixture.nativeElement.querySelector('[data-testid=load-status]')?.textContent).toContain('Waiting for approval');
  });
});
