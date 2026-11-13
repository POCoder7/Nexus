import { DOCUMENT } from '@angular/common';
import { Injectable, computed, effect, inject } from '@angular/core';
import { NexusApi } from '../api/nexus-api';
import type { Preferences } from '../api/generated/models';
import { ContextStore } from './context.store';
import { PREFERENCE_DEBOUNCE_MS } from './config';

export type StartPage = 'home' | 'hierarchies' | 'worklist';
export type Density = 'compact' | 'comfortable';

/** Start page, last hierarchy and density (OD-27): server-side, never browser storage (LLD §9). */
@Injectable({ providedIn: 'root' })
export class PreferencesStore {
  private readonly api = inject(NexusApi);
  private readonly context = inject(ContextStore);
  private readonly document = inject(DOCUMENT);
  private pendingHierarchy: ReturnType<typeof setTimeout> | null = null;

  readonly startPage = computed<StartPage>(() => (this.context.me()?.preferences?.startPage as StartPage) ?? 'home');
  readonly density = computed<Density>(() => (this.context.me()?.preferences?.density as Density) ?? 'compact');
  readonly lastHierarchy = computed(() => this.context.me()?.preferences?.lastHierarchyCode ?? null);

  constructor() {
    effect(() => {
      this.document.documentElement.dataset['density'] = this.density();
    });
  }

  async save(change: { startPage?: StartPage; density?: Density }): Promise<void> {
    const prefs = await this.api.updatePreferences(change);
    this.patch(prefs);
  }

  /** Chooses the working version new requests are raised in (ADR-037). The server refuses a version that is not working. */
  async saveWorkingVersion(name: string): Promise<void> {
    const prefs = await this.api.updatePreferences({ workingVersion: name });
    this.patch(prefs);
    const me = this.context.me();
    if (me) {
      this.context.me.set({ ...me, workingVersion: prefs.workingVersion ?? name });
    }
  }

  /** Remembers the hierarchy in view, debounced (LLD §5.2), so Hierarchies reopens it. */
  rememberHierarchy(code: string): void {
    if (this.pendingHierarchy) {
      clearTimeout(this.pendingHierarchy);
    }
    this.pendingHierarchy = setTimeout(() => {
      this.pendingHierarchy = null;
      if (code !== this.lastHierarchy()) {
        this.api.updatePreferences({ lastHierarchyCode: code }).then((p) => this.patch(p), () => undefined);
      }
    }, PREFERENCE_DEBOUNCE_MS);
  }

  private patch(prefs: Preferences): void {
    const me = this.context.me();
    if (me) {
      this.context.me.set({ ...me, preferences: { ...me.preferences, ...prefs } });
    }
  }
}
