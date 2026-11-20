import type { LoadRunView } from '../api/generated/models';
import { STRINGS } from '../core/strings';

/** The plan the server stores on a prepared run (LoadRunService.plan). */
export interface LoadPlan {
  targetVersion: string;
  steps: { step: string; label: string; count: number }[];
  counts: Record<string, number>;
  rules: { guardsRelabelled: number; withExpression: number; storedInactive: string[] };
  skipped: string[];
}

/** The report of an applied or failed run (LoadRunService.run). */
export interface LoadReport {
  reconciliation?: { clean: boolean; valuesStaged: number; valuesApplied: number;
                     hierarchies: { hierarchy: string; placementsStaged: number; placementsApplied: number }[] };
  access?: { items: number; skipped: string[] };
  versions?: string[];
  versionTransitions?: string[];
}

export function planOf(run: LoadRunView | null | undefined): LoadPlan | null {
  return (run?.plan as unknown as LoadPlan) ?? null;
}

export function reportOf(run: LoadRunView | null | undefined): LoadReport | null {
  return (run?.report as unknown as LoadReport) ?? null;
}

/** What the person looking at a run may do next, and why not (UI_STANDARD: a disabled action says why). */
export interface LoadActions {
  approve: boolean;
  approveWhyNot: string | null;
  apply: boolean;
  applyWhyNot: string | null;
  cancel: boolean;
}

/**
 * ADR-046 (Phase 4 LLD §17.8.2): a second ADMIN approves the manifest, and the approver applies the load. The server
 * decides again; this only shows the buttons and their reasons.
 */
export function loadActions(run: LoadRunView | null | undefined, login: string | null | undefined): LoadActions {
  const t = STRINGS.loads;
  const status = run?.status;
  const preparer = !!login && login === run?.preparedBy;
  const approver = !!login && login === run?.approvedBy;
  return {
    approve: status === 'prepared' && !preparer,
    approveWhyNot: status === 'prepared' && preparer ? t.whyNot.ownLoad : null,
    apply: status === 'approved' && approver,
    applyWhyNot: status === 'approved' && !approver ? t.whyNot.notApprover(run?.approvedBy ?? '') : null,
    cancel: status === 'prepared' || status === 'approved',
  };
}
