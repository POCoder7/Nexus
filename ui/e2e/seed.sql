-- End-to-end seed for the Phase 3 Playwright journeys (SLICE-01 S1-R2 … S1-R7).
-- SYNTHETIC DATA ONLY: every name is invented and prefixed "E2E"; no client, account or personal data.
-- Runs as the database owner on a freshly migrated, throw-away database (ui/e2e/global-setup.ts), like the pgTAP
-- fixtures. It writes facts directly because the database is empty; everything the journeys do goes through the API.
\set ON_ERROR_STOP on
BEGIN;

-- Users ---------------------------------------------------------------------------------------------------------
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-00000000e001', 'e2e_admin',           'E2E Admin One',        'human'),
  ('00000000-0000-0000-0000-00000000e002', 'e2e_admin2',          'E2E Admin Two',        'human'),
  ('00000000-0000-0000-0000-00000000e003', 'e2e_steward',         'E2E Steward',          'human'),
  ('00000000-0000-0000-0000-00000000e004', 'e2e_approver',        'E2E Approver',         'human'),
  ('00000000-0000-0000-0000-00000000e005', 'e2e_committer',       'E2E Committer',        'human'),
  ('00000000-0000-0000-0000-00000000e006', 'e2e_policy',          'E2E Policy Admin',     'human'),
  ('00000000-0000-0000-0000-00000000e007', 'e2e_policy_approver', 'E2E Policy Approver',  'human'),
  ('00000000-0000-0000-0000-00000000e008', 'e2e_viewer',          'E2E Viewer',           'human'),
  ('00000000-0000-0000-0000-00000000e0ff', 'nexus_system',        'Nexus system',         'system_feed');

INSERT INTO mdm.version (version_name, business_as_of) VALUES ('E2E working', current_date);

-- Hierarchy E2E_H -------------------------------------------------------------------------------------------------
-- Top → North (with two leaves and a shared node), South (shares that node), a bulk parent with 450 leaves for
-- paging, and a chain nine levels deep for "search reveals a node 8 levels down".
CREATE TEMP TABLE e2e_node (id uuid PRIMARY KEY, name text, descr text, kind mdm.node_kind, limb boolean, parent uuid,
                            primary_link boolean DEFAULT true, sort numeric);

INSERT INTO e2e_node VALUES
  ('00000000-0000-0000-0000-00000000a000', 'E2E Group',             'Top of the synthetic group', 'structural',   true,  NULL, true, 1),
  ('00000000-0000-0000-0000-00000000a001', 'E2E Region North',      'Synthetic region',           'structural',   true,  '00000000-0000-0000-0000-00000000a000', true, 1),
  ('00000000-0000-0000-0000-00000000a002', 'E2E Region South',      'Synthetic region',           'structural',   true,  '00000000-0000-0000-0000-00000000a000', true, 2),
  ('00000000-0000-0000-0000-00000000a003', 'E2E Bulk Parent',       '450 synthetic leaves',       'structural',   true,  '00000000-0000-0000-0000-00000000a000', true, 3),
  ('00000000-0000-0000-0000-00000000a011', 'E2E North Leaf One',    'Synthetic entity',           'legal_entity', false, '00000000-0000-0000-0000-00000000a001', true, 1),
  ('00000000-0000-0000-0000-00000000a012', 'E2E North Leaf Two',    'Synthetic entity',           'legal_entity', false, '00000000-0000-0000-0000-00000000a001', true, 2),
  ('00000000-0000-0000-0000-00000000a013', 'E2E Shared Services',   'Placed under North and South', 'legal_entity', false, '00000000-0000-0000-0000-00000000a001', true, 3);

INSERT INTO e2e_node
SELECT ('00000000-0000-0000-0000-0000000b' || lpad(to_hex(g), 4, '0'))::uuid, 'E2E Bulk ' || lpad(g::text, 4, '0'),
       'Synthetic bulk leaf', 'legal_entity', false, '00000000-0000-0000-0000-00000000a003', true, g
FROM generate_series(1, 450) g;

INSERT INTO e2e_node
SELECT ('00000000-0000-0000-0000-0000000c' || lpad(to_hex(g), 4, '0'))::uuid,
       CASE WHEN g = 9 THEN 'E2E Deep Target' ELSE 'E2E Level ' || g END,
       'Synthetic chain', CASE WHEN g = 9 THEN 'legal_entity' ELSE 'structural' END::mdm.node_kind, g < 9,
       CASE WHEN g = 1 THEN '00000000-0000-0000-0000-00000000a000'::uuid
            ELSE ('00000000-0000-0000-0000-0000000c' || lpad(to_hex(g - 1), 4, '0'))::uuid END, true, 4
