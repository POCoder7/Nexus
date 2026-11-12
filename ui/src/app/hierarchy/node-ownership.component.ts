import { ChangeDetectionStrategy, Component, computed, effect, inject, input, output, signal, untracked } from '@angular/core';
import { NexusApi, Slice } from '../api/nexus-api';
import type { OwnershipEdge } from '../api/generated/models';
import { STRINGS } from '../core/strings';
import { UiError } from '../core/ui-error';
import { DsButtonComponent, DsTableDirective } from '../shared/ds';

interface Side {
  rows: OwnershipEdge[];
  cursor: string | null;
}

/** Diagram geometry (SVG user units, not CSS pixels). */
const BOX_W = 180;
const BOX_H = 34;
const GAP = 12;
const MAX_IN_DIAGRAM = 8;

/**
 * Ownership tab (NEW-02, view only; second scope extension): direct owners and holdings at the as-of date as two tables,
 * which are the accessible equivalent (UI_STANDARD §5), plus a small SVG diagram of the same rows, drawn without a graph
 * library (OD-05 is open). Percentages are stored values to two decimals (UI_STANDARD §7); nothing is calculated here:
 * effective ownership and beneficial owners are Phase 6.
 */
@Component({
  selector: 'nx-node-ownership',
  imports: [DsTableDirective, DsButtonComponent],
  templateUrl: './node-ownership.component.html',
  styleUrl: './node-ownership.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class NodeOwnershipComponent {
  readonly nodeId = input.required<string>();
  readonly nodeName = input('');
  readonly slice = input<Slice>({});
  readonly openNode = output<string>();

  private readonly api = inject(NexusApi);
  protected readonly t = STRINGS.ownership;
  protected readonly owners = signal<Side>({ rows: [], cursor: null });
  protected readonly holdings = signal<Side>({ rows: [], cursor: null });
  protected readonly error = signal<UiError | null>(null);
  protected readonly loading = signal(false);
  protected readonly boxW = BOX_W;
  protected readonly boxH = BOX_H;

  constructor() {
    effect(() => {
      const id = this.nodeId();
      const slice = this.slice();
      untracked(() => void this.load(id, slice));
    });
  }

  private async load(id: string, slice: Slice): Promise<void> {
    this.loading.set(true);
    this.error.set(null);
    try {
      const [o, h] = await Promise.all([this.api.owners(id, slice), this.api.holdings(id, slice)]);
      this.owners.set({ rows: o.items ?? [], cursor: o.nextCursor ?? null });
      this.holdings.set({ rows: h.items ?? [], cursor: h.nextCursor ?? null });
    } catch (e) {
      this.error.set(UiError.from(e));
    } finally {
      this.loading.set(false);
    }
  }

  protected async more(side: 'owners' | 'holdings'): Promise<void> {
    const current = side === 'owners' ? this.owners() : this.holdings();
    if (!current.cursor) return;
    const page = side === 'owners'
      ? await this.api.owners(this.nodeId(), this.slice(), current.cursor)
      : await this.api.holdings(this.nodeId(), this.slice(), current.cursor);
    (side === 'owners' ? this.owners : this.holdings).set({ rows: [...current.rows, ...(page.items ?? [])], cursor: page.nextCursor ?? null });
  }

  protected pct(v: number | undefined | null): string {
    return v === null || v === undefined ? '—' : `${Number(v).toFixed(2)}`;
  }

  // ------------------------------------------------------------------ diagram: owners above, the node, holdings below

  protected readonly diagram = computed(() => {
    const top = this.owners().rows.slice(0, MAX_IN_DIAGRAM);
    const bottom = this.holdings().rows.slice(0, MAX_IN_DIAGRAM);
    const columns = Math.max(top.length, bottom.length, 1);
    const width = columns * (BOX_W + GAP) + GAP;
    const rowY = [GAP, GAP * 2 + BOX_H * 2, GAP * 3 + BOX_H * 4];
    const place = (i: number, n: number) => GAP + (width - GAP * 2 - n * (BOX_W + GAP) + GAP) / 2 + i * (BOX_W + GAP);
    const centre = { x: width / 2 - BOX_W / 2, y: rowY[1] };
    return {
      width,
      height: rowY[2] + BOX_H + GAP,
      centre,
      owners: top.map((e, i) => ({ e, x: place(i, top.length), y: rowY[0] })),
      holdings: bottom.map((e, i) => ({ e, x: place(i, bottom.length), y: rowY[2] })),
      hidden: Math.max(0, this.owners().rows.length - MAX_IN_DIAGRAM) + Math.max(0, this.holdings().rows.length - MAX_IN_DIAGRAM),
    };
  });

  protected label(e: OwnershipEdge): string {
    const name = e.otherName ?? '';
    return name.length > 22 ? `${name.slice(0, 21)}…` : name;
  }
}
