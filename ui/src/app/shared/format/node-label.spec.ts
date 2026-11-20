import { nodeLabel } from './node-label';

/** ADR-046 D1: a node with a display name reads "display name · code"; without one, its name alone. */
describe('nodeLabel', () => {
  it('shows the display name first and the code after it', () => {
    expect(nodeLabel({ name: '10110', displayName: 'FP and A Group' })).toBe('FP and A Group · 10110');
  });

  it('falls back to the name when there is no display name', () => {
    expect(nodeLabel({ name: 'Synthetic Holdings', displayName: null })).toBe('Synthetic Holdings');
    expect(nodeLabel({ name: 'Synthetic Holdings' })).toBe('Synthetic Holdings');
    expect(nodeLabel(null)).toBe('');
  });
});
