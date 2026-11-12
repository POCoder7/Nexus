import { ChangeDetectionStrategy, Component } from '@angular/core';
import { RouterLink } from '@angular/router';
import { STRINGS } from './strings';

@Component({
  selector: 'nx-not-found-page',
  imports: [RouterLink],
  template: `<section class="nx-page"><h1>{{ t.notFoundTitle }}</h1><p>{{ t.notFound }}</p><a routerLink="/home">{{ t.goHome }}</a></section>`,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class NotFoundPage {
  protected readonly t = STRINGS.common;
}
