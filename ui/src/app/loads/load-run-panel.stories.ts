import { provideRouter } from '@angular/router';
import { applicationConfig, type Meta, type StoryObj } from '@storybook/angular-vite';
import type { IntakeResult, LoadFinding, LoadRunView } from '../api/generated/models';
import { LoadRunPanelComponent } from './load-run-panel.component';

/** Synthetic data only (CLAUDE.md rule 5). */
const staged: IntakeResult = {
  loadId: '00000000-0000-0000-0000-00000000f001', errors: 0, warnings: 0,
  staged: [{ fileName: 'hierarchies.csv', rows: 3 }, { fileName: 'nodes.csv', rows: 59 }, { fileName: 'relationships.csv', rows: 94 }],
  rejected: [],
  findings: [{ fileName: 'attribute_definitions.csv', lineNo: 16, severity: 'info', kind: 'skipped', detail: 'OC is derived: not loaded now' }],
};
const errors: LoadFinding[] = [
  { fileName: 'nodes.csv', lineNo: 61, severity: 'error', kind: 'row_width', detail: 'The row has 3 fields; the header has 5' },
  { fileName: 'relationships.csv', lineNo: 12, severity: 'error', kind: 'parent_is_leaf', detail: 'parent 10110 is a LEAF' },
  { fileName: 'users.csv', lineNo: 2, severity: 'info', kind: 'kept', detail: 'user u_admin already exists: it is kept' },
];
const plan = {
  targetVersion: 'Synthetic working', counts: { nodes: 59 }, skipped: ['attribute OC (derived)', 'rule VR00 (FEED)'],
  rules: { guardsRelabelled: 5, withExpression: 12, storedInactive: [] },
  steps: [{ step: 'versions', label: 'Create versions', count: 4 }, { step: 'hierarchies', label: 'One request per hierarchy for its top node', count: 3 },
    { step: 'nodes ORGNEXUS', label: 'Nodes, placements and values of ORGNEXUS', count: 45 }],
};
const prepared: LoadRunView = {
  id: staged.loadId, status: 'prepared', targetVersion: 'Synthetic working', preparedBy: 'u_admin', preparedAt: '2031-05-01T10:00:00Z',
  manifestSha256: '26625da0ed25fbf887726f8e5af9bc662ff5c0687d00bf9daa26ab4132a932d0', plan: plan as never, requests: [],
};
const requests = [
  { seq: 1, step: 'hierarchy ORGNEXUS', status: 'applied', changeRequestId: '00000000-0000-0000-0000-00000000f101' },
  { seq: 2, step: 'nodes ORGNEXUS', status: 'applied', changeRequestId: '00000000-0000-0000-0000-00000000f102' },
];

const meta: Meta<LoadRunPanelComponent> = {
  title: 'Custom/Data load',
  component: LoadRunPanelComponent,
  decorators: [applicationConfig({ providers: [provideRouter([])] })],
  args: { staged: null, findings: staged.findings, run: null, login: 'u_admin', busy: false },
};
export default meta;
type Story = StoryObj<LoadRunPanelComponent>;

export const CheckedReadyToPrepare: Story = { args: { staged } };
export const CheckedWithErrors: Story = { args: { findings: errors } };
export const WaitingForTheSecondAdmin: Story = { args: { run: prepared } };
export const ReadyToApproveByAnotherAdmin: Story = { args: { run: prepared, login: 'e2e_admin' } };
export const Applying: Story = { args: { run: { ...prepared, status: 'applying', approvedBy: 'e2e_admin', requests }, login: 'e2e_admin' } };
export const Applied: Story = {
  args: {
    login: 'e2e_admin',
    run: { ...prepared, status: 'applied', approvedBy: 'e2e_admin', requests,
      report: { reconciliation: { clean: true, valuesStaged: 184, valuesApplied: 184,
        hierarchies: [{ hierarchy: 'ORGNEXUS', placementsStaged: 46, placementsApplied: 46 }] },
        access: { items: 15, skipped: ['u_admin (ADMIN on every hierarchy): left to another ADMIN'] } } as never },
  },
};
export const Failed: Story = {
  args: { login: 'e2e_admin', run: { ...prepared, status: 'failed', approvedBy: 'e2e_admin', requests: requests.slice(0, 1),
    error: 'nodes ORGNEXUS failed validation: VR16: Active leaf 10110 has no GL_COMPANY' } },
};
