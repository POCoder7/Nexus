import type { CompareRow } from '../api/generated/models';
import { changeText, leftText, propertyOf, rightText, toneOf } from './compare-text';

/** QRY-02 wording (Phase 5 LLD §17.4): synthetic rows. */
describe('compare text', () => {
  const row = (r: Partial<CompareRow>): CompareRow => ({ nodeId: 'n', nodeName: 'Synthetic', ...r }) as CompareRow;

  it('words structure changes by their parents, with a tone for each', () => {
    const moved = row({ kind: 'structure', detail: { change: 'moved', leftParentId: 'a', leftParentName: 'North', rightParentId: 'b', rightParentName: 'South' } });
    expect(changeText(moved)).toBe('Moved');
    expect(toneOf(moved)).toBe('moved');
    expect(leftText(moved)).toBe('under North');
    expect(rightText(moved)).toBe('under South');
    const added = row({ kind: 'structure', detail: { change: 'added', rightParentId: 'b', rightParentName: 'South' } });
    expect([changeText(added), toneOf(added), leftText(added), rightText(added)]).toEqual(['Added', 'added', '', 'under South']);
    expect(toneOf(row({ kind: 'structure', detail: { change: 'shared_removed' } }))).toBe('removed');
    const reordered = row({ kind: 'structure', detail: { change: 'reordered', leftParentId: 'a', leftParentName: 'A', leftSortOrder: 1,
      rightParentId: 'a', rightParentName: 'A', rightSortOrder: 2 } });
    expect(rightText(reordered)).toBe('under A, position 2');
  });

  it('words property and name changes with both sides', () => {
    const p = row({ kind: 'property', detail: { propertyLabel: 'Currency', leftValue: 'EUR', rightValue: null,
      leftProvenance: 'inherited', rightProvenance: 'none' } });
    expect(propertyOf(p)).toBe('Currency');
    expect(leftText(p)).toBe('EUR (inherited)');
    expect(rightText(p)).toBe('(blank) (not set)');
    expect(toneOf(p)).toBe('modified');
    const r = row({ kind: 'rename', detail: { leftName: 'Old', rightName: 'New', rightDescription: 'Synthetic' } });
    expect([changeText(r), leftText(r), rightText(r)]).toEqual(['Renamed', 'Old', 'New — Synthetic']);
  });
});
