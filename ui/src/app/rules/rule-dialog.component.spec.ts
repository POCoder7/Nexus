import { editBody, RuleForm } from './rule-dialog.component';

/** ADR-046 D5: a database guard is only ever relabelled; a configured rule sends every field. */
describe('editBody', () => {
  const form: RuleForm = {
    name: ' NO_CYCLES ', description: 'No cycles', externalCode: ' VR07 ', severity: 'warning', mode: 'import', active: false,
    expression: 'SELECT 1',
  };

  it('sends only the labels for a guard', () => {
    expect(editBody({ code: 'NEXUS.HIERARCHY_CYCLE', enforcement: 'guard' }, form))
      .toEqual({ name: 'NO_CYCLES', description: 'No cycles', externalCode: 'VR07' });
  });

  it('sends severity, mode, state and check for a rule', () => {
    expect(editBody({ code: 'X.RULE', enforcement: 'rule' }, form)).toEqual({
      name: 'NO_CYCLES', description: 'No cycles', externalCode: 'VR07', severity: 'warning', mode: 'import', active: false,
      expression: 'SELECT 1',
    });
  });
});
