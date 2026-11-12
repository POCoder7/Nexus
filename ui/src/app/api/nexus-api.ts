import { HttpContext, HttpContextToken } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { Api } from './generated/api';
import * as fn from './generated/functions';
import type {
  ChangeRequestView, CreateRequest, DecisionResult, HomeView, Impact, InstanceView, ItemCommand, ItemView, MeView, NodeDetail,
  NodePath, PageChangeRequestView, PageChildNode, PageHierarchySummary, PageItemView, PageSearchHit, Preferences,
  PreferencesUpdate, SubmitForm, ValidationReport, WorklistPage,
} from './generated/models';
import { HierarchySummary } from './generated/models';

/** Idempotency-Key for one user action (ADR-015); the interceptor turns it into the header. */
export const IDEMPOTENCY_KEY = new HttpContextToken<string | null>(() => null);
/** Marks the client-error report itself, so a failing report is not reported again. */
export const SKIP_ERROR_REPORT = new HttpContextToken<boolean>(() => false);

/** Business date and optional recorded instant of a read (ADR-006, NEW-01). `asOf` undefined = the server's today. */
export interface Slice {
  asOf?: string;
  recordedAsOf?: string;
}

export interface Tagged<T> {
  body: T;
  etag: string;
}

/**
 * Thin facade over the generated client (P-27): screens and stores call these methods and never build URLs. Every type
 * comes from the generated models, so a contract change in `docs/api/openapi.json` fails the UI build.
 */
@Injectable({ providedIn: 'root' })
export class NexusApi {
  private readonly api = inject(Api);

  me(): Promise<MeView> {
    return this.api.invoke(fn.getMe);
  }

  updatePreferences(body: PreferencesUpdate): Promise<Preferences> {
    return this.api.invoke(fn.updatePreferences, { body });
  }

  home(): Promise<HomeView> {
    return this.api.invoke(fn.getHome);
  }

  hierarchies(slice: Slice = {}, cursor?: string): Promise<PageHierarchySummary> {
    return this.api.invoke(fn.listHierarchies, { ...slice, cursor, limit: 200 });
  }

  hierarchy(code: string, slice: Slice = {}): Promise<HierarchySummary> {
    return this.api.invoke(fn.getHierarchy, { code, ...slice });
  }

  children(code: string, parentId: string, slice: Slice, cursor: string | undefined, limit: number): Promise<PageChildNode> {
    return this.api.invoke(fn.listChildren, { code, parentId, ...slice, cursor, limit });
  }

  search(code: string, q: string, slice: Slice, limit = 20, cursor?: string): Promise<PageSearchHit> {
    return this.api.invoke(fn.searchHierarchy, { code, q, ...slice, limit, cursor });
  }

  path(code: string, nodeId: string, slice: Slice): Promise<NodePath> {
    return this.api.invoke(fn.getNodePath, { code, nodeId, ...slice });
  }

  impact(code: string, nodeId: string, slice: Slice): Promise<Impact> {
    return this.api.invoke(fn.getNodeImpact, { code, nodeId, ...slice });
  }

  node(nodeId: string, hierarchy: string | undefined, slice: Slice): Promise<NodeDetail> {
    return this.api.invoke(fn.getNode, { nodeId, hierarchy, ...slice });
  }

  submitForm(modelCode: string, hierarchy: string): Promise<SubmitForm> {
    return this.api.invoke(fn.getSubmitForm, { code: modelCode, hierarchy });
  }

  myRequests(status?: string, limit = 50): Promise<PageChangeRequestView> {
    return this.api.invoke(fn.listChangeRequests, { mine: true, status, limit });
  }

  async createRequest(body: CreateRequest, key: string): Promise<Tagged<ChangeRequestView>> {
    const r = await this.api.invoke$Response(fn.createChangeRequest, { body }, idem(key));
    return { body: r.body, etag: etagOf(r.headers.get('ETag')) };
  }

  async request(id: string): Promise<Tagged<ChangeRequestView>> {
    const r = await this.api.invoke$Response(fn.getChangeRequest, { id });
    return { body: r.body, etag: etagOf(r.headers.get('ETag')) };
  }

  async addItem(id: string, etag: string, body: ItemCommand, key: string): Promise<Tagged<ItemView>> {
    const r = await this.api.invoke$Response(fn.addChangeRequestItem, { id, 'If-Match': etag, body }, idem(key));
    return { body: r.body, etag: etagOf(r.headers.get('ETag')) };
  }

  items(id: string): Promise<PageItemView> {
    return this.api.invoke(fn.listChangeRequestItems, { id, limit: 1000 });
  }

  validate(id: string): Promise<ValidationReport> {
    return this.api.invoke(fn.validateChangeRequest, { id });
  }

  async submit(id: string, etag: string): Promise<Tagged<ChangeRequestView>> {
    const r = await this.api.invoke$Response(fn.submitChangeRequest, { id, 'If-Match': etag, body: {} });
    return { body: r.body as ChangeRequestView, etag: etagOf(r.headers.get('ETag')) };
  }

  instance(instanceId: string): Promise<InstanceView> {
    return this.api.invoke(fn.getWorkflowInstance, { instanceId });
  }

  decideStage(stageId: string, decision: 'approve' | 'reject', comment: string | undefined, key: string): Promise<DecisionResult> {
    return this.api.invoke(fn.decideStage, { stageId, body: { decision, comment } }, idem(key));
  }

  claim(stageId: string): Promise<void> {
    return this.api.invoke(fn.claimStage, { stageId, body: {} });
  }

  worklist(view: string, search: string | undefined, model: string | undefined, limit: number, cursor?: string): Promise<WorklistPage> {
    return this.api.invoke(fn.getWorklist, { view, search, model, limit, cursor });
  }

  reportClientError(status: number, type: string | null, correlationId: string | null, route: string): Promise<void> {
    return this.api.invoke(fn.reportClientError,
      { body: { status, type: type ?? undefined, correlationId: correlationId ?? undefined, route } },
      new HttpContext().set(SKIP_ERROR_REPORT, true));
  }
}

function idem(key: string): HttpContext {
  return new HttpContext().set(IDEMPOTENCY_KEY, key);
}

/** ETags are quoted row versions (ADR-015); kept as sent so they can be echoed in If-Match. */
function etagOf(header: string | null): string {
  return header ?? '';
}

/** A fresh key per user action. */
export function newIdempotencyKey(): string {
  return crypto.randomUUID();
}
