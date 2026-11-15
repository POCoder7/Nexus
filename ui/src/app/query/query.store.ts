import { Injectable, computed, inject, signal } from '@angular/core';
import { NexusApi, etagOfRevision, newIdempotencyKey } from '../api/nexus-api';
import type { HierarchySummary, QueryDefinition, QueryRow, SavedQueryView } from '../api/generated/models';
import { ContextStore } from '../core/context.store';
import { UiError } from '../core/ui-error';
import { Field, Group, emptyGroup, fieldsFrom, fromWhere, problems, toWhere } from './query-model';

/** Results come 100 at a time; "Show more" and "Continue searching" fetch the next page. */
export const QUERY_PAGE = 100;

/**
 * The Queries page (QRY-01, Phase 5 LLD §17.12): the definition being built, its results page by page, and the saved
 * queries. Results are read at the context bar's date. A partial page (the server's scan budget ran out) is shown as
 * "N matches so far" with Continue, never as a complete answer.
 */
@Injectable()
export class QueryStore {
  private readonly api = inject(NexusApi);
  private readonly context = inject(ContextStore);

  readonly hierarchies = signal<HierarchySummary[]>([]);
  readonly fields = signal<Field[]>([]);
  readonly saved = signal<SavedQueryView[]>([]);
  readonly loadError = signal<UiError | null>(null);

  readonly hierarchyCode = signal<string | null>(null);
  readonly include = signal<'all' | 'leaves' | 'limbs'>('all');
  readonly includeInactive = signal(false);
  readonly root = signal<Group>(emptyGroup('all'));
  readonly columns = signal<string[]>([]);

  readonly rows = signal<QueryRow[]>([]);
  readonly columnsShown = signal<string[]>([]);
  readonly ran = signal(false);
  readonly running = signal(false);
  readonly partial = signal(false);
  readonly scanned = signal(0);
  readonly error = signal<UiError | null>(null);
  private cursor: string | null = null;
  private lastDefinition: QueryDefinition | null = null;

  /** The saved query being edited, if it is the user's own. */
  readonly current = signal<SavedQueryView | null>(null);

  private readonly cursorSet = signal(false);
  readonly hasMore = computed(() => this.ran() && this.cursorSet());
  readonly problems = computed(() => problems(this.root(), this.fields()));
  readonly canRun = computed(() => !!this.hierarchyCode() && this.problems().length === 0 && !this.running());

  async load(): Promise<void> {
    this.loadError.set(null);
    try {
      const [hierarchies, defs, saved] = await Promise.all([this.api.hierarchies(), this.api.propertyDefinitions(), this.api.savedQueries()]);
      this.hierarchies.set(hierarchies.items ?? []);
      this.fields.set(fieldsFrom(defs.items ?? []));
      this.saved.set(saved.items ?? []);
      if (!this.hierarchyCode() && this.hierarchies().length > 0) {
        this.hierarchyCode.set(this.hierarchies()[0].code ?? null);
      }
    } catch (e) {
      this.loadError.set(UiError.from(e));
    }
  }

  definition(): QueryDefinition {
    return {
      hierarchyCode: this.hierarchyCode() ?? undefined, include: this.include(), includeInactive: this.includeInactive(),
      where: toWhere(this.root(), this.fields()), columns: this.columns(),
    };
  }

  /** Runs the query from its first page. */
  async run(): Promise<void> {
    this.lastDefinition = this.definition();
    this.rows.set([]);
    this.scanned.set(0);
    this.cursor = null;
    await this.page();
  }

  /** The next page: more matches, or the rest of a search the budget stopped. */
  async more(): Promise<void> {
    if (this.cursor && this.lastDefinition) {
      await this.page();
    }
  }

  private async page(): Promise<void> {
    const definition = this.lastDefinition!;
    this.running.set(true);
    this.error.set(null);
    try {
      const asOf = this.context.isHistorical() ? this.context.asOf() ?? undefined : undefined;
      const page = await this.api.runQuery(definition, asOf, this.cursor ?? undefined, QUERY_PAGE);
      this.rows.update((r) => [...r, ...(page.items ?? [])]);
      this.columnsShown.set(definition.columns ?? []);
      this.scanned.update((s) => s + (page.scanned ?? 0));
      this.partial.set(page.partial === true);
      this.cursor = page.nextCursor ?? null;
      this.cursorSet.set(this.cursor !== null);
      this.ran.set(true);
    } catch (e) {
      this.error.set(UiError.from(e));
    } finally {
      this.running.set(false);
    }
  }

  /** Puts a saved query in the builder (and remembers it, when it is the user's own, so Save updates it). */
  open(q: SavedQueryView): void {
    const d = q.definition ?? {};
    this.hierarchyCode.set(d.hierarchyCode ?? this.hierarchyCode());
    this.include.set((d.include as 'all' | 'leaves' | 'limbs') ?? 'all');
    this.includeInactive.set(d.includeInactive === true);
    this.root.set(fromWhere(d.where ?? { all: [] }));
    this.columns.set(d.columns ?? []);
    this.current.set(q.mine ? q : null);
    this.ran.set(false);
    this.rows.set([]);
  }

  /** Saves the query: updates the user's own open query, or creates a new one. */
  async save(name: string, shared: boolean, asNew: boolean): Promise<SavedQueryView> {
    const body = { name, visibility: shared ? 'shared' : 'private', definition: this.definition() };
    const current = this.current();
    const { body: savedQuery } = current && !asNew
      ? await this.api.updateSavedQuery(current.id!, etagOfRevision(current.rowVersion), body)
      : await this.api.saveQuery(body, newIdempotencyKey());
    this.current.set(savedQuery);
    this.saved.set((await this.api.savedQueries()).items ?? []);
    return savedQuery;
  }

  async remove(q: SavedQueryView): Promise<void> {
    await this.api.deleteSavedQuery(q.id!, etagOfRevision(q.rowVersion));
    if (this.current()?.id === q.id) {
      this.current.set(null);
    }
    this.saved.update((list) => list.filter((x) => x.id !== q.id));
  }
}
