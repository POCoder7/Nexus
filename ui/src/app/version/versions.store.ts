import { Injectable, inject, signal } from '@angular/core';
import { NexusApi } from '../api/nexus-api';
import type { VersionView } from '../api/generated/models';
import { VERSIONS_PAGE } from '../core/config';
import { ContextStore } from '../core/context.store';
import { UiError } from '../core/ui-error';

export const VERSION_FILTERS = ['working', 'submitted', 'finalized', 'expired', 'all'] as const;
export type VersionFilter = (typeof VERSION_FILTERS)[number];

/**
 * Versions page state (Phase 3 LLD V.6; VER-01, VER-02): the status filter, keyset pages of `GET /versions`, loading and
 * error. Holds no rule: which transitions are offered, and why one is refused, come from the server on every row.
 */
@Injectable()
export class VersionsStore {
  private readonly api = inject(NexusApi);
  private readonly context = inject(ContextStore);

  readonly filter = signal<VersionFilter>('all');
  readonly rows = signal<VersionView[]>([]);
  readonly nextCursor = signal<string | null>(null);
  readonly loading = signal(false);
  readonly error = signal<UiError | null>(null);
  private generation = 0;

  async load(filter: VersionFilter): Promise<void> {
    const generation = ++this.generation;
    this.filter.set(filter);
    this.loading.set(true);
    this.error.set(null);
    try {
      const page = await this.api.versions(filter === 'all' ? undefined : filter, undefined, VERSIONS_PAGE);
      if (generation !== this.generation) {
        return;
      }
      this.rows.set(page.items ?? []);
      this.nextCursor.set(page.nextCursor ?? null);
    } catch (e) {
      if (generation === this.generation) {
        this.error.set(UiError.from(e));
        this.rows.set([]);
        this.nextCursor.set(null);
      }
    } finally {
      if (generation === this.generation) {
        this.loading.set(false);
      }
    }
  }

  async loadMore(): Promise<void> {
    const cursor = this.nextCursor();
    if (!cursor || this.loading()) {
      return;
    }
    const generation = this.generation;
    const filter = this.filter();
    this.loading.set(true);
    try {
      const page = await this.api.versions(filter === 'all' ? undefined : filter, cursor, VERSIONS_PAGE);
      if (generation === this.generation) {
        this.rows.update((r) => [...r, ...(page.items ?? [])]);
        this.nextCursor.set(page.nextCursor ?? null);
      }
    } catch (e) {
      if (generation === this.generation) {
        this.error.set(UiError.from(e));
      }
    } finally {
      if (generation === this.generation) {
        this.loading.set(false);
      }
    }
  }

  /**
   * After a create, edit or transition: the list, the context-bar picker and `/me` (whose working version falls back to the
   * latest working one when the chosen version leaves working) all follow the server.
   */
  async refresh(): Promise<void> {
    await Promise.all([this.load(this.filter()), this.context.loadWorkingVersions(), this.context.load(true)]);
  }
}
