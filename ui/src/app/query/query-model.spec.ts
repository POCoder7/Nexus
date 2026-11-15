import type { PropertyDefinitionView } from '../api/generated/models';
import {
  Condition, Group, MAX_GROUP_DEPTH, addCondition, addGroup, emptyGroup, fieldsFrom, fromWhere, nodeAt, patchCondition, problems,
  toWhere,
} from './query-model';

/** The builder's model (QRY-01, Phase 5 LLD §17.5.1): fields, edits and the round trip to the filter language. Synthetic codes. */
describe('query model', () => {
  const defs: PropertyDefinitionView[] = [
    { code: 'SYN.Ccy', label: 'Currency', category: 'Finance', dataType: 'string', listValues: ['EUR', 'USD'] },
    { code: 'SYN.Amt', label: 'Amount', category: 'Finance', dataType: 'integer' },
    { code: 'SYN.Open', label: 'Opened', category: 'Legal', dataType: 'date' },
    { code: 'SYN.Flag', label: 'Flag', dataType: 'boolean' },
  ];
  const fields = fieldsFrom(defs);
  const field = (key: string) => fields.find((f) => f.key === key)!;
  const cond = (key: string, op: string, value = '', value2 = '', ci = false): Condition =>
    ({ kind: 'condition', id: 0, field: key, op, value, value2, ci });

  it('offers the node attributes first, then properties by category, each with its comparison type', () => {
    expect(fields.slice(0, 6).map((f) => f.key)).toEqual(['attr:name', 'attr:description', 'attr:kind', 'attr:level', 'attr:isLeaf', 'attr:isActive']);
    expect(fields.slice(6).map((f) => `${f.group}/${f.property}/${f.type}`))
      .toEqual(['Finance/SYN.Amt/number', 'Finance/SYN.Ccy/text', 'Legal/SYN.Open/date', 'Other/SYN.Flag/boolean']);
    expect(field('prop:SYN.Ccy').listValues).toEqual(['EUR', 'USD']);
  });

  it('writes nested groups with typed values: numbers, booleans, lists, ranges and ignore-case', () => {
    const root: Group = { ...emptyGroup('all'), items: [
      cond('prop:SYN.Amt', 'between', '5', '10'),
      cond('attr:isLeaf', '=', 'true'),
      { ...emptyGroup('any'), items: [cond('prop:SYN.Ccy', 'in', 'EUR, USD'), cond('attr:name', 'starts_with', 'Syn', '', true),
        cond('prop:SYN.Open', 'is_null')] },
    ] };
    expect(toWhere(root, fields)).toEqual({ all: [
      { property: 'SYN.Amt', op: 'between', value: [5, 10] },
      { attribute: 'isLeaf', op: '=', value: true },
      { any: [{ property: 'SYN.Ccy', op: 'in', value: ['EUR', 'USD'] }, { attribute: 'name', op: 'starts_with', value: 'Syn', ci: true },
        { property: 'SYN.Open', op: 'is_null' }] },
    ] });
  });

  it('reads a saved filter back into the same builder state, and a bare export filter as "all of"', () => {
    const where = { all: [{ property: 'SYN.Amt', op: 'gt', value: 3 }, { any: [{ attribute: 'name', op: 'contains', value: 'x', ci: true }] }] };
    expect(toWhere(fromWhere(where), fields)).toEqual(where);
    const bare = fromWhere([{ property: 'SYN.Ccy', op: '=', value: 'EUR' }]);
    expect(bare.mode).toBe('all');
    expect(toWhere(bare, fields)).toEqual({ all: [{ property: 'SYN.Ccy', op: '=', value: 'EUR' }] });
  });

  it('keeps the comparison when it suits the new field, and resets it when it does not', () => {
    let root = addCondition(emptyGroup(), [], field('attr:name'));
    root = patchCondition(root, [0], { op: 'contains' }, fields);
    root = patchCondition(root, [0], { field: 'prop:SYN.Ccy' }, fields);
    expect((nodeAt(root, [0]) as Condition).op).toBe('contains');
    root = patchCondition(root, [0], { field: 'prop:SYN.Amt' }, fields);
    expect((nodeAt(root, [0]) as Condition).op).toBe('=');
  });

  it('stops nesting groups where the server would refuse them (N2807)', () => {
    let root = emptyGroup();
    const path: number[] = [];
    for (let i = 0; i < MAX_GROUP_DEPTH + 2; i++) {
      root = addGroup(root, path);
      if ((nodeAt(root, path) as Group).items.length > 0) path.push(0);
    }
    expect(path.length).toBe(MAX_GROUP_DEPTH);
  });

  it('lists what to fix before running, by condition number', () => {
    const root: Group = { ...emptyGroup(), items: [cond('prop:SYN.Amt', '='), cond('prop:SYN.Amt', 'between', '1'), cond('attr:isLeaf', 'not_null')] };
    expect(problems(root, fields)).toEqual(['Condition 1: enter a value.', 'Condition 2: enter the upper bound.']);
  });
});
