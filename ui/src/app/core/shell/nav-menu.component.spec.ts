import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { ContextStore } from '../context.store';
import { NavMenuComponent } from './nav-menu.component';

/** Phase 5 LLD §21: navigation menus are disclosure buttons (keyboard and pointer). */
describe('NavMenuComponent', () => {
  async function render() {
    TestBed.configureTestingModule({ providers: [provideRouter([{ path: '**', children: [] }])] });   // any link navigates
    const fixture = TestBed.createComponent(NavMenuComponent);
    fixture.componentRef.setInput('label', 'Admin');
    fixture.componentRef.setInput('items', [{ label: 'Versions', link: '/versions' }, { label: 'Audit', link: '/audit', count: 3 }]);
    await fixture.whenStable();
    const el = fixture.nativeElement as HTMLElement;
    return { fixture, el, button: el.querySelector('button')! };
  }

  it('opens and closes the list with the button, and says so with aria-expanded', async () => {
    const { fixture, el, button } = await render();
    expect(button.getAttribute('aria-expanded')).toBe('false');
    expect(el.querySelector('ul')).toBeNull();
    button.click();
    await fixture.whenStable();
    expect(button.getAttribute('aria-expanded')).toBe('true');
    expect([...el.querySelectorAll('a')].map((a) => a.textContent?.trim())).toEqual(['Versions', 'Audit 3']);
    expect(el.querySelector('ul')!.id).toBe(button.getAttribute('aria-controls'));
  });

  it('closes on Escape and returns focus to the button, and closes when a link is chosen', async () => {
    const { fixture, el, button } = await render();
    button.click();
    await fixture.whenStable();
    el.querySelector('a')!.focus();
    el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    await fixture.whenStable();
    expect(el.querySelector('ul')).toBeNull();
    expect(document.activeElement).toBe(button);

    button.click();
    await fixture.whenStable();
    (el.querySelector('a') as HTMLAnchorElement).click();
    await fixture.whenStable();
    expect(el.querySelector('ul')).toBeNull();
  });

  it("keeps the sandbox in a link that asks for the working context", async () => {
    TestBed.configureTestingModule({ providers: [provideRouter([{ path: "**", children: [] }])] });
    TestBed.inject(ContextStore).syncFromUrl(null, null, null, "sb-1");
    const fixture = TestBed.createComponent(NavMenuComponent);
    fixture.componentRef.setInput("label", "Hierarchies");
    fixture.componentRef.setInput("items", [{ label: "Open hierarchy", link: "/hierarchies", keepContext: true },
      { label: "Browse", link: "/browse" }]);
    await fixture.whenStable();
    const el = fixture.nativeElement as HTMLElement;
    el.querySelector("button")!.click();
    await fixture.whenStable();
    const links = [...el.querySelectorAll("a")].map((a) => a.getAttribute("href"));
    expect(links).toEqual(["/hierarchies?sandbox=sb-1", "/browse"]);
  });
});
