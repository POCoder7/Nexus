-- pgTAP: the workflow ↔ mdm bridge (Phase 2 increment 2-6): governed_by_workflow, decider attribution after a split
-- (D-06), clearance and Phase 1 apply, enrichment items (ADR-023), requires_workflow (B-3). Synthetic data only.
BEGIN;
SELECT plan(16);

-- Fixture -----------------------------------------------------------------------------------------------------------
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-000000001701', 'g_steward',   'Steward',   'human'),
  ('00000000-0000-0000-0000-000000001702', 'g_committer', 'Committer', 'human'),
  ('00000000-0000-0000-0000-000000001703', 'g_rejecter',  'Rejecter',  'human'),
  ('00000000-0000-0000-0000-000000001704', 'g_enricher',  'Enricher',  'human'),
  ('00000000-0000-0000-0000-000000001705', 'g_outsider',  'Outsider',  'human'),
  ('00000000-0000-0000-0000-000000001706', 'g_approver',  'Approver',  'human');
INSERT INTO mdm.version (version_id, version_name, business_as_of) VALUES ('00000000-0000-0000-0000-000000001711', 'G2_V', current_date);
INSERT INTO mdm.node (node_id, node_kind) VALUES ('00000000-0000-0000-0000-000000001721', 'structural'), ('00000000-0000-0000-0000-000000001722', 'legal_entity');
INSERT INTO mdm.node_attr (node_id, node_name, valid_period) VALUES
  ('00000000-0000-0000-0000-000000001721', 'G2 top', daterange('2020-01-01', NULL)), ('00000000-0000-0000-0000-000000001722', 'G2 leaf', daterange('2020-01-01', NULL));
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id, requires_workflow) VALUES
  ('00000000-0000-0000-0000-000000001731', 'G2_FREE',     'Free',     '00000000-0000-0000-0000-000000001721', false),
  ('00000000-0000-0000-0000-000000001732', 'G2_GOVERNED', 'Governed', '00000000-0000-0000-0000-000000001721', true);
INSERT INTO mdm.property_definition (property_id, property_code, label, data_type, scope) VALUES
  ('00000000-0000-0000-0000-000000001741', 'G2.Note', 'Note', 'string', 'global');

CREATE FUNCTION pg_temp.cr(p_id uuid, p_items int) RETURNS void LANGUAGE sql AS $$
  INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind)
  VALUES (p_id, '00000000-0000-0000-0000-000000001711', 'G2 ' || p_id, '00000000-0000-0000-0000-000000001701', 'human');
  INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, property_id, payload)
  SELECT p_id, s, 'set_property', '00000000-0000-0000-0000-000000001731', '00000000-0000-0000-0000-000000001722',
         '00000000-0000-0000-0000-000000001741', jsonb_build_object('value', 'v' || s)
  FROM generate_series(1, p_items) s;
$$;
CREATE FUNCTION pg_temp.item(p_cr uuid, p_seq int) RETURNS uuid LANGUAGE sql AS $$
  SELECT change_item_id FROM mdm.change_item WHERE change_request_id = p_cr AND seq = p_seq
