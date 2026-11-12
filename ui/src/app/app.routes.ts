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
  { path: 'worklist', canActivate: [contextGuard], title: 'Worklist · Nexus', loadComponent: () => import('./worklist/worklist.page').then((m) => m.WorklistPage) },
  {
    path: 'requests/:id/review', canActivate: [contextGuard], title: 'Review and submit · Nexus',
    loadComponent: () => import('./change-request/review-submit.page').then((m) => m.ReviewSubmitPage),
  },
  {
    path: 'requests/:id', canActivate: [contextGuard], title: 'Request · Nexus',
    loadComponent: () => import('./change-request/request.page').then((m) => m.RequestPage),
  },
  { path: 'settings', canActivate: [contextGuard], title: 'Settings · Nexus', loadComponent: () => import('./settings/settings.page').then((m) => m.SettingsPage) },
  { path: '**', title: 'Not found · Nexus', component: NotFoundPage },
];
