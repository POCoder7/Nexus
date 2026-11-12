import { TestBed } from '@angular/core/testing';
import { WorkflowTimelineComponent } from './workflow-timeline.component';

/** SLICE-01 S1-R6: stages with status in words and shadow evaluations that say they had no effect (LLD §3.3). */
describe('WorkflowTimelineComponent', () => {
  it('shows each stage status in words and the shadow outcome', async () => {
    const fixture = TestBed.createComponent(WorkflowTimelineComponent);
    fixture.componentRef.setInput('stages', [
      { seq: 1, label: 'Submit', status: 'completed', type: 'submit' },
      { seq: 2, label: 'Approve', status: 'active', type: 'approve' },
      { seq: 3, label: 'Commit', status: 'pending', type: 'commit' },
    ]);
    fixture.componentRef.setInput('evaluations', [{ policyCode: 'SYN_SHADOW', outcome: 'shadow_would_commit', mode: 'shadow' }]);
    await fixture.whenStable();
    const el: HTMLElement = fixture.nativeElement;
    const text = el.textContent!.replace(/\s+/g, ' ');
    expect(text).toContain('1. Submit');
    expect(text).toContain('Completed');
    expect(text).toContain('In progress');
    expect(text).toContain('Not started');
    expect(el.querySelector('[data-testid=policy-evaluations]')!.textContent).toContain('SYN_SHADOW: would commit (shadow mode, no effect)');
    expect(el.querySelector('[aria-live=polite]')).not.toBeNull();
  });
});