$$;
-- a minimal model, only for the instance rows (the bridge does not depend on the model's shape)
INSERT INTO wf.workflow_model (model_id, model_code, label) VALUES ('00000000-0000-0000-0000-000000001751', 'G2_PLAIN', 'Plain');

-- governed_by_workflow, and a split: root committed, child rejected later by someone else (D-06) -------------------
SELECT pg_temp.cr('00000000-0000-0000-0000-000000001761', 2);
INSERT INTO wf.workflow_instance (instance_id, change_request_id, model_id, status, submitted_by, submitted_at) VALUES
  ('00000000-0000-0000-0000-000000001771', '00000000-0000-0000-0000-000000001761', '00000000-0000-0000-0000-000000001751', 'in_flight', '00000000-0000-0000-0000-000000001701', now());
SELECT is((SELECT status::text || '/' || governed_by_workflow FROM mdm.change_request WHERE change_request_id = '00000000-0000-0000-0000-000000001761'),
  'in_review/true', 'Starting a workflow instance marks the request as governed and in review');
INSERT INTO wf.workflow_instance (instance_id, change_request_id, model_id, parent_instance_id, status, submitted_by, submitted_at) VALUES
  ('00000000-0000-0000-0000-000000001772', '00000000-0000-0000-0000-000000001761', '00000000-0000-0000-0000-000000001751',
   '00000000-0000-0000-0000-000000001771', 'in_flight', '00000000-0000-0000-0000-000000001701', now());
INSERT INTO wf.instance_item VALUES
  (pg_temp.item('00000000-0000-0000-0000-000000001761', 1), '00000000-0000-0000-0000-000000001771'),
  (pg_temp.item('00000000-0000-0000-0000-000000001761', 2), '00000000-0000-0000-0000-000000001772');
INSERT INTO wf.instance_action (instance_id, actor_id, actor_kind, action, occurred_at) VALUES
  ('00000000-0000-0000-0000-000000001771', '00000000-0000-0000-0000-000000001702', 'human', 'commit', now() - interval '1 minute'),
  ('00000000-0000-0000-0000-000000001772', '00000000-0000-0000-0000-000000001703', 'human', 'reject', now());
UPDATE wf.workflow_instance SET status = 'rejected', closed_at = now() WHERE instance_id = '00000000-0000-0000-0000-000000001772';
UPDATE wf.workflow_instance SET status = 'committed', closed_at = now() WHERE instance_id = '00000000-0000-0000-0000-000000001771';

SELECT is((SELECT status::text || '/' || decided_by || '/' || decision_basis FROM mdm.change_request
           WHERE change_request_id = '00000000-0000-0000-0000-000000001761'),
  'approved/00000000-0000-0000-0000-000000001702/human_review',
  'After a split the approved request is decided by the committer, not by the later rejecter of the other branch');
SELECT is((SELECT array_agg(change_item_id) FROM mdm.change_item_clearance
           WHERE change_item_id IN (SELECT change_item_id FROM mdm.change_item WHERE change_request_id = '00000000-0000-0000-0000-000000001761')),
  ARRAY[pg_temp.item('00000000-0000-0000-0000-000000001761', 1)], 'Only the committed branch''s items are cleared');
SELECT is((SELECT array_agg(i.seq) FROM mdm.apply_items_of((SELECT cr FROM mdm.change_request cr WHERE change_request_id = '00000000-0000-0000-0000-000000001761')) i),
  ARRAY[1], 'Phase 1 apply would write only the cleared item');

-- Rejection attribution ---------------------------------------------------------------------------------------------
SELECT pg_temp.cr('00000000-0000-0000-0000-000000001762', 1);
INSERT INTO wf.workflow_instance (instance_id, change_request_id, model_id, status, submitted_by, submitted_at) VALUES
  ('00000000-0000-0000-0000-000000001773', '00000000-0000-0000-0000-000000001762', '00000000-0000-0000-0000-000000001751', 'in_flight', '00000000-0000-0000-0000-000000001701', now());
INSERT INTO wf.instance_action (instance_id, actor_id, actor_kind, action) VALUES
  ('00000000-0000-0000-0000-000000001773', '00000000-0000-0000-0000-000000001703', 'human', 'reject');
UPDATE wf.workflow_instance SET status = 'rejected', closed_at = now() WHERE instance_id = '00000000-0000-0000-0000-000000001773';
SELECT is((SELECT status::text || '/' || decided_by FROM mdm.change_request WHERE change_request_id = '00000000-0000-0000-0000-000000001762'),
  'rejected/00000000-0000-0000-0000-000000001703', 'A rejected request is decided by the human who rejected it');

-- requires_workflow (B-3): no core-mode decision on a governed hierarchy ----------------------------------------------
INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind)
VALUES ('00000000-0000-0000-0000-000000001763', '00000000-0000-0000-0000-000000001711', 'G2 core', '00000000-0000-0000-0000-000000001701', 'human');
INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, property_id, payload)
VALUES ('00000000-0000-0000-0000-000000001763', 1, 'set_property', '00000000-0000-0000-0000-000000001732', '00000000-0000-0000-0000-000000001722',
        '00000000-0000-0000-0000-000000001741', '{"value": "x"}');
