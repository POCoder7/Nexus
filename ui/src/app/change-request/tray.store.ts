import { Injectable, computed, inject, signal } from '@angular/core';
import { NexusApi, Tagged, newIdempotencyKey } from '../api/nexus-api';
import type { ChangeRequestView, ItemCommand, ItemView } from '../api/generated/models';
import { ADD_LEAF_MODEL, MAINTAIN_MODEL } from '../core/config';
import { ContextStore } from '../core/context.store';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';

/** A change that could not be added; retried with the same idempotency key, so a retry never adds it twice. */
export interface FailedItem {
  key: string;
  command: ItemCommand;
  error: UiError;
}

export interface NewLeaf {
  hierarchyCode: string;
  parentId: string;
  parentName: string;
  name: string;
  description: string | null;
  nodeKind: string;
  isLeaf: boolean;
  effectiveFrom: string;
  properties: { code: string; value: unknown }[];
}

/**
 * The change-request tray (LLD §3.2, §7.3, UI_STANDARD §6): the user's current draft, its items and ETag. Edits only
 * ever become items of a draft request; nothing here writes live data. Every item call sends `If-Match` with the latest
 * ETag and stores the returned one (ETag chaining); each user action has its own idempotency key.
 */
@Injectable({ providedIn: 'root' })
export class TrayStore {
  private readonly api = inject(NexusApi);
  private readonly context = inject(ContextStore);

  readonly request = signal<ChangeRequestView | null>(null);
  readonly items = signal<ItemView[]>([]);
  readonly failed = signal<FailedItem[]>([]);
  readonly busy = signal(false);
  private etag = '';
  private loaded: Promise<void> | null = null;

  readonly count = computed(() => this.items().length);
  readonly hasDraft = computed(() => this.request()?.status === 'draft');

  /** Finds the user's latest draft (if any) so the tray survives a reload. */
  load(force = false): Promise<void> {
    if (!this.loaded || force) {
      this.loaded = (async () => {
        try {
          const page = await this.api.myRequests('draft', 1);
          const latest = page.items?.[0];
          if (latest?.id) {
            await this.reload(latest.id);
          } else {
            this.reset();
          }
        } catch {
          this.loaded = null;   // the shell shows the error when the context fails; the tray just stays empty
        }
      })();
    }
    return this.loaded;
  }

  /** Adds a leaf with its properties to the draft, creating the draft if needed (LLD §6.1). */
  async addLeaf(leaf: NewLeaf): Promise<{ nodeId: string; failed: number }> {
    this.busy.set(true);
    try {
      await this.ensureDraft(STRINGS.addLeaf.requestTitle(leaf.name, leaf.parentName), leaf.effectiveFrom);
      const added = await this.add({
        action: 'add_node', hierarchyCode: leaf.hierarchyCode, targetParentId: leaf.parentId,
        payload: { nodeKind: leaf.nodeKind, name: leaf.name, description: leaf.description ?? undefined, isLeaf: leaf.isLeaf },
      }, newIdempotencyKey());
      const nodeId = added.nodeId!;
      for (const p of leaf.properties) {
        const command: ItemCommand = { action: 'set_property', hierarchyCode: leaf.hierarchyCode, nodeId, propertyCode: p.code,
          payload: { value: p.value } };
        const key = newIdempotencyKey();
        try {
          await this.add(command, key);
        } catch (e) {
          const error = UiError.from(e);
          if (error.status === 412) {
            throw error;
          }
          this.failed.update((f) => [...f, { key, command, error }]);   // partial failure: keep what was added
        }
      }
      return { nodeId, failed: this.failed().length };
    } finally {
      this.busy.set(false);
    }
  }

  /**
   * Adds one change of any kind to the draft (scope extension: edit details, properties, place, move, remove, delete,
   * new hierarchy). A new draft for it uses the MAINTAIN model; a change joins the current draft whatever its model.
   */
  async addChange(command: ItemCommand, title: string, effectiveFrom: string): Promise<ItemView> {
    this.busy.set(true);
    try {
      await this.ensureDraft(title, effectiveFrom, MAINTAIN_MODEL);
      return await this.add(command, newIdempotencyKey());
    } finally {
      this.busy.set(false);
    }
  }

  /** Retries the changes that failed, each with its original key (idempotent). */
  async retryFailed(): Promise<void> {
    const pending = this.failed();
    this.failed.set([]);
    for (const f of pending) {
      try {
        await this.add(f.command, f.key);
      } catch (e) {
        this.failed.update((list) => [...list, { ...f, error: UiError.from(e) }]);
      }
    }
  }

  /** The ETag to submit with. */
  currentEtag(): string {
    return this.etag;
  }

  async reload(id: string): Promise<void> {
    const [{ body, etag }, items] = await Promise.all([this.api.request(id), this.api.items(id)]);
    this.request.set(body.status === 'draft' ? body : null);
    this.items.set(body.status === 'draft' ? (items.items ?? []) : []);
    this.etag = etag;
  }

  /**
   * Moves a draft to another working version (ADR-037; after `N2703`, Phase 3 LLD V.6): `PATCH versionName` with If-Match.
   * The server refuses a target that is not working. The tray follows when it holds this draft.
   */
  async moveTo(id: string, etag: string, versionName: string): Promise<Tagged<ChangeRequestView>> {
    const moved = await this.api.moveRequest(id, etag, versionName);
    if (this.request()?.id === id) {
      this.request.set(moved.body);
      this.etag = moved.etag;
    }
    return moved;
  }

  /** Withdraws a draft (the requester only; the database re-checks). The tray empties when it held this draft. */
  async withdraw(id: string, etag: string): Promise<Tagged<ChangeRequestView>> {
    const withdrawn = await this.api.withdraw(id, etag);
    if (this.request()?.id === id) {
      this.reset();
    }
    return withdrawn;
  }

  /** After submit (or withdraw) the tray is empty until the next draft. */
  reset(): void {
    this.request.set(null);
    this.items.set([]);
    this.failed.set([]);
    this.etag = '';
  }

  private async ensureDraft(title: string, effectiveFrom: string, model: string = ADD_LEAF_MODEL): Promise<void> {
    if (this.hasDraft()) {
      return;
    }
    const version = this.context.workingVersion();
    const created = await this.api.createRequest({ versionName: version ?? undefined, title, riskTier: 'low', effectiveFrom,
      workflowModelCode: model }, newIdempotencyKey());
    this.request.set(created.body);
    this.items.set([]);
    this.etag = created.etag;
  }

  private async add(command: ItemCommand, key: string): Promise<ItemView> {
    const id = this.request()!.id!;
    try {
      const { body, etag } = await this.api.addItem(id, this.etag, command, key);
      this.etag = etag;
      this.items.update((items) => [...items, body]);
      return body;
    } catch (e) {
      const error = UiError.from(e);
      if (error.status === 412) {
        await this.reload(id);   // someone changed it elsewhere: show the latest and ask to repeat (LLD §7.3)
        throw new UiError(412, error.title, STRINGS.errors.trayStale, error.code, error.type, [], error.correlationId, error.body);
      }
      throw error;
    }
  }
}
