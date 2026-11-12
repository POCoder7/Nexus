import { ChangeDetectionStrategy, Component } from '@angular/core';
import { AppShellComponent } from './core/shell/app-shell.component';

@Component({
  selector: 'nx-root',
  imports: [AppShellComponent],
  template: '<nx-app-shell />',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class App {}
