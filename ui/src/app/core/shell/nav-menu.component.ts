import { ChangeDetectionStrategy, Component, ElementRef, HostListener, computed, inject, input, signal, viewChild } from '@angular/core';
import { IsActiveMatchOptions, NavigationEnd, Router, RouterLink } from '@angular/router';
import { toSignal } from '@angular/core/rxjs-interop';
import { filter, map } from 'rxjs';

export interface NavMenuItem {
  label: string;
  link: string;
  testId?: string;
  /** A number shown next to the label (e.g. requests waiting). */
  count?: number | null;
}

const MATCH: IsActiveMatchOptions = { paths: 'subset', queryParams: 'ignored', fragment: 'ignored', matrixParams: 'ignored' };

/**
 * `nx-nav-menu` (Phase 5 LLD §21): a top-navigation entry that opens a short list of links. A disclosure button
 * (WAI-ARIA disclosure pattern): `aria-expanded`, the list follows the button in the DOM, Escape closes it and returns
 * focus to the button, a click outside or choosing a link closes it. The button reads as current when one of its links is.
 */
@Component({
  selector: 'nx-nav-menu',
  imports: [RouterLink],
  template: `
    <button #button type="button" class="nav-menu__button" [class.active]="active()" [attr.aria-expanded]="open()"
            [attr.aria-controls]="id()" [attr.data-testid]="testId()" (click)="toggle()">
      {{ label() }}<span class="nav-menu__caret" aria-hidden="true">▾</span>
    </button>
    @if (open()) {
      <ul class="nav-menu__list" [id]="id()">
        @for (item of items(); track item.link) {
          <li>
            <a [routerLink]="item.link" [attr.data-testid]="item.testId ?? null" [attr.aria-current]="isActive(item.link) ? 'page' : null"
               (click)="close(false)">
              {{ item.label }}
              @if (item.count !== null && item.count !== undefined) {
                <span class="nav-menu__count">{{ item.count }}</span>
              }
            </a>
          </li>
        }
      </ul>
    }
  `,
  styles: `
    :host { position: relative; display: inline-block; }
    .nav-menu__button { display: inline-flex; align-items: center; gap: var(--nx-space-2); padding: var(--nx-space-3) var(--nx-space-4);
                        border: 0; border-bottom: calc(var(--nx-border-width) * 2) solid transparent; background: none;
                        color: var(--nx-color-text-primary); font-size: var(--nx-font-size-body); cursor: pointer; }
    .nav-menu__button:hover { background: var(--nx-color-surface-hover); }
    .nav-menu__button.active { border-bottom-color: var(--nx-color-action-primary); font-weight: var(--nx-font-weight-strong); }
    .nav-menu__caret { font-size: var(--nx-font-size-label); }
    .nav-menu__list { position: absolute; top: 100%; left: 0; z-index: var(--nx-z-dropdown); min-width: 12rem; margin: 0;
                      padding: var(--nx-space-2) 0; list-style: none; border: var(--nx-border-width) solid var(--nx-color-border-strong);
                      background: var(--nx-color-surface-raised); box-shadow: var(--nx-elevation-2); }
    .nav-menu__list a { display: flex; justify-content: space-between; gap: var(--nx-space-3); padding: var(--nx-space-3) var(--nx-space-4);
                        color: var(--nx-color-text-primary); text-decoration: none; }
    .nav-menu__list a:hover, .nav-menu__list a:focus { background: var(--nx-color-surface-hover); }
    .nav-menu__list a[aria-current=page] { font-weight: var(--nx-font-weight-strong); }
    .nav-menu__count { padding: 0 var(--nx-space-3); border: var(--nx-border-width) solid var(--nx-color-border-strong);
                       border-radius: var(--nx-radius-2); font-size: var(--nx-font-size-label); }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class NavMenuComponent {
  readonly label = input.required<string>();
  readonly items = input.required<NavMenuItem[]>();
  readonly testId = input<string | null>(null);

  private readonly router = inject(Router);
  private readonly host = inject(ElementRef<HTMLElement>);
  private readonly button = viewChild.required<ElementRef<HTMLButtonElement>>('button');
  private static next = 0;
  protected readonly id = signal(`nx-nav-menu-${NavMenuComponent.next++}`);
  protected readonly open = signal(false);
  private readonly url = toSignal(this.router.events.pipe(filter((e) => e instanceof NavigationEnd), map(() => this.router.url)),
    { initialValue: this.router.url });
  protected readonly active = computed(() => {
    this.url();
    return this.items().some((i) => this.isActive(i.link));
  });

  protected isActive(link: string): boolean {
    return this.router.isActive(link, MATCH);
  }

  protected toggle(): void {
    this.open.update((o) => !o);
  }

  /** Closes the list; with {@code focus}, focus returns to the button (Escape). */
  close(focus: boolean): void {
    if (!this.open()) return;
    this.open.set(false);
    if (focus) this.button().nativeElement.focus();
  }

  @HostListener('keydown.escape')
  protected onEscape(): void {
    this.close(true);
  }

  @HostListener('document:click', ['$event'])
  protected onDocumentClick(event: MouseEvent): void {
    if (!this.host.nativeElement.contains(event.target as Node)) this.close(false);
  }
}
