import { Injectable, inject, signal } from '@angular/core';
import { NexusApi } from '../api/nexus-api';
import type { WorklistRow } from '../api/generated/models';
import { WORKLIST_PAGE, WorklistView } from '../core/config';
import { UiError } from '../core/ui-error';

/** Worklist state (LLD §3.2; GOV-13): view, search, model filter, keyset pages and the count per view. */
@Injectable()
export class WorklistStore {
  private readonly api = inject(NexusApi);

  readonly view = signal<WorklistView>('assigned');
  readonly search = signal('');
  readonly model = signal('');
  readonly rows = signal<WorklistRow[]>([]);
  readonly counts = signal<Record<string, number>>({});
  readonly nextCursor = signal<string | null>(null);
  readonly loading = signal(false);
  readonly error = signal<UiError | null>(null);
  private generation = 0;

  async load(view: WorklistView, search: string, model: string): Promise<void> {
    const generation = ++this.generation;
    this.view.set(view);
    this.search.set(search);
    this.model.set(model);
    this.loading.set(true);
    this.error.set(null);
    try {
      const page = await this.api.worklist(view, search || undefined, model || undefined, WORKLIST_PAGE);
      if (generation !== this.generation) {
        return;
      }
      this.rows.set(page.items ?? []);
      this.counts.set((page.counts ?? {}) as Record<string, number>);
      this.nextCursor.set(page.nextCursor ?? null);
    } catch (e) {
      if (generation === this.generation) {
        this.error.set(UiError.from(e));
        this.rows.set([]);
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
    this.loading.set(true);
    try {
      const page = await this.api.worklist(this.view(), this.search() || undefined, this.model() || undefined, WORKLIST_PAGE, cursor);
      if (generation === this.generation) {
        this.rows.update((r) => [...r, ...(page.items ?? [])]);
        this.nextCursor.set(page.nextCursor ?? null);
      }
    } catch (e) {
      this.error.set(UiError.from(e));
    } finally {
      this.loading.set(false);
    }
  }
}