UPDATE mdm.change_request SET status = 'submitted' WHERE change_request_id = '00000000-0000-0000-0000-000000001763';
SET LOCAL ROLE nexus_api;
SELECT throws_ok($$SELECT mdm.decide_change_request('00000000-0000-0000-0000-000000001763', '00000000-0000-0000-0000-000000001706', 'approve', NULL)$$,
  'N2107', NULL, 'A hierarchy that requires a workflow cannot be changed by a core-mode decision');
RESET ROLE;

-- Enrichment items (ADR-023) ----------------------------------------------------------------------------------------
INSERT INTO wf.user_group (group_id, group_code, name) VALUES
  ('00000000-0000-0000-0000-000000001781', 'G2_ENRICHERS', 'Enrichers'), ('00000000-0000-0000-0000-000000001782', 'G2_COMMITTERS', 'Committers');
INSERT INTO wf.user_group_member (group_id, user_id) VALUES
  ('00000000-0000-0000-0000-000000001781', '00000000-0000-0000-0000-000000001704'), ('00000000-0000-0000-0000-000000001782', '00000000-0000-0000-0000-000000001702');
INSERT INTO wf.workflow_task (task_id, task_code, label, allowed_actions) VALUES
  ('00000000-0000-0000-0000-000000001791', 'G2_SUBMIT', 'Submit', '{set_property}'),
  ('00000000-0000-0000-0000-000000001792', 'G2_ENRICH', 'Enrich', '{set_property}');
INSERT INTO wf.task_property (task_id, property_id) VALUES ('00000000-0000-0000-0000-000000001792', '00000000-0000-0000-0000-000000001741');
INSERT INTO wf.workflow_model (model_id, model_code, label) VALUES ('00000000-0000-0000-0000-000000001752', 'G2_ENRICH', 'Enrich');
INSERT INTO wf.workflow_stage (stage_id, model_id, seq, stage_type, label, task_id) VALUES
  ('00000000-0000-0000-0000-0000000017a1', '00000000-0000-0000-0000-000000001752', 1, 'submit', 'Submit', NULL),
  ('00000000-0000-0000-0000-0000000017a2', '00000000-0000-0000-0000-000000001752', 2, 'enrich', 'Enrich', '00000000-0000-0000-0000-000000001792'),
  ('00000000-0000-0000-0000-0000000017a3', '00000000-0000-0000-0000-000000001752', 3, 'commit', 'Commit', NULL);
INSERT INTO wf.submit_task VALUES ('00000000-0000-0000-0000-000000001752', '00000000-0000-0000-0000-000000001791');
INSERT INTO wf.stage_group (stage_id, group_id) VALUES
  ('00000000-0000-0000-0000-0000000017a2', '00000000-0000-0000-0000-000000001781'), ('00000000-0000-0000-0000-0000000017a3', '00000000-0000-0000-0000-000000001782');
UPDATE wf.workflow_model SET status = 'active' WHERE model_id = '00000000-0000-0000-0000-000000001752';
SELECT pg_temp.cr('00000000-0000-0000-0000-000000001764', 1);
SELECT wf.start_instance('00000000-0000-0000-0000-000000001764', 'G2_ENRICH', '00000000-0000-0000-0000-000000001701');
UPDATE wf.instance_stage SET status = 'active', started_at = now()
WHERE stage_id = '00000000-0000-0000-0000-0000000017a2'
  AND instance_id = (SELECT instance_id FROM wf.workflow_instance WHERE change_request_id = '00000000-0000-0000-0000-000000001764');
UPDATE wf.workflow_instance SET current_seq = 2 WHERE change_request_id = '00000000-0000-0000-0000-000000001764';
CREATE TEMP TABLE e AS SELECT ist.instance_stage_id AS stage,
       (SELECT row_version FROM mdm.change_request WHERE change_request_id = '00000000-0000-0000-0000-000000001764') AS version_before
