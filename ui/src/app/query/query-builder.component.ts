import { ChangeDetectionStrategy, Component, computed, input, output } from '@angular/core';
import { STRINGS } from '../core/strings';
import { DsButtonComponent } from '../shared/ds';
import { Condition, Field, Group, MAX_GROUP_DEPTH, OPS_BY_TYPE, allowsCi, isList, isRange, needsValue } from './query-model';

/** An edit the builder asks for; the page applies it to the model (query-model.ts). */
export type QueryEdit =
  | { type: 'addCondition'; path: number[] }
  | { type: 'addGroup'; path: number[] }
  | { type: 'remove'; path: number[] }
  | { type: 'mode'; path: number[]; mode: 'all' | 'any' }
  | { type: 'patch'; path: number[]; patch: Partial<Condition> };

/**
 * `nx-query-builder` (QRY-01, Phase 5 LLD §17.12): one group of conditions, rendered recursively for nested groups.
 * Each condition picks a field (the node's attributes, then properties by category), a comparison offered for that
 * field's type, and a value. Presentational: it emits edits and the page applies them. Every control has a label
 * that names its condition, so a screen-reader user knows which row they are in.
 */
@Component({
  selector: 'nx-query-builder',
  imports: [DsButtonComponent],
  template: `
    <fieldset class="group" [class.group--nested]="depth() > 0" [attr.data-depth]="depth()">
      <legend>{{ t.groupLabel(depth()) }}</legend>
      <div class="mode" role="radiogroup" [attr.aria-label]="t.modeLabel">
        <label><input type="radio" [name]="'nx-mode-' + group().id" [checked]="group().mode === 'all'"
                      (change)="edit.emit({ type: 'mode', path: path(), mode: 'all' })" /> {{ t.matchAll }}</label>
        <label><input type="radio" [name]="'nx-mode-' + group().id" [checked]="group().mode === 'any'"
                      (change)="edit.emit({ type: 'mode', path: path(), mode: 'any' })" /> {{ t.matchAny }}</label>
      </div>
      @if (group().items.length === 0) {
        <p class="nx-muted">{{ t.empty }}</p>
      }
      <ul class="items">
        @for (item of group().items; track item.id; let i = $index) {
          <li>
            @if (item.kind === 'group') {
              <nx-query-builder [group]="item" [path]="childPath(i)" [depth]="depth() + 1" [fields]="fields()"
                                [numbers]="numbers()" (edit)="edit.emit($event)" />
              <ds-button variant="link" (pressed)="edit.emit({ type: 'remove', path: childPath(i) })">{{ t.removeGroup }}</ds-button>
            } @else {
              @let n = numbers().get(item.id) ?? 0;
              @let f = fieldOf(item);
              <div class="condition" [attr.data-condition]="n">
                <span class="nx-identifier num" aria-hidden="true">{{ n }}</span>
                <select [attr.aria-label]="t.field(n)" [value]="item.field"
                        (change)="patch(i, { field: $any($event.target).value })" data-testid="query-field">
                  @for (g of groups(); track g.name) {
                    <optgroup [label]="g.name">
                      @for (x of g.fields; track x.key) {
                        <option [value]="x.key" [selected]="x.key === item.field">{{ x.label }}</option>
                      }
                    </optgroup>
                  }
                </select>
                <select [attr.aria-label]="t.operator(n)" (change)="patch(i, { op: $any($event.target).value })" data-testid="query-op">
                  @for (op of opsOf(f); track op) {
                    <option [value]="op" [selected]="op === item.op">{{ t.ops[op] ?? op }}</option>
                  }
                </select>
                @if (needsValue(item.op)) {
                  @if (f?.type === 'boolean') {
                    <select [attr.aria-label]="t.value(n)" (change)="patch(i, { value: $any($event.target).value })" data-testid="query-value">
                      <option value="" [selected]="item.value === ''"></option>
                      <option value="true" [selected]="item.value === 'true'">{{ t.yes }}</option>
                      <option value="false" [selected]="item.value === 'false'">{{ t.no }}</option>
                    </select>
                  } @else {
                    <input [attr.aria-label]="t.value(n)" [type]="inputType(f)" [value]="item.value"
                           [attr.list]="f?.listValues && !isList(item.op) ? 'nx-list-' + item.id : null"
                           [attr.aria-describedby]="isList(item.op) ? 'nx-list-hint-' + item.id : null"
                           (input)="patch(i, { value: $any($event.target).value })" data-testid="query-value" />
                    @if (f?.listValues && !isList(item.op)) {
                      <datalist [id]="'nx-list-' + item.id">
                        @for (v of f!.listValues!; track v) {
                          <option [value]="v"></option>
                        }
                      </datalist>
                    }
                    @if (isList(item.op)) {
                      <span class="nx-muted hint" [id]="'nx-list-hint-' + item.id">{{ t.listHint }}</span>
                    }
                  }
                  @if (isRange(item.op)) {
                    <input [attr.aria-label]="t.upper(n)" [type]="inputType(f)" [value]="item.value2"
                           (input)="patch(i, { value2: $any($event.target).value })" data-testid="query-value2" />
                  }
                  @if (allowsCi(item.op)) {
                    <label class="ci"><input type="checkbox" [checked]="item.ci" [attr.aria-label]="t.ignoreCase(n)"
                                             (change)="patch(i, { ci: $any($event.target).checked })" /> {{ t.ignoreCaseShort }}</label>
                  }
                }
                <ds-button variant="link" (pressed)="edit.emit({ type: 'remove', path: childPath(i) })">
                  <span aria-hidden="true">✕</span><span class="nx-visually-hidden">{{ t.removeCondition(n) }}</span>
                </ds-button>
              </div>
            }
          </li>
        }
      </ul>
      <div class="actions">
        <ds-button (pressed)="edit.emit({ type: 'addCondition', path: path() })" data-testid="query-add-condition">{{ t.addCondition }}</ds-button>
        @if (depth() < maxDepth) {
          <ds-button variant="link" (pressed)="edit.emit({ type: 'addGroup', path: path() })" data-testid="query-add-group">{{ t.addGroup }}</ds-button>
        }
      </div>
    </fieldset>
  `,
  styles: `
    .group { margin: 0; padding: var(--nx-space-3) var(--nx-space-4); border: var(--nx-border-width) solid var(--nx-color-border-default);
             border-radius: var(--nx-radius-2); }
    .group--nested { margin-top: var(--nx-space-2); background: var(--nx-color-surface-page); }
    legend { padding: 0 var(--nx-space-2); font-weight: var(--nx-font-weight-strong); }
    .mode { display: flex; gap: var(--nx-space-4); margin-bottom: var(--nx-space-2); }
    .items { display: flex; flex-direction: column; gap: var(--nx-space-2); margin: 0; padding: 0; list-style: none; }
    .condition { display: flex; flex-wrap: wrap; align-items: center; gap: var(--nx-space-2); }
    .num { min-width: var(--nx-space-5); color: var(--nx-color-text-secondary); }
    .condition select, .condition input:not([type='checkbox']) { padding: var(--nx-space-1) var(--nx-space-2);
             border: var(--nx-border-width) solid var(--nx-color-border-strong); border-radius: var(--nx-radius-1);
             background: var(--nx-color-surface-panel); color: var(--nx-color-text-primary); font-size: var(--nx-font-size-body); }
    .hint, .ci { font-size: var(--nx-font-size-label); }
    .actions { display: flex; gap: var(--nx-space-3); margin-top: var(--nx-space-3); }
  `,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class QueryBuilderComponent {
  readonly group = input.required<Group>();
  readonly path = input<number[]>([]);
  readonly depth = input(0);
  readonly fields = input.required<Field[]>();
  /** Condition numbers in reading order, the same across nested groups. */
  readonly numbers = input<Map<number, number>>(new Map());
  readonly edit = output<QueryEdit>();

  protected readonly t = STRINGS.queries;
  protected readonly maxDepth = MAX_GROUP_DEPTH;
  protected readonly needsValue = needsValue;
  protected readonly isRange = isRange;
  protected readonly isList = isList;
  protected readonly allowsCi = allowsCi;

  protected readonly groups = computed(() => {
    const out: { name: string; fields: Field[] }[] = [];
    for (const f of this.fields()) {
      const last = out[out.length - 1];
      if (last && last.name === f.group) {
        last.fields.push(f);
      } else {
        out.push({ name: f.group, fields: [f] });
      }
    }
    return out;
  });

  protected childPath(i: number): number[] {
    return [...this.path(), i];
  }

  protected fieldOf(c: Condition): Field | undefined {
    return this.fields().find((f) => f.key === c.field);
  }

  protected opsOf(f: Field | undefined): string[] {
    return OPS_BY_TYPE[f?.type ?? 'text'];
  }

  protected inputType(f: Field | undefined): string {
    return f?.type === 'number' ? 'number' : f?.type === 'date' ? 'date' : f?.type === 'datetime' ? 'datetime-local' : 'text';
  }

  protected patch(i: number, patch: Partial<Condition>): void {
    this.edit.emit({ type: 'patch', path: this.childPath(i), patch });
  }
}

/** Condition numbers in reading order (depth first), for labels and problems. */
export function numberConditions(root: Group): Map<number, number> {
  const out = new Map<number, number>();
  const walk = (g: Group) => {
    for (const item of g.items) {
      if (item.kind === 'group') {
        walk(item);
      } else {
        out.set(item.id, out.size + 1);
      }
    }
  };
  walk(root);
  return out;
}
