import { Injectable, computed, inject, signal } from '@angular/core';
import { Router } from '@angular/router';
import { NexusApi, Slice } from '../api/nexus-api';
import type { MeView } from '../api/generated/models';
import { UiError } from './ui-error';

export type PermissionName = 'READ' | 'PROPOSE' | 'DECIDE' | 'ADMIN_WORKFLOW' | 'ADMIN_POLICY' | 'ADMIN_SYSTEM';

/**
 * Global context (LLD §3.1, UI_STANDARD §4): who is signed in, the business "today", the "Viewing as of" date and the
 * hierarchy in view. "Today" always comes from the server (`GET /me` → `businessToday`, ADR-018), never from the
 * browser's clock or time zone. `permissions` only decide which controls to offer; the server decides everything.
 */
@Injectable({ providedIn: 'root' })
export class ContextStore {
  private readonly api = inject(NexusApi);
  private readonly router = inject(Router);

  readonly me = signal<MeView | null>(null);
  readonly loadError = signal<UiError | null>(null);
  /** The `?asOf=` query parameter; null means today. */
  readonly asOfParam = signal<string | null>(null);
  readonly hierarchyName = signal<string | null>(null);

  readonly businessToday = computed(() => this.me()?.businessToday ?? null);
  readonly asOf = computed(() => this.asOfParam() ?? this.businessToday());
  readonly isHistorical = computed(() => {
    const param = this.asOfParam();
    return param !== null && param !== this.businessToday();
  });
  readonly workingVersion = computed(() => this.me()?.workingVersion ?? null);
  readonly displayName = computed(() => this.me()?.actor?.displayName ?? this.me()?.actor?.login ?? null);
  readonly userId = computed(() => this.me()?.actor?.userId ?? null);
  /** The slice for reads: only an explicit historical date is sent; otherwise the server uses its own today. */
  readonly slice = computed<Slice>(() => (this.isHistorical() ? { asOf: this.asOf() ?? undefined } : {}));

  private loading: Promise<MeView | null> | null = null;

  load(force = false): Promise<MeView | null> {
    if (!this.loading || force) {
      this.loading = this.api.me().then(
        (me) => {
          this.me.set(me);
          this.loadError.set(null);
          return me;
        },
        (e: unknown) => {
          this.loadError.set(UiError.from(e));
          this.loading = null;
          return null;
        },
      );
    }
    return this.loading;
  }

  /** True if a grant gives the permission in the hierarchy (or in every hierarchy). */
  can(permission: PermissionName, hierarchyCode?: string | null): boolean {
    const perms = this.me()?.permissions ?? {};
    const all = perms['*'] ?? [];
    if (all.includes(permission)) {
      return true;
    }
    if (hierarchyCode) {
      return (perms[hierarchyCode] ?? []).includes(permission);
    }
    return Object.values(perms).some((list) => list.includes(permission));
  }

  /**
   * May the user propose edits to properties of this category here (ADR-036)? A hint for showing "Edit": a PROPOSE grant on
   * the hierarchy (or every hierarchy) whose categories are unlimited or include it. The server decides.
   */
  canEditCategory(hierarchyCode: string | null, category: string | null | undefined): boolean {
    return (this.me()?.grants ?? []).some((g) =>
      (g.roleCode === 'STEWARD') && (!g.hierarchyCode || g.hierarchyCode === hierarchyCode)
      && (!g.categoryCodes || (!!category && g.categoryCodes.includes(category))));
  }

  /** True if a grant gives the permission in every hierarchy (e.g. creating a hierarchy needs PROPOSE everywhere). */
  canEverywhere(permission: PermissionName): boolean {
    return (this.me()?.permissions?.['*'] ?? []).includes(permission);
  }

  /** Called by the shell on every navigation: the URL is the source of truth for the as-of date (LLD §6.3). */
  syncFromUrl(asOf: string | null): void {
    this.asOfParam.set(asOf && /^\d{4}-\d{2}-\d{2}$/.test(asOf) ? asOf : null);
  }

  /** Changes the global as-of date; today (or empty) clears it. The URL carries it so links open the same view. */
  setAsOf(date: string | null): Promise<boolean> {
    const value = !date || date === this.businessToday() ? null : date;
    return this.router.navigate([], { queryParams: { asOf: value }, queryParamsHandling: 'merge', replaceUrl: false });
  }
}