FROM generate_series(1, 9) g;

INSERT INTO mdm.node (node_id, node_kind) SELECT id, kind FROM e2e_node;
INSERT INTO mdm.node_attr (node_id, node_name, description, allows_children, valid_period)
SELECT id, name, descr, limb, daterange('2020-01-01', NULL) FROM e2e_node;

INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, purpose, top_node_id, allow_shared_nodes, requires_workflow, sort_seq)
VALUES ('E2E_H', 'E2E Legal Group', 'legal_consolidation', '00000000-0000-0000-0000-00000000a000', true, true, 1),
       ('E2E_MGMT', 'E2E Management View', 'management', '00000000-0000-0000-0000-00000000a000', false, false, 2);

INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, is_primary, sort_order, valid_period)
SELECT h.hierarchy_id, n.parent, n.id, n.primary_link, n.sort, daterange('2020-01-01', NULL)
FROM e2e_node n, mdm.hierarchy h
WHERE h.hierarchy_code = 'E2E_H' AND n.parent IS NOT NULL;

INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, is_primary, sort_order, valid_period)
SELECT hierarchy_id, '00000000-0000-0000-0000-00000000a002', '00000000-0000-0000-0000-00000000a013', false, 1,
       daterange('2020-01-01', NULL)
FROM mdm.hierarchy WHERE hierarchy_code = 'E2E_H';

-- Properties: stored on top and inherited below, a default, and one the add-leaf form requires ----------------------
INSERT INTO mdm.property_definition (property_code, label, category_code, data_type, scope, inheritance, default_value) VALUES
  ('E2E.Currency',   'Reporting currency', 'Finance', 'string', 'global', 'inherit_from_ancestor', NULL),
  ('E2E.Segment',    'Segment',            'Finance', 'string', 'global', 'none', '"Unassigned"'),
  ('E2E.CostCentre', 'Cost centre',        'Finance', 'string', 'global', 'none', NULL);
INSERT INTO mdm.property_list_value (property_id, list_value)
SELECT property_id, v FROM mdm.property_definition, (VALUES ('EUR'), ('GBP'), ('USD')) AS l(v) WHERE property_code = 'E2E.Currency';
INSERT INTO mdm.property_value (node_id, property_id, value, valid_period)
SELECT '00000000-0000-0000-0000-00000000a000', property_id, '"EUR"', daterange('2020-01-01', NULL)
FROM mdm.property_definition WHERE property_code = 'E2E.Currency';

-- Roles (ADR-022) ---------------------------------------------------------------------------------------------------
INSERT INTO mdm.user_role (user_id, role_code, hierarchy_id, granted_by, valid_period)
SELECT u.user_id, r.role, CASE WHEN r.scoped THEN h.hierarchy_id END,
       -- nobody grants their own role (maker-checker on grants)
       CASE WHEN r.login = 'e2e_admin' THEN '00000000-0000-0000-0000-00000000e002'::uuid
            ELSE '00000000-0000-0000-0000-00000000e001'::uuid END,
       daterange(current_date - 1, NULL)
FROM (VALUES ('e2e_steward', 'STEWARD', true), ('e2e_approver', 'APPROVER', true), ('e2e_committer', 'APPROVER', true),
             ('e2e_viewer', 'VIEWER', true), ('e2e_policy', 'POLICY_ADMIN', false), ('e2e_admin', 'WORKFLOW_ADMIN', false),
             ('e2e_admin2', 'WORKFLOW_ADMIN', false)) AS r(login, role, scoped)
JOIN mdm.app_user u ON u.login = r.login
CROSS JOIN (SELECT hierarchy_id FROM mdm.hierarchy WHERE hierarchy_code = 'E2E_H') h;
-- the management view is readable by the steward too (Home lists two hierarchies)
INSERT INTO mdm.user_role (user_id, role_code, hierarchy_id, granted_by, valid_period)
SELECT '00000000-0000-0000-0000-00000000e003', 'VIEWER', hierarchy_id, '00000000-0000-0000-0000-00000000e001', daterange(current_date - 1, NULL)
FROM mdm.hierarchy WHERE hierarchy_code = 'E2E_MGMT';

-- Workflow: Submit → Approve (separation of duties) → Commit ---------------------------------------------------------
INSERT INTO wf.user_group (group_code, name) VALUES ('E2E_APPROVERS', 'E2E approvers'), ('E2E_COMMITTERS', 'E2E committers');
INSERT INTO wf.user_group_member (group_id, user_id)
SELECT g.group_id, u.user_id FROM wf.user_group g JOIN mdm.app_user u
  ON (g.group_code, u.login) IN (('E2E_APPROVERS', 'e2e_approver'), ('E2E_COMMITTERS', 'e2e_committer'),
                                 ('POLICY_APPROVERS', 'e2e_policy_approver'));

