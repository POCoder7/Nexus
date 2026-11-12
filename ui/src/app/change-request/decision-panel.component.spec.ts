import { TestBed } from '@angular/core/testing';
import { DecisionIntent, DecisionPanelComponent } from './decision-panel.component';

/** SLICE-01 S1-R5: the reason in words when the user cannot act; reject needs a comment (LLD §12.2). */
describe('DecisionPanelComponent', () => {
  async function render(stage: object | null, reason: string | null = null) {
    const fixture = TestBed.createComponent(DecisionPanelComponent);
    fixture.componentRef.setInput('stage', stage);
    fixture.componentRef.setInput('reason', reason);
    await fixture.whenStable();
    const sent: DecisionIntent[] = [];
    fixture.componentInstance.decide.subscribe((d) => sent.push(d));
    return { fixture, el: fixture.nativeElement as HTMLElement, sent };
  }

  it("shows the server's reason instead of the actions when the user cannot act", async () => {
    const { el } = await render({ instanceStageId: 's1', type: 'commit', youCanAct: false },
      'You requested or submitted this change, so you cannot approve or commit it.');
    expect(el.querySelector('[data-testid=decision-reason]')!.textContent).toContain('You requested or submitted this change');
    expect(el.querySelectorAll('button')).toHaveLength(0);
  });

  it('labels the commit stage action "Commit" and sends approve', async () => {
    const { el, sent } = await render({ instanceStageId: 's1', type: 'commit', youCanAct: true });
    const commit = [...el.querySelectorAll('button')].find((b) => b.textContent?.trim() === 'Commit')!;
    commit.click();
    expect(sent).toEqual([{ stageId: 's1', decision: 'approve', comment: undefined }]);
  });

  it('refuses to reject without a comment', async () => {
    const { fixture, el, sent } = await render({ instanceStageId: 's1', type: 'approve', youCanAct: true });
    [...el.querySelectorAll('button')].find((b) => b.textContent?.trim() === 'Reject')!.click();
    await fixture.whenStable();
    expect(sent).toHaveLength(0);
    expect(el.textContent).toContain('A comment is required to reject.');
  });
});
