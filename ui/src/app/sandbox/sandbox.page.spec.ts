import { HttpErrorResponse } from '@angular/common/http';
import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { NexusApi } from '../api/nexus-api';
import type { SandboxView } from '../api/generated/models';
import { ContextStore } from '../core/context.store';
import { SandboxPage } from './sandbox.page';

/** A refused submit lists the validation findings by rule, and marks the items they are about (owner, 2026-11-20). */
describe('SandboxPage', () => {
  const open: SandboxView = { id: 'sb1', name: 'Synthetic sandbox', kind: 'sandbox', status: 'draft', ownerId: 'me', itemCount: 1 };

  it('shows why a submit was refused: each error and warning with its rule, and the error on its item', async () => {
    const refused = new HttpErrorResponse({
      status: 422,
      error: {
        status: 422, title: 'Validation failed', detail: 'The sandbox has validation errors and stays a sandbox. Fix them and submit again.',
        code: 'change_request.validation_failed',
        errors: [{ ruleCode: 'VR04', nodeId: 'n1', message: 'Limb code Synthetic region is longer than 5 characters' }],
        warnings: [{ ruleCode: 'VR17', nodeId: 'n9', message: 'Synthetic currency differs' }],
      },
    });
    const api = {
      me: async () => ({ actor: { userId: 'me' } }),
      sandbox: async () => ({ body: open, etag: '"1"' }),
      sandboxItems: async () => ({ items: [{ id: 'i1', seq: 1, action: 'add_node', nodeId: 'n1',
        payload: { name: 'Synthetic region', displayName: 'Synthetic display', isLeaf: false }, before: {} }] }),
      sandboxConflicts: async () => ({ items: [] }),
      sandboxes: async () => ({ items: [] }),
      submitSandbox: async () => { throw refused; },
    };
    TestBed.configureTestingModule({ providers: [provideRouter([]), { provide: NexusApi, useValue: api }] });
    TestBed.inject(ContextStore).me.set({ actor: { userId: 'me' } });
    const fixture = TestBed.createComponent(SandboxPage);
    fixture.componentRef.setInput('id', 'sb1');
    await fixture.whenStable();
    await fixture.whenStable();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid=sandbox-findings]')).toBeNull();

    await (fixture.componentInstance as unknown as { submit: () => Promise<void> }).submit();
    await fixture.whenStable();
    expect(el.querySelector('[data-testid=sandbox-action-error]')?.textContent).toContain('validation errors');
    expect(el.querySelector('[data-testid=sandbox-finding-errors]')?.textContent)
      .toContain('VR04: Limb code Synthetic region is longer than 5 characters');
    expect(el.querySelector('[data-testid=sandbox-finding-warnings]')?.textContent).toContain('VR17: Synthetic currency differs');
    // the error is also shown on the item it is about, and the item reads "display name · code"
    const row = el.querySelector('nx-item-list')!.textContent!;
    expect(row).toContain('Limb code Synthetic region is longer than 5 characters');
    expect(row).toContain('Synthetic display · Synthetic region');
  });
});
