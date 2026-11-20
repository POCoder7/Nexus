import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { LoadRunPanelComponent } from './load-run-panel.component';

/** The panel's Prepare button emits the version typed (or null); a checked load with errors offers no Prepare. */
describe('LoadRunPanelComponent', () => {
  function render(findings: { severity: string }[] = []) {
    TestBed.configureTestingModule({ imports: [LoadRunPanelComponent], providers: [provideRouter([])] });
    const fixture = TestBed.createComponent(LoadRunPanelComponent);
    fixture.componentRef.setInput('findings', findings);
    fixture.detectChanges();
    return fixture;
  }

  it('emits prepare when the button is pressed', () => {
    const fixture = render();
    const emitted: (string | null)[] = [];
    fixture.componentInstance.prepare.subscribe((v) => emitted.push(v));
    (fixture.nativeElement.querySelector('[data-testid=load-prepare] button') as HTMLButtonElement).click();
    expect(emitted).toEqual([null]);
  });

  it('offers no Prepare while the files have errors', () => {
    const fixture = render([{ severity: 'error' }]);
    expect(fixture.nativeElement.querySelector('[data-testid=load-prepare]')).toBeNull();
  });
});
