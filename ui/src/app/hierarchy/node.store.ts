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
  private generation = 0;

  async load(nodeId: string, hierarchyCode: string, slice: Slice): Promise<void> {
    const generation = ++this.generation;
    this.loading.set(true);
    this.error.set(null);
    try {
      const [detail, path] = await Promise.all([
        this.api.node(nodeId, hierarchyCode, slice),
        this.api.path(hierarchyCode, nodeId, slice).then((p) => p.path ?? [], () => [] as NodeRef[]),
      ]);
      if (generation !== this.generation) {
        return;
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

  clear(): void {
    this.generation++;
    this.detail.set(null);
    this.path.set([]);
    this.error.set(null);
    this.loading.set(false);
  }
}
