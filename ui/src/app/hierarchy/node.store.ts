import { Injectable, inject, signal } from '@angular/core';
import { NexusApi, Slice } from '../api/nexus-api';
import type { NodeDetail, NodeRef } from '../api/generated/models';
import { UiError } from '../core/ui-error';

/**
 * The selected node's detail at a slice (LLD §3.2): attributes, resolved properties with provenance, the primary path,
 * and the names of the nodes that inherited values come from.
 */
@Injectable()
export class NodeStore {
  private readonly api = inject(NexusApi);

  readonly detail = signal<NodeDetail | null>(null);
  readonly path = signal<NodeRef[]>([]);
  readonly sourceNames = signal<Record<string, string>>({});
  readonly loading = signal(false);
  readonly error = signal<UiError | null>(null);
  /** In a sandbox (NEW-08): the node's attributes differ from the live data, and the codes of the values that do. */
  readonly nodeChanged = signal(false);
  readonly changedCodes = signal<ReadonlySet<string>>(new Set());
  private generation = 0;

  /**
   * With `sandboxId` the detail is that sandbox's overlay at its effective date (or the slice's date). The path stays the
   * live primary path: the overlay has no path read, so after a move it shows where the node is today (LLD §12 note).
   */
  async load(nodeId: string, hierarchyCode: string, slice: Slice, sandboxId: string | null = null): Promise<void> {
    const generation = ++this.generation;
    this.loading.set(true);
    this.error.set(null);
    try {
      const [detail, path] = await Promise.all([
        sandboxId ? this.sandboxDetail(sandboxId, nodeId, hierarchyCode, slice, generation) : this.api.node(nodeId, hierarchyCode, slice),
        this.api.path(hierarchyCode, nodeId, slice).then((p) => p.path ?? [], () => [] as NodeRef[]),
      ]);
      if (generation !== this.generation) {
        return;
      }
      if (!sandboxId) {
        this.nodeChanged.set(false);
        this.changedCodes.set(new Set());
      }
      this.detail.set(detail);
      this.path.set(path);
      // names of inheritance sources: usually ancestors on the path; otherwise one lookup each
      const names: Record<string, string> = {};
      for (const p of path) {
        names[p.nodeId!] = p.name ?? p.nodeId!;
      }
      const missing = [...new Set((detail.properties ?? []).map((p) => p.sourceNodeId).filter((id): id is string => !!id && !names[id]))];
      await Promise.all(missing.map((id) => this.api.node(id, hierarchyCode, slice).then((n) => (names[id] = n.name ?? id), () => undefined)));
      if (generation === this.generation) {
        this.sourceNames.set(names);
      }
    } catch (e) {
      if (generation === this.generation) {
        this.detail.set(null);
        this.error.set(UiError.from(e));
      }
    } finally {
      if (generation === this.generation) {
        this.loading.set(false);
      }
    }
  }

  /** The overlay node as a NodeDetail, so the panel and the property grid show it unchanged; the markers are kept apart. */
  private async sandboxDetail(sandboxId: string, nodeId: string, hierarchyCode: string, slice: Slice,
                              generation: number): Promise<NodeDetail> {
    const s = await this.api.sandboxNode(sandboxId, nodeId, hierarchyCode, slice.asOf);
    if (generation === this.generation) {
      this.nodeChanged.set(s.changed === true);
      this.changedCodes.set(new Set((s.properties ?? []).filter((p) => p.changed).map((p) => p.code!)));
    }
    return {
      nodeId: s.nodeId, kind: s.kind, name: s.name, description: s.description, active: s.active,
      allowsChildren: s.allowsChildren,
      properties: (s.properties ?? []).map((p) => ({ code: p.code, label: p.label, dataType: p.dataType, scope: p.scope,
        value: p.value, provenance: p.provenance, sourceNodeId: p.sourceNodeId, category: p.category })),
    };
  }

  clear(): void {
    this.generation++;
    this.nodeChanged.set(false);
    this.changedCodes.set(new Set());
    this.detail.set(null);
    this.path.set([]);
    this.error.set(null);
    this.loading.set(false);
  }
}