INSERT INTO wf.workflow_task (task_code, label, allowed_actions) VALUES
  ('E2E_SUBMIT', 'Describe the new leaf', '{add_node,set_property}'),
  ('E2E_APPROVE', 'Approve the request', '{}');
INSERT INTO wf.task_property (task_id, property_id, is_required, sort_seq)
SELECT t.task_id, p.property_id, p.property_code = 'E2E.CostCentre', CASE p.property_code WHEN 'E2E.CostCentre' THEN 1 ELSE 2 END
FROM wf.workflow_task t, mdm.property_definition p
WHERE t.task_code = 'E2E_SUBMIT' AND p.property_code IN ('E2E.CostCentre', 'E2E.Segment');

INSERT INTO wf.workflow_model (model_id, model_code, label, created_by)
VALUES ('00000000-0000-0000-0000-00000000f001', 'ADD_LEAF', 'Add a leaf', '00000000-0000-0000-0000-00000000e001');
INSERT INTO wf.workflow_stage (model_id, seq, stage_type, label, task_id, separation_of_duties) VALUES
  ('00000000-0000-0000-0000-00000000f001', 1, 'submit',  'Submit',  NULL, false),
  ('00000000-0000-0000-0000-00000000f001', 2, 'approve', 'Approve', (SELECT task_id FROM wf.workflow_task WHERE task_code = 'E2E_APPROVE'), true),
  ('00000000-0000-0000-0000-00000000f001', 3, 'commit',  'Commit',  NULL, true);
INSERT INTO wf.submit_task SELECT '00000000-0000-0000-0000-00000000f001', task_id FROM wf.workflow_task WHERE task_code = 'E2E_SUBMIT';
INSERT INTO wf.stage_group (stage_id, group_id)
SELECT s.stage_id, g.group_id FROM wf.workflow_stage s JOIN wf.user_group g
  ON (s.seq = 2 AND g.group_code = 'E2E_APPROVERS') OR (s.seq = 3 AND g.group_code = 'E2E_COMMITTERS')
WHERE s.model_id = '00000000-0000-0000-0000-00000000f001';
-- activated by a second administrator (GOV-01)
UPDATE wf.workflow_model SET status = 'active', activated_by = '00000000-0000-0000-0000-00000000e002', activated_at = now()
WHERE model_id = '00000000-0000-0000-0000-00000000f001';

-- MAINTAIN: the model for every other steward change (edit details and properties, place, move, remove, delete, new
-- hierarchy), Phase 3 scope extension. Same approvers and committers; all E2E properties editable, none required.
INSERT INTO wf.workflow_task (task_code, label, allowed_actions) VALUES
  ('E2E_MAINTAIN', 'Describe the change',
   '{add_node,insert_node,move_node,remove_node,delete_node,update_node,add_hierarchy,set_property,clear_property}');
INSERT INTO wf.task_property (task_id, property_id, is_required, sort_seq)
SELECT t.task_id, p.property_id, false, row_number() OVER (ORDER BY p.property_code)
FROM wf.workflow_task t, mdm.property_definition p WHERE t.task_code = 'E2E_MAINTAIN' AND p.property_code LIKE 'E2E.%';
INSERT INTO wf.workflow_model (model_id, model_code, label, created_by)
VALUES ('00000000-0000-0000-0000-00000000f002', 'MAINTAIN', 'Maintain nodes and properties', '00000000-0000-0000-0000-00000000e001');
INSERT INTO wf.workflow_stage (model_id, seq, stage_type, label, task_id, separation_of_duties) VALUES
  ('00000000-0000-0000-0000-00000000f002', 1, 'submit',  'Submit',  NULL, false),
  ('00000000-0000-0000-0000-00000000f002', 2, 'approve', 'Approve', (SELECT task_id FROM wf.workflow_task WHERE task_code = 'E2E_APPROVE'), true),
  ('00000000-0000-0000-0000-00000000f002', 3, 'commit',  'Commit',  NULL, true);
INSERT INTO wf.submit_task SELECT '00000000-0000-0000-0000-00000000f002', task_id FROM wf.workflow_task WHERE task_code = 'E2E_MAINTAIN';
INSERT INTO wf.stage_group (stage_id, group_id)
SELECT s.stage_id, g.group_id FROM wf.workflow_stage s JOIN wf.user_group g
  ON (s.seq = 2 AND g.group_code = 'E2E_APPROVERS') OR (s.seq = 3 AND g.group_code = 'E2E_COMMITTERS')
