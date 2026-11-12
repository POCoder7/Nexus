import { ChangeDetectionStrategy, Component, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { STRINGS } from '../strings';
import { DEV_LOGINS, DevIdentity } from './dev-identity.providers';

/** Development user picker (local and test builds only, LLD C-7): chooses the synthetic login sent as X-Nexus-User. */
@Component({
  selector: 'nx-dev-user-picker',
  imports: [FormsModule],
  templateUrl: './dev-user-picker.component.html',
  styleUrl: './dev-user-picker.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class DevUserPickerComponent {
  protected readonly t = STRINGS.user;
  protected readonly logins = DEV_LOGINS;
  private readonly identity = inject(DevIdentity);
  protected readonly value = signal(this.identity.login() ?? '');

  protected apply(): void {
    const login = this.value().trim();
    if (login && login !== this.identity.login()) {
      this.identity.set(login);
      location.assign('/');   // a new user starts from their own start page with fresh state
    }
  }
}
