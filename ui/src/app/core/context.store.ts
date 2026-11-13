import { Injectable, computed, inject, signal } from '@angular/core';
import { Router } from '@angular/router';
import { NexusApi, Slice } from '../api/nexus-api';
import type { MeView, VersionView } from '../api/generated/models';
import { formatBusinessDate, formatInstant } from '../shared/format/nx-date.pipe';
import { WORKING_VERSIONS_LIMIT } from './config';
import { STRINGS } from './strings';
import { UiError } from './ui-error';

export type PermissionName = 'READ' | 'PROPOSE' | 'DECIDE' | 'ADMIN_WORKFLOW' | 'ADMIN_POLICY' | 'ADMIN_SYSTEM' | 'ADMIN_VERSION';

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;
const ISO_INSTANT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/;

/**
 * Global context (LLD §3.1, UI_STANDARD §4): who is signed in, the business "today", the "Viewing as of" date and the
 * hierarchy in view. "Today" always comes from the server (`GET /me` → `businessToday`, ADR-018), never from the
 * browser's clock or time zone. `permissions` only decide which controls to offer; the server decides everything.
 *
 * A version's picture (Phase 3 LLD V.6, ADR-037) is the same view with `?recordedAsOf=` (the version's pin) and
 * `?version=` (its name, for the banner) next to `?asOf=` (its business date). The view is historical, so read-only,
 * when the date is not today or a recorded time is set.
 */
@Injectable({ providedIn: 'root' })
export class ContextStore {
  private readonly api = inject(NexusApi);
  private readonly router = inject(Router);

  readonly me = signal<MeView | null>(null);
  readonly loadError = signal<UiError | null>(null);
  /** The `?asOf=` query parameter; null means today. */
  readonly asOfParam = signal<string | null>(null);
  /** The `?recordedAsOf=` query parameter (an instant); null means as recorded now. */
  readonly recordedAsOfParam = signal<string | null>(null);
  /** The `?version=` query parameter: the version whose picture is shown, named in the banner. */
  readonly versionParam = signal<string | null>(null);
  /** The status of that version, looked up from the server (it can change while the picture is open). */
  readonly versionStatus = signal<string | null>(null);
  readonly hierarchyName = signal<string | null>(null);
  /** Working versions for the context-bar picker: the first page of `GET /versions?status=working`. */
  readonly workingVersions = signal<VersionView[]>([]);

  readonly businessToday = computed(() => this.me()?.businessToday ?? null);
  readonly asOf = computed(() => this.asOfParam() ?? this.businessToday());
  readonly isHistorical = computed(() => {
    const param = this.asOfParam();
    return (param !== null && param !== this.businessToday()) || this.recordedAsOfParam() !== null;
  });
  readonly workingVersion = computed(() => this.me()?.workingVersion ?? null);
  readonly displayName = computed(() => this.me()?.actor?.displayName ?? this.me()?.actor?.login ?? null);
  readonly userId = computed(() => this.me()?.actor?.userId ?? null);
  /** The slice for reads: only an explicit historical date and recorded time are sent; otherwise the server uses its own today. */
  readonly slice = computed<Slice>(() => {
    if (!this.isHistorical()) {
      return {};
    }
    const recorded = this.recordedAsOfParam();
    return recorded ? { asOf: this.asOf() ?? undefined, recordedAsOf: recorded } : { asOf: this.asOf() ?? undefined };
  });

  /**
   * The banner over a read-only view: a version's picture names the version and its status ("Version X, finalized: the
   * data on … as recorded at …. Read-only."); any other past view keeps the plain historical text. Null when not historical.
   */
  readonly banner = computed<string | null>(() => {
    if (!this.isHistorical()) {
      return null;
    }
    const date = formatBusinessDate(this.asOf());
    const recorded = this.recordedAsOfParam();
    const version = this.versionParam();
    if (!version && !recorded) {
      return STRINGS.context.historicalBanner(date);
    }
    const status = this.versionStatus();
    return STRINGS.context.pictureBanner(version, status ? STRINGS.versions.statusWords[status] ?? status : null, date,
      recorded ? formatInstant(recorded, this.me()?.businessTimeZone ?? undefined) : null);
  });

  private loading: Promise<MeView | null> | null = null;
  private statusFor: string | null = null;

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

  /** Reloads the working versions for the picker; called at start and after a version changes. Failures keep the last list. */
  async loadWorkingVersions(): Promise<void> {
    try {
      const page = await this.api.versions('working', undefined, WORKING_VERSIONS_LIMIT);
      this.workingVersions.set(page.items ?? []);
    } catch {
      // the picker still shows the current working version from /me
    }
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

  /** Called by the shell on every navigation: the URL is the source of truth for the slice (LLD §6.3, V.6). */
  syncFromUrl(asOf: string | null, recordedAsOf: string | null = null, version: string | null = null): void {
    this.asOfParam.set(asOf && ISO_DATE.test(asOf) ? asOf : null);
    this.recordedAsOfParam.set(recordedAsOf && ISO_INSTANT.test(recordedAsOf) && !Number.isNaN(Date.parse(recordedAsOf))
      ? recordedAsOf : null);
    const name = version?.trim() || null;
    this.versionParam.set(name);
    if (name !== this.statusFor) {
      this.statusFor = name;
      this.versionStatus.set(null);
      if (name) {
        this.api.version(name).then(
          ({ body }) => (this.statusFor === name ? this.versionStatus.set(body.status ?? null) : undefined),
          () => undefined,   // the banner then names the version without its status
        );
      }
    }
  }

  /**
   * Changes the global as-of date; today (or empty) clears it. Changing the date leaves a version's picture, so the recorded
   * time and version go too. The URL carries all three so links open the same view.
   */
  setAsOf(date: string | null): Promise<boolean> {
    const value = !date || date === this.businessToday() ? null : date;
    return this.router.navigate([], { queryParams: { asOf: value, recordedAsOf: null, version: null }, queryParamsHandling: 'merge',
      replaceUrl: false });
  }

  /** Opens a version's picture in the hierarchy workspace: its business date, as recorded at its pin (or now while working). */
  openPicture(v: VersionView): Promise<boolean> {
    return this.router.navigate(['/hierarchies'], { queryParams: { asOf: v.businessAsOf, recordedAsOf: v.recordedAsOf ?? null,
      version: v.name } });
  }
}
