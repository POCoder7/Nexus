import { HttpErrorResponse, HttpHeaders } from '@angular/common/http';
import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { NexusApi } from '../api/nexus-api';
import type { SandboxView } from '../api/generated/models';
import { ContextStore } from '../core/context.store';
import { SandboxStore } from './sandbox.store';

/** The sandbox page's store (NEW-08, Phase 5 LLD §5, §12) against a fake API. Synthetic names only. */
describe('SandboxStore', () => {
  const open: SandboxView = { id: 'sb1', name: 'Synthetic sandbox', kind: 'sandbox', status: 'draft', ownerId: 'me', itemCount: 2 };

  function setup(overrides: Record<string, unknown> = {}, me = 'me', view: SandboxView = open) {
    const calls: string[] = [];
    let version = 3;
    const api = {
      me: async () => ({ actor: { userId: me } }),
      sandbox: async () => ({ body: view, etag: `"${version}"` }),
      sandboxItems: async () => ({ items: [{ id: 'i1', seq: 1 }, { id: 'i2', seq: 2 }] }),
      sandboxConflicts: async () => {
        calls.push('conflicts');
        return { items: [{ seq: 1, itemId: 'i1', field: 'name', expected: 'Old', actual: 'Other' }] };
      },
      rebaseSandbox: async (_id: string, etag: string) => {
        calls.push(`rebase ${etag}`);
        version++;
        return { body: { rowVersion: version, failures: [{ seq: 1, itemId: 'i1', errorCode: 'N3001', message: 'stale' }] }, etag: `"${version}"` };
      },
      deleteSandboxItem: async (_id: string, itemId: string, etag: string) => {
        calls.push(`delete ${itemId} ${etag}`);
        version++;
        return { body: { rowVersion: version, failures: [] }, etag: `"${version}"` };
      },
      sandboxes: async () => ({ items: [] }),
      ...overrides,
    };
    TestBed.configureTestingModule({ providers: [provideRouter([]), SandboxStore, { provide: NexusApi, useValue: api }] });
    const context = TestBed.inject(ContextStore);
    context.me.set({ actor: { userId: me } });
    return { store: TestBed.inject(SandboxStore), calls };
  }

  it('lists conflicts for the owner of an open sandbox', async () => {
    const { store, calls } = setup();
    await store.load('sb1');
    expect(store.canChange()).toBe(true);
    expect(store.conflicts().length).toBe(1);
    expect(calls).toContain('conflicts');
  });

  it('shows a viewer the sandbox read-only, without asking for its conflicts', async () => {
    const { store, calls } = setup({}, 'someone-else');
    await store.load('sb1');
    expect(store.canChange()).toBe(false);
    expect(store.conflicts()).toEqual([]);
    expect(calls).not.toContain('conflicts');
  });

  it('rebases with the latest ETag and keeps the items it still cannot apply', async () => {
    const { store, calls } = setup();
    await store.load('sb1');
    await store.rebase();
    expect(calls).toContain('rebase "3"');
    expect(store.failures().map((f) => f.errorCode)).toEqual(['N3001']);
  });

  it('removes a change with If-Match and reloads', async () => {
    const { store, calls } = setup();
    await store.load('sb1');
    await store.removeItem('i1');
    expect(calls).toContain('delete i1 "3"');
    expect(store.failures()).toEqual([]);
  });

  it('reloads the conflicts when submit is refused, and stays a sandbox', async () => {
    const refused = new HttpErrorResponse({
      status: 422, headers: new HttpHeaders({ 'Content-Type': 'application/problem+json' }),
      error: { status: 422, title: 'Rule violation', detail: 'Other changes were made', code: 'sandbox.has_conflicts' },
    });
    const { store, calls } = setup({ submitSandbox: async () => { throw refused; } });
    await store.load('sb1');
    calls.length = 0;
    await expect(store.submit()).rejects.toMatchObject({ status: 422 });
    expect(calls).toContain('conflicts');
    expect(store.sandbox()?.kind).toBe('sandbox');
  });
});
