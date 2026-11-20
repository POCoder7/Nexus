import { Routes } from '@angular/router';
import { contextGuard, hierarchiesGuard, startPageGuard } from './core/guards';
import { NotFoundPage } from './core/not-found.page';

/** Routes (LLD §12.1). Every feature is a lazy chunk (UI_STANDARD §2); guards only navigate, the server authorises. */
export const routes: Routes = [
  { path: '', pathMatch: 'full', canActivate: [startPageGuard], children: [] },
  { path: 'home', canActivate: [contextGuard], title: 'Home · Nexus', loadComponent: () => import('./home/home.page').then((m) => m.HomePage) },
  { path: 'hierarchies', pathMatch: 'full', canActivate: [hierarchiesGuard], children: [] },
  {
    path: 'hierarchies/:code', canActivate: [contextGuard], title: 'Hierarchy · Nexus',
    loadComponent: () => import('./hierarchy/hierarchy-workspace.page').then((m) => m.HierarchyWorkspacePage),
  },
  // Phase 5 LLD §17.6.1: search across hierarchies (QRY-03)
  { path: 'search', canActivate: [contextGuard], title: 'Search · Nexus', loadComponent: () => import('./search/search.page').then((m) => m.SearchPage) },
  // Phase 5 LLD §17.4: compares and baselines (QRY-02, VER-04)
  { path: 'compare', canActivate: [contextGuard], title: 'Compare · Nexus', loadComponent: () => import('./compare/compare.page').then((m) => m.ComparePage) },
  // Phase 5 LLD §18.7: the transaction history (AUD-01)
  { path: 'audit', canActivate: [contextGuard], title: 'Audit · Nexus', loadComponent: () => import('./audit/audit.page').then((m) => m.AuditPage) },
  // Phase 5 LLD §20: every hierarchy in one tree under the version
  { path: 'browse', canActivate: [contextGuard], title: 'All hierarchies · Nexus', loadComponent: () => import('./hierarchy/all-hierarchies.page').then((m) => m.AllHierarchiesPage) },
  { path: 'worklist', canActivate: [contextGuard], title: 'Worklist · Nexus', loadComponent: () => import('./worklist/worklist.page').then((m) => m.WorklistPage) },
  {
    path: 'requests/:id/review', canActivate: [contextGuard], title: 'Review and submit · Nexus',
    loadComponent: () => import('./change-request/review-submit.page').then((m) => m.ReviewSubmitPage),
  },
  {
    path: 'requests/:id', canActivate: [contextGuard], title: 'Request · Nexus',
    loadComponent: () => import('./change-request/request.page').then((m) => m.RequestPage),
  },
  { path: 'sandboxes', canActivate: [contextGuard], title: 'Sandboxes · Nexus', loadComponent: () => import('./sandbox/sandboxes.page').then((m) => m.SandboxesPage) },
  {
    path: 'sandboxes/:id', canActivate: [contextGuard], title: 'Sandbox · Nexus',
    loadComponent: () => import('./sandbox/sandbox.page').then((m) => m.SandboxPage),
  },
  { path: 'queries', canActivate: [contextGuard], title: 'Queries · Nexus', loadComponent: () => import('./query/queries.page').then((m) => m.QueriesPage) },
  { path: 'versions', canActivate: [contextGuard], title: 'Versions · Nexus', loadComponent: () => import('./version/versions.page').then((m) => m.VersionsPage) },
  {
    path: 'admin/validation-rules', canActivate: [contextGuard], title: 'Validation rules · Nexus',
    loadComponent: () => import('./rules/validation-rules.page').then((m) => m.ValidationRulesPage),
  },
  { path: 'settings', canActivate: [contextGuard], title: 'Settings · Nexus', loadComponent: () => import('./settings/settings.page').then((m) => m.SettingsPage) },
  { path: '**', title: 'Not found · Nexus', component: NotFoundPage },
];
