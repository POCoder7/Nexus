import { HttpErrorResponse, HttpHeaders } from '@angular/common/http';
import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { NexusApi } from '../api/nexus-api';
import type { ItemCommand } from '../api/generated/models';
import { ContextStore } from '../core/context.store';
import { STRINGS } from '../core/strings';
import { TrayStore } from './tray.store';

/** LLD §6.1 partial failure and §7.3 ETag chaining, against a fake API. Synthetic names only. */
describe('TrayStore', () => {
  const leaf = {
    hierarchyCode: 'SYN_H', parentId: 'parent', parentName: 'Synthetic parent', name: 'Synthetic leaf', description: null,
    nodeKind: 'legal_entity', isLeaf: true, effectiveFrom: '2031-05-17',
    properties: [{ code: 'P.One', value: 'a' }, { code: 'P.Two', value: 'b' }],
  };

  function setup(fail: (cmd: ItemCommand, key: string) => HttpErrorResponse | null) {
    const sent: { etag: string; cmd: ItemCommand; key: string }[] = [];
    let version = 1;
    const api = {
      createRequest: async () => ({ body: { id: 'cr1', status: 'draft', effectiveFrom: '2031-05-17' }, etag: '"1"' }),
      addItem: async (_id: string, etag: string, cmd: ItemCommand, key: string) => {
        sent.push({ etag, cmd, key });
        const error = fail(cmd, key);
        if (error) throw error;
        version++;
        return { body: { id: `i${version}`, action: cmd.action, nodeId: cmd.nodeId ?? 'new-node' }, etag: `"${version}"` };
      },
      request: async () => ({ body: { id: 'cr1', status: 'draft' }, etag: '"9"' }),
      items: async () => ({ items: [{ id: 'reloaded' }] }),
      myRequests: async () => ({ items: [] }),
    };
    TestBed.configureTestingModule({ providers: [provideRouter([]), { provide: NexusApi, useValue: api }] });
    TestBed.inject(ContextStore).me.set({ workingVersion: 'Synthetic working' });
    return { tray: TestBed.inject(TrayStore), sent };
  }

  it('chains ETags: each item call sends the ETag the previous one returned', async () => {
    const { tray, sent } = setup(() => null);
    await tray.addLeaf(leaf);
    expect(sent.map((s) => s.etag)).toEqual(['"1"', '"2"', '"3"']);
    expect(sent[1].cmd.nodeId).toBe('new-node');   // properties are set on the new node
    expect(tray.count()).toBe(3);
  });

  it('keeps what was added when a later item fails, and retries it with the same key', async () => {
    let failOnce = true;
    const { tray, sent } = setup((cmd) => {
      if (cmd.propertyCode === 'P.Two' && failOnce) {
        failOnce = false;
        return new HttpErrorResponse({ status: 422, error: { detail: 'Synthetic refusal' } });
      }
      return null;
    });
    const result = await tray.addLeaf(leaf);
    expect(result.failed).toBe(1);
    expect(tray.count()).toBe(2);
    const failedKey = tray.failed()[0].key;
    await tray.retryFailed();
    expect(tray.failed()).toHaveLength(0);
    expect(tray.count()).toBe(3);
    expect(sent.at(-1)!.key).toBe(failedKey);   // idempotent retry
  });

  it('starts a MAINTAIN draft for a change that is not add-leaf', async () => {
    const created: unknown[] = [];
    const { tray } = setup(() => null);
    const api = TestBed.inject(NexusApi) as unknown as { createRequest: (b: unknown) => Promise<unknown> };
    const original = api.createRequest;
    api.createRequest = async (body: unknown) => {
      created.push(body);
      return original(body);
    };
    await tray.addChange({ action: 'update_node', hierarchyCode: 'SYN_H', nodeId: 'n1', payload: { name: 'Renamed' } },
      'Edit Synthetic node', '2031-05-17');
    expect(created).toEqual([expect.objectContaining({ workflowModelCode: 'MAINTAIN', title: 'Edit Synthetic node' })]);
    expect(tray.count()).toBe(1);
  });

  it('on 412 reloads the request and asks the user to repeat the action', async () => {
    const { tray } = setup((cmd) => (cmd.action === 'add_node'
      ? new HttpErrorResponse({ status: 412, headers: new HttpHeaders(), error: { detail: 'stale' } }) : null));
    await expect(tray.addLeaf(leaf)).rejects.toMatchObject({ status: 412, detail: STRINGS.errors.trayStale });
    expect(tray.items().map((i) => i.id)).toEqual(['reloaded']);
    expect(tray.currentEtag()).toBe('"9"');
  });
});