WHERE s.model_id = '00000000-0000-0000-0000-00000000f002';
UPDATE wf.workflow_model SET status = 'active', activated_by = '00000000-0000-0000-0000-00000000e002', activated_at = now()
WHERE model_id = '00000000-0000-0000-0000-00000000f002';

-- An architect who may propose in every hierarchy (needed to create one, HIE-01)
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-00000000e009', 'e2e_architect', 'E2E Architect', 'human');
INSERT INTO mdm.user_role (user_id, role_code, hierarchy_id, granted_by, valid_period)
VALUES ('00000000-0000-0000-0000-00000000e009', 'STEWARD', NULL, '00000000-0000-0000-0000-00000000e001', daterange(current_date - 1, NULL));

-- Deciding a request that creates a hierarchy needs the decide right on every hierarchy (a new hierarchy is in none yet)
INSERT INTO mdm.user_role (user_id, role_code, hierarchy_id, granted_by, valid_period)
SELECT user_id, 'APPROVER', NULL, '00000000-0000-0000-0000-00000000e001', daterange(current_date - 1, NULL)
FROM mdm.app_user WHERE login IN ('e2e_approver', 'e2e_committer');

-- A property outside the Finance category, and a steward whose grant covers Finance properties only (ADR-036)
INSERT INTO mdm.property_definition (property_code, label, category_code, data_type, scope)
VALUES ('E2E.LegalForm', 'Legal form', 'Legal', 'string', 'global');
INSERT INTO wf.task_property (task_id, property_id, is_required, sort_seq)
SELECT t.task_id, p.property_id, false, 99 FROM wf.workflow_task t, mdm.property_definition p
WHERE t.task_code = 'E2E_MAINTAIN' AND p.property_code = 'E2E.LegalForm';
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-00000000e010', 'e2e_finance', 'E2E Finance Steward', 'human');
INSERT INTO mdm.user_role (user_id, role_code, hierarchy_id, granted_by, valid_period, category_codes)
SELECT '00000000-0000-0000-0000-00000000e010', 'STEWARD', hierarchy_id, '00000000-0000-0000-0000-00000000e001',
       daterange(current_date - 1, NULL), '{Finance}'
FROM mdm.hierarchy WHERE hierarchy_code = 'E2E_H';

-- Direct ownership between synthetic entities (NEW-02 view): Leaf One is owned 60/40 and holds 75% of Bulk 0001
INSERT INTO mdm.ownership_edge (owner_node_id, owned_node_id, relation, economic_pct, voting_pct, source, valid_period) VALUES
  ('00000000-0000-0000-0000-00000000a013', '00000000-0000-0000-0000-00000000a011', 'shareholding', 60, 60, 'manual', daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-00000000a012', '00000000-0000-0000-0000-00000000a011', 'shareholding', 40, 40, 'manual', daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-00000000a011', '00000000-0000-0000-0000-0000000b0001', 'shareholding', 75, 75, 'company_registry', daterange('2020-01-01', NULL));

-- A shadow commit policy on the model: evaluated on every request, never commits on its own (OD-08) ----------------
INSERT INTO wf.commit_policy (policy_id, policy_code, description, rationale, mode, allowed_actions, owner_group_id, proposed_by)
SELECT '00000000-0000-0000-0000-00000000f101', 'E2E_SHADOW', 'Low-risk leaf additions', 'Synthetic shadow policy', 'shadow',
       '{add_node,set_property}', group_id, '00000000-0000-0000-0000-00000000e006'
FROM wf.user_group WHERE group_code = 'E2E_COMMITTERS';
INSERT INTO wf.policy_scope (policy_id, model_code) VALUES ('00000000-0000-0000-0000-00000000f101', 'ADD_LEAF');
SELECT wf.submit_commit_policy('00000000-0000-0000-0000-00000000f101', '00000000-0000-0000-0000-00000000e006');
SELECT wf.approve_commit_policy('00000000-0000-0000-0000-00000000f101', '00000000-0000-0000-0000-00000000e007', 'E2E seed');

-- Two version administrators (VER-01, VER-02): finalizing needs a second one (four eyes, V11 N1029) -----------------
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-00000000e011', 'e2e_vadmin', 'E2E Version Admin One', 'human'),
  ('00000000-0000-0000-0000-00000000e012', 'e2e_vadmin2', 'E2E Version Admin Two', 'human');
INSERT INTO mdm.user_role (user_id, role_code, hierarchy_id, granted_by, valid_period)
SELECT user_id, 'VERSION_ADMIN', NULL, '00000000-0000-0000-0000-00000000e001', daterange(current_date - 1, NULL)
FROM mdm.app_user WHERE login IN ('e2e_vadmin', 'e2e_vadmin2');

COMMIT;
