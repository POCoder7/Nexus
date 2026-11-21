import { ChangeDetectionStrategy, Component, computed, inject, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { STRINGS } from '../strings';
import { DEV_LOGINS, DevIdentity } from './dev-identity.providers';

/** A user the development picker offers. */
interface DevUser {
  login: string;
  displayName: string;
}

/**
 * Development user picker (local and test builds only, LLD C-7): chooses the synthetic login sent as X-Nexus-User. A plain
 * dropdown of the active users of the running database (GET /api/v1/dev/users, local and test profiles only), so the list
 * follows whatever the database holds: the demo's data set or the end-to-end seed. Choosing a user switches to them at
 * once (owner, 2026-11-20). The current login is always listed, even when the database does not offer it.
 */
@Component({
  selector: 'nx-dev-user-picker',
  templateUrl: './dev-user-picker.component.html',
  styleUrl: './dev-user-picker.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class DevUserPickerComponent {
  protected readonly t = STRINGS.user;
  protected readonly users = signal<DevUser[]>(DEV_LOGINS.map((login) => ({ login, displayName: login })));
  private readonly identity = inject(DevIdentity);
  protected readonly value = signal(this.identity.login() ?? '');
  protected readonly options = computed(() => {
    const current = this.value();
    const list = this.users();
    return current && !list.some((u) => u.login === current) ? [{ login: current, displayName: current }, ...list] : list;
  });

  constructor() {
    inject(HttpClient).get<DevUser[]>('/api/v1/dev/users').subscribe({
      next: (users) => this.users.set(users),
      error: () => undefined,   // the built-in list is offered instead
    });
  }

  protected choose(login: string): void {
    if (login && login !== this.identity.login()) {
      this.value.set(login);
      this.identity.set(login);
      location.assign('/');   // a new user starts from their own start page with fresh state
    }
  }
}
