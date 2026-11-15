import type { JsonNode, PropertyDefinitionView } from '../api/generated/models';
import { STRINGS } from '../core/strings';

/**
 * The query builder's model (QRY-01, Phase 5 LLD §17.5.1, §17.12): conditions in AND/OR groups over node attributes and
 * properties, converted to and from the filter language the server checks (`filter_compile`). Pure functions, so the
 * builder and the store stay simple and the conversion is unit-tested.
 */
export type FieldType = 'text' | 'number' | 'date' | 'datetime' | 'boolean';

export interface Field {
  key: string;                // 'attr:name' or 'prop:Custom.Currency'
  label: string;
  group: string;              // picker group: "Node" or the property category
  type: FieldType;
  attribute?: string;
  property?: string;
  listValues?: string[];
}

export interface Condition {
  kind: 'condition';
  id: number;
  field: string;
  op: string;
  value: string;
  value2: string;             // the upper bound of "between"
  ci: boolean;                // case-insensitive, for the text operators
}

export interface Group {
  kind: 'group';
  id: number;
  mode: 'all' | 'any';
  items: QueryNode[];
}

export type QueryNode = Condition | Group;

/** The server refuses groups nested deeper than this (N2807); the root is depth 0. */
export const MAX_GROUP_DEPTH = 4;

const ATTRIBUTES: { attribute: string; type: FieldType }[] = [
  { attribute: 'name', type: 'text' }, { attribute: 'description', type: 'text' }, { attribute: 'kind', type: 'text' },
  { attribute: 'level', type: 'number' }, { attribute: 'isLeaf', type: 'boolean' }, { attribute: 'isActive', type: 'boolean' },
];

export const OPS_BY_TYPE: Record<FieldType, string[]> = {
  text: ['=', '<>', 'contains', 'starts_with', 'ends_with', 'like', 'in', 'not_in', 'is_null', 'not_null'],
  number: ['=', '<>', 'gt', 'ge', 'lt', 'le', 'between', 'in', 'not_in', 'is_null', 'not_null'],
  date: ['=', 'gt', 'ge', 'lt', 'le', 'between', 'is_null', 'not_null'],
  datetime: ['gt', 'ge', 'lt', 'le', 'between', 'is_null', 'not_null'],
  boolean: ['=', 'is_null', 'not_null'],
};

const TEXT_OPS = new Set(['contains', 'starts_with', 'ends_with', 'like']);

export const needsValue = (op: string): boolean => op !== 'is_null' && op !== 'not_null';
export const isRange = (op: string): boolean => op === 'between';
export const isList = (op: string): boolean => op === 'in' || op === 'not_in';
export const allowsCi = (op: string): boolean => TEXT_OPS.has(op);

function typeOf(dataType: string | undefined): FieldType {
  switch (dataType) {
    case 'integer':
    case 'decimal':
      return 'number';
    case 'date':
      return 'date';
    case 'datetime':
      return 'datetime';
    case 'boolean':
      return 'boolean';
    default:
      return 'text';
  }
}

/** The fields a condition can name: the node's attributes, then every property, grouped by category. */
export function fieldsFrom(defs: PropertyDefinitionView[]): Field[] {
  const t = STRINGS.queries;
  const attrs: Field[] = ATTRIBUTES.map((a) => ({ key: `attr:${a.attribute}`, label: t.attributes[a.attribute] ?? a.attribute,
    group: t.nodeGroup, type: a.type, attribute: a.attribute }));
  const props: Field[] = defs
    .filter((d) => !!d.code)
    .map((d) => ({ key: `prop:${d.code}`, label: `${d.label ?? d.code} (${d.code})`, group: d.category ?? t.noCategory,
      type: typeOf(d.dataType), property: d.code!, listValues: d.listValues?.length ? d.listValues : undefined }))
    .sort((a, b) => a.group.localeCompare(b.group) || a.label.localeCompare(b.label));
  return [...attrs, ...props];
}

let nextId = 1;
export function emptyGroup(mode: 'all' | 'any' = 'all'): Group {
  return { kind: 'group', id: nextId++, mode, items: [] };
}

export function newCondition(field: Field): Condition {
  return { kind: 'condition', id: nextId++, field: field.key, op: OPS_BY_TYPE[field.type][0], value: '', value2: '', ci: false };
}

// ------------------------------------------------------------------ edits by path (indexes from the root group)

function at(root: Group, path: number[]): QueryNode {
  let node: QueryNode = root;
  for (const i of path) {
    node = (node as Group).items[i];
  }
  return node;
}

/** Returns a copy of the tree with the node at `path` replaced by `fn(node)`; untouched branches are shared. */
export function update(root: Group, path: number[], fn: (node: QueryNode) => QueryNode | null): Group {
  if (path.length === 0) {
    return fn(root) as Group;
  }
  const [head, ...rest] = path;
  const items = [...root.items];
  if (rest.length === 0) {
    const replaced = fn(items[head]);
    if (replaced === null) {
      items.splice(head, 1);
    } else {
      items[head] = replaced;
    }
  } else {
    items[head] = update(items[head] as Group, rest, fn);
  }
  return { ...root, items };
}

