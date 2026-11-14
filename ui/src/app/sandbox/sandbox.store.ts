import { Injectable, computed, inject, signal } from '@angular/core';
import { NexusApi, newIdempotencyKey } from '../api/nexus-api';
import type { ChangeRequestView, Conflict, ItemFailure, ItemView, SandboxView } from '../api/generated/models';
import { TrayStore } from '../change-request/tray.store';
import { MAINTAIN_MODEL } from '../core/config';
import { ContextStore } from '../core/context.store';
import { UiError } from '../core/ui-error';

/**
 * One sandbox's page (NEW-08, Phase 5 LLD §5, §12): the sandbox, its items, its conflicts and the items its overlay leaves
 * out. Rebase, Remove change, Submit as request and Discard go through the API with `If-Match`; the server decides.
 * When the sandbox is also the one in view in the workspace, the tray is reloaded after each change.
 */
@Injectable()
export class SandboxStore {
  private readonly api = inject(NexusApi);
  private readonly context = inject(ContextStore);
  private readonly tray = inject(TrayStore);

  readonly sandbox = signal<SandboxView | null>(null);
  readonly items = signal<ItemView[]>([]);
  readonly conflicts = signal<Conflict[]>([]);
  readonly failures = signal<ItemFailure[]>([]);
  readonly loading = signal(false);
  readonly busy = signal(false);
  readonly error = signal<UiError | null>(null);
  private etag = '';

  readonly isOwner = computed(() => !!this.sandbox() && this.sandbox()?.ownerId === this.context.userId());
  readonly isOpen = computed(() => this.sandbox()?.kind === 'sandbox' && this.sandbox()?.status === 'draft');
  readonly canChange = computed(() => this.isOwner() && this.isOpen());

  async load(id: string): Promise<void> {
    this.loading.set(true);
    this.error.set(null);
    try {
      const [{ body, etag }, items] = await Promise.all([this.api.sandbox(id), this.api.sandboxItems(id)]);
      this.sandbox.set(body);
      this.etag = etag;
      this.items.set(items.items ?? []);
      const ownOpen = body.kind === 'sandbox' && body.status === 'draft' && body.ownerId === this.context.userId();
      this.conflicts.set(ownOpen ? ((await this.api.sandboxConflicts(id)).items ?? []) : []);
      // the latest refresh outcome the tray knows, when this is the sandbox in view
      if (this.context.sandboxParam() === id && this.failures().length === 0) {
        this.failures.set(this.tray.failures());
      }
    } catch (e) {
      this.error.set(UiError.from(e));
    } finally {
      this.loading.set(false);
    }
  }

  /** Moves the base to now and refreshes; the conflicting items stay listed until they are changed. */
  async rebase(): Promise<void> {
    const id = this.sandbox()?.id;
    if (!id) return;
    await this.write(async () => {
      const { body } = await this.api.rebaseSandbox(id, this.etag);
      this.failures.set(body.failures ?? []);
    });
  }

  async removeItem(itemId: string): Promise<void> {
    const id = this.sandbox()?.id;
    if (!id) return;
    await this.write(async () => {
      const { body } = await this.api.deleteSandboxItem(id, itemId, this.etag);
      this.failures.set(body.failures ?? []);
    });
  }

  /** Submits as a request with the MAINTAIN workflow model, as the tray's drafts are; returns the request it became. */
  async submit(): Promise<ChangeRequestView> {
    const id = this.sandbox()!.id!;
    this.busy.set(true);
    try {
      const { body } = await this.api.submitSandbox(id, this.etag, MAINTAIN_MODEL);
      await this.afterLeaving(id);
      return body;
    } catch (e) {
      const error = UiError.from(e);
      if (error.status === 422 || error.status === 412) {
        await this.load(id);   // the conflicts or the latest ETag
      }
      throw error;
    } finally {
      this.busy.set(false);
    }
  }

  async discard(): Promise<void> {
    const id = this.sandbox()!.id!;
    this.busy.set(true);
    try {
      const { body } = await this.api.discardSandbox(id, this.etag);
      this.sandbox.set(body);
      await this.afterLeaving(id);
    } finally {
      this.busy.set(false);
    }
  }

  /** Creates a sandbox in the working version; returns it. */
  async create(name: string, effectiveFrom: string): Promise<SandboxView> {
    const { body } = await this.api.createSandbox({ name, effectiveFrom, versionName: this.context.workingVersion() ?? undefined },
      newIdempotencyKey());
    void this.context.loadSandboxes();
    return body;
  }

  private async write(action: () => Promise<void>): Promise<void> {
    const id = this.sandbox()!.id!;
    this.busy.set(true);
    try {
      await action();
    } catch (e) {
      const error = UiError.from(e);
      await this.load(id);
      throw error;
    } finally {
      this.busy.set(false);
    }
    const kept = this.failures();
    await this.load(id);
    this.failures.set(kept);
    await this.syncWorkspace(id);
  }

  /** The tray and the context bar follow when this sandbox is the one in view. */
  private async syncWorkspace(id: string): Promise<void> {
    if (this.context.sandboxParam() === id) {
      await Promise.all([this.tray.load(true), this.context.refreshSandbox()]);
      this.tray.revision.update((r) => r + 1);
    }
  }

  /** After submit or discard the sandbox is no longer open: leave it in the workspace too. */
  private async afterLeaving(id: string): Promise<void> {
    void this.context.loadSandboxes();
    if (this.context.sandboxParam() === id) {
      await this.context.enterSandbox(null);
    }
  }
}
