import { loadActions } from './load-run.model';

/** ADR-046 (Phase 4 LLD §17.8.2): a second ADMIN approves; the approver applies; each refusal says why. */
describe('loadActions', () => {
  const prepared = { status: 'prepared', preparedBy: 'u_admin' };
  const approved = { status: 'approved', preparedBy: 'u_admin', approvedBy: 'e2e_admin' };

  it('lets another administrator approve, and tells the preparer why they cannot', () => {
    expect(loadActions(prepared, 'e2e_admin')).toMatchObject({ approve: true, approveWhyNot: null, cancel: true });
    const own = loadActions(prepared, 'u_admin');
    expect(own.approve).toBe(false);
    expect(own.approveWhyNot).toContain('A second administrator');
  });

  it('lets only the approver apply', () => {
    expect(loadActions(approved, 'e2e_admin')).toMatchObject({ apply: true, applyWhyNot: null });
    const other = loadActions(approved, 'u_admin');
    expect(other.apply).toBe(false);
    expect(other.applyWhyNot).toContain('e2e_admin');
  });

  it('offers nothing once the load is applying or done', () => {
    for (const status of ['applying', 'applied', 'failed', 'cancelled']) {
      expect(loadActions({ ...approved, status }, 'e2e_admin')).toEqual(
        { approve: false, approveWhyNot: null, apply: false, applyWhyNot: null, cancel: false });
    }
  });
});
