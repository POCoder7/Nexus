import type { AuditEntry, RequestEvent } from '../api/generated/models';
import { changeText, eventDetail, eventText, kindText, valueText, whatText } from './audit-text';

/** AUD-01 and AUD-02 wording (Phase 5 LLD §18.3, §18.6); synthetic entries. */
describe('audit text', () => {
  const entry = (e: Partial<AuditEntry>): AuditEntry => ({ id: 'mdm:1', kind: 'stated', ...e }) as AuditEntry;

  it('words a property change as before → after, and a first value as an addition', () => {
    const changed = entry({ table: 'property_value', propertyLabel: 'Segment', before: { value: 'Retail' }, after: { value: 'Wholesale' } });
    expect(whatText(changed)).toBe('Segment');
    expect(changeText(changed)).toBe('Retail → Wholesale');
    expect(kindText(changed)).toBe('Changed');
    const added = entry({ table: 'property_value', propertyCode: 'SYN.Code', after: { value: null } });
    expect(whatText(added)).toBe('SYN.Code');
    expect(changeText(added)).toBe('(blank)');
    expect(kindText(added)).toBe('Added');
  });

  it('words a move by its parents and a rename by its changed fields', () => {
    const move = entry({ table: 'hierarchy_relationship', hierarchyCode: 'SYN_H',
      before: { parent_name: 'North', parent_node_id: 'n' }, after: { parent_name: 'South', parent_node_id: 's' } });
    expect(whatText(move)).toBe('Placement in SYN_H');
    expect(changeText(move)).toBe('under North → under South');
    const rename = entry({ table: 'node_attr', before: { node_name: 'Old', is_active: true }, after: { node_name: 'New', is_active: true },
      changedFields: ['node_name'] });
    expect(whatText(rename)).toBe('Node details');
    expect(changeText(rename)).toBe('Name: Old → New');
  });

  it('shows values as text, yes/no and (blank)', () => {
    expect(valueText('EUR')).toBe('EUR');
    expect(valueText(false)).toBe('no');
    expect(valueText(null)).toBe('(blank)');
    expect(valueText({ a: 1 })).toBe('{"a":1}');
  });

  it('words request events, with the override reason and failed checks as details', () => {
    const ev = (e: Partial<RequestEvent>): RequestEvent => ({ id: 'a:1', ...e }) as RequestEvent;
    expect(eventText(ev({ type: 'created', data: { title: 'Synthetic' } }))).toBe('Request created: Synthetic');
    expect(eventText(ev({ type: 'status', data: { from: 'submitted', to: 'approved', basis: 'approved_policy' } }))).toBe('Approved by policy');
    expect(eventText(ev({ type: 'status', data: { to: 'apply_failed', error: 'N2105 stale' } }))).toBe('Could not be applied: N2105 stale');
    expect(eventText(ev({ type: 'item_added', data: { item: { seq: 2, action: 'set_property', propertyCode: 'SYN.Seg', nodeName: 'Leaf' } } })))
      .toBe('Change 2 added: Set SYN.Seg (Leaf)');
    const override = ev({ type: 'workflow', data: { action: 'override', stage: 'Approve', decision: 'approve', comment: 'Approvers away' } });
    expect(eventText(override)).toBe('Overrode (approved) · Approve');
    expect(eventDetail(override)).toBe('Approvers away');
    expect(eventDetail(ev({ type: 'policy', data: { policy: 'SYN_P', outcome: 'routed_to_human', failedChecks: ['too_many_items'] } })))
      .toBe('Checks not met: too_many_items');
  });
});