export function addCondition(root: Group, groupPath: number[], field: Field): Group {
  return update(root, groupPath, (g) => ({ ...(g as Group), items: [...(g as Group).items, newCondition(field)] }));
}

export function addGroup(root: Group, groupPath: number[]): Group {
  if (groupPath.length >= MAX_GROUP_DEPTH) {
    return root;
  }
  return update(root, groupPath, (g) => ({ ...(g as Group), items: [...(g as Group).items, emptyGroup('any')] }));
}

export function removeAt(root: Group, path: number[]): Group {
  return path.length === 0 ? root : update(root, path, () => null);
}

export function patchCondition(root: Group, path: number[], patch: Partial<Condition>, fields: Field[]): Group {
  return update(root, path, (n) => {
    const c = { ...(n as Condition), ...patch };
    if (patch.field) {
      const f = fields.find((x) => x.key === patch.field);
      if (f && !OPS_BY_TYPE[f.type].includes(c.op)) {
        c.op = OPS_BY_TYPE[f.type][0];
      }
    }
    return c;
  });
}

export function setMode(root: Group, groupPath: number[], mode: 'all' | 'any'): Group {
  return update(root, groupPath, (g) => ({ ...(g as Group), mode }));
}

export function nodeAt(root: Group, path: number[]): QueryNode {
  return at(root, path);
}

// ------------------------------------------------------------------ to and from the filter language

function typed(raw: string, type: FieldType): unknown {
  const s = raw.trim();
  if (type === 'number') {
    const n = Number(s);
    return Number.isFinite(n) && s !== '' ? n : s;
  }
  if (type === 'boolean') {
    return s === 'true' ? true : s === 'false' ? false : s;
  }
  return s;
}

/** The problems to fix before the query can run, one per condition, numbered as on screen. */
export function problems(root: Group, fields: Field[]): string[] {
  const out: string[] = [];
  let n = 0;
  const walk = (g: Group) => {
    for (const item of g.items) {
      if (item.kind === 'group') {
        walk(item);
        continue;
      }
      n++;
      const f = fields.find((x) => x.key === item.field);
      if (!f) {
        out.push(STRINGS.queries.problemField(n));
      } else if (needsValue(item.op) && item.value.trim() === '') {
        out.push(STRINGS.queries.problemValue(n));
      } else if (isRange(item.op) && item.value2.trim() === '') {
        out.push(STRINGS.queries.problemUpper(n));
      }
    }
  };
  walk(root);
  return out;
}

export function toWhere(root: Group, fields: Field[]): JsonNode {
  const convert = (node: QueryNode): unknown => {
    if (node.kind === 'group') {
      return { [node.mode]: node.items.map(convert) };
    }
    const f = fields.find((x) => x.key === node.field)!;
    const target = f.attribute ? { attribute: f.attribute } : { property: f.property };
    const out: Record<string, unknown> = { ...target, op: node.op };
    if (isList(node.op)) {
      out['value'] = node.value.split(',').map((v) => typed(v, f.type)).filter((v) => v !== '');
    } else if (isRange(node.op)) {
      out['value'] = [typed(node.value, f.type), typed(node.value2, f.type)];
    } else if (needsValue(node.op)) {
      out['value'] = typed(node.value, f.type);
    }
    if (allowsCi(node.op) && node.ci) {
      out['ci'] = true;
    }
    return out;
  };
  return convert(root) as JsonNode;
}

/** A saved query's filter back into the builder. A bare array is "all of"; anything else that is not a group becomes one. */
export function fromWhere(where: unknown): Group {
  const text = (v: unknown): string => (v === null || v === undefined ? '' : String(v));
  const convert = (w: unknown): QueryNode | null => {
    if (Array.isArray(w)) {
      return { ...emptyGroup('all'), items: w.map(convert).filter((x): x is QueryNode => x !== null) };
    }
    if (!w || typeof w !== 'object') {
      return null;
    }
    const o = w as Record<string, unknown>;
    if (Array.isArray(o['all']) || Array.isArray(o['any'])) {
      const mode = Array.isArray(o['all']) ? 'all' : 'any';
      return { ...emptyGroup(mode), items: (o[mode] as unknown[]).map(convert).filter((x): x is QueryNode => x !== null) };
    }
    const key = o['attribute'] ? `attr:${o['attribute']}` : `prop:${o['property']}`;
    const value = o['value'];
    const op = String(o['op'] ?? '=');
    const c: Condition = { kind: 'condition', id: nextId++, field: key, op, value: '', value2: '', ci: o['ci'] === true };
    if (isList(op) && Array.isArray(value)) {
      c.value = value.map(text).join(', ');
    } else if (isRange(op) && Array.isArray(value)) {
      c.value = text(value[0]);
      c.value2 = text(value[1]);
    } else {
      c.value = text(value);
    }
    return c;
  };
  const g = convert(where);
  return g && g.kind === 'group' ? g : g ? { ...emptyGroup('all'), items: [g] } : emptyGroup('all');
}