FROM wf.instance_stage ist WHERE ist.stage_id = '00000000-0000-0000-0000-0000000017a2'
  AND ist.instance_id = (SELECT instance_id FROM wf.workflow_instance WHERE change_request_id = '00000000-0000-0000-0000-000000001764');
GRANT SELECT ON e TO nexus_api, nexus_wf;

SET LOCAL ROLE nexus_api;
SELECT lives_ok($$SELECT wf_bridge.add_enrichment_item((SELECT stage FROM e), '00000000-0000-0000-0000-000000001704', 'set_property',
                   '00000000-0000-0000-0000-000000001731', '00000000-0000-0000-0000-000000001722', NULL, '00000000-0000-0000-0000-000000001741',
                   '{"value": "enriched"}')$$, 'An enricher adds an item while the request is in review');
SELECT throws_ok($$SELECT wf_bridge.add_enrichment_item((SELECT stage FROM e), '00000000-0000-0000-0000-000000001704', 'move_node',
                   '00000000-0000-0000-0000-000000001731', '00000000-0000-0000-0000-000000001722', '00000000-0000-0000-0000-000000001721', NULL, '{}')$$,
  'N1013', NULL, 'An item the stage''s task does not allow is refused');
SELECT throws_ok($$SELECT wf_bridge.add_enrichment_item((SELECT stage FROM e), '00000000-0000-0000-0000-000000001705', 'set_property',
                   '00000000-0000-0000-0000-000000001731', '00000000-0000-0000-0000-000000001722', NULL, '00000000-0000-0000-0000-000000001741', '{"value": "x"}')$$,
  'N1016', NULL, 'Someone who cannot act on the stage cannot enrich');
SELECT throws_ok($$INSERT INTO mdm.change_item (change_request_id, seq, action, node_id, property_id, payload)
                   VALUES ('00000000-0000-0000-0000-000000001764', 9, 'set_property', '00000000-0000-0000-0000-000000001722',
                           '00000000-0000-0000-0000-000000001741', '{"value": "sneaky"}')$$,
  'N2102', NULL, 'The API still cannot add items to a request in review directly');
RESET ROLE;
SET LOCAL ROLE nexus_wf;
SELECT throws_ok($$INSERT INTO mdm.change_item (change_request_id, seq, action, node_id, property_id, payload)
                   VALUES ('00000000-0000-0000-0000-000000001764', 9, 'set_property', '00000000-0000-0000-0000-000000001722',
                           '00000000-0000-0000-0000-000000001741', '{"value": "sneaky"}')$$,
  '42501', NULL, 'The workflow role cannot write mdm (layer separation)');
RESET ROLE;

SELECT is((SELECT string_agg(ci.seq::text || ':' || (ii.instance_id IS NOT NULL), ',' ORDER BY ci.seq) FROM mdm.change_item ci
           LEFT JOIN wf.instance_item ii ON ii.change_item_id = ci.change_item_id
           WHERE ci.change_request_id = '00000000-0000-0000-0000-000000001764'),
  '1:true,2:true', 'The enrichment item is the next item and joins the instance; the refused one left nothing');
SELECT ok((SELECT row_version FROM mdm.change_request WHERE change_request_id = '00000000-0000-0000-0000-000000001764') > (SELECT version_before FROM e),
  'Adding an item still bumps the request''s row version');
SELECT is((SELECT count(*)::int FROM wf.instance_action WHERE instance_stage_id = (SELECT stage FROM e) AND action = 'enrich'
             AND actor_id = '00000000-0000-0000-0000-000000001704'),
  1, 'The enrichment is in the request history');
SELECT is((SELECT status::text FROM mdm.change_request WHERE change_request_id = '00000000-0000-0000-0000-000000001764'),
  'in_review', 'The request stays in review');
SELECT throws_ok($$DELETE FROM mdm.change_item WHERE change_request_id = '00000000-0000-0000-0000-000000001764' AND seq = 2$$,
  'N2102', NULL, 'Items of a request in review cannot be deleted, even by the owner');

SELECT * FROM finish();
ROLLBACK;
