import { ChangeDetectionStrategy, Component, inject, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { FormsModule } from '@angular/forms';
import { STRINGS } from '../strings';
import { DEV_LOGINS, DevIdentity } from './dev-identity.providers';

/** A user the development picker offers. */
interface DevUser {
  login: string;
  displayName: string;
}

/**
 * Development user picker (local and test builds only, LLD C-7): chooses the synthetic login sent as X-Nexus-User. It
 * offers the active users of the running database (GET /api/v1/dev/users, local and test profiles only), so the list
 * follows whatever the database holds: the demo's data set or the end-to-end seed. Any other login can still be typed.
 */
@Component({
  selector: 'nx-dev-user-picker',
  imports: [FormsModule],
  templateUrl: './dev-user-picker.component.html',
  styleUrl: './dev-user-picker.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class DevUserPickerComponent {
  protected readonly t = STRINGS.user;
  protected readonly users = signal<DevUser[]>(DEV_LOGINS.map((login) => ({ login, displayName: login })));
  private readonly identity = inject(DevIdentity);
  protected readonly value = signal(this.identity.login() ?? '');

  constructor() {
    inject(HttpClient).get<DevUser[]>('/api/v1/dev/users').subscribe({
      next: (users) => this.users.set(users),
      error: () => undefined,   // the list is a convenience: typing a login still works
    });
  }

  protected apply(): void {
    const login = this.value().trim();
    if (login && login !== this.identity.login()) {
      this.identity.set(login);
      location.assign('/');   // a new user starts from their own start page with fresh state
    }
  }
}
