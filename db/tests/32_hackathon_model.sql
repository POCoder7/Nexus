-- pgTAP: model changes for the hackathon CSV load (ADR-046, Phase 4 LLD §17). H-1: node display names and hierarchy
-- descriptions. Synthetic data only.
BEGIN;
SELECT plan(8);

-- Fixture ------------------------------------------------------------------------------------------------------
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-000000003201', 'x_steward',  'Steward',  'human'),
  ('00000000-0000-0000-0000-000000003202', 'x_approver', 'Approver', 'human');
INSERT INTO mdm.version (version_id, version_name, business_as_of)
VALUES ('00000000-0000-0000-0000-000000003211', 'X_VERSION', current_date);
INSERT INTO mdm.node (node_id, node_kind) VALUES
  ('00000000-0000-0000-0000-000000003221', 'structural'),   -- top of X_H
  ('00000000-0000-0000-0000-000000003222', 'structural'),   -- added under the top with a display name
  ('00000000-0000-0000-0000-000000003223', 'structural'),   -- added with the same display name
  ('00000000-0000-0000-0000-000000003224', 'structural');   -- top of the hierarchy added by add_hierarchy
INSERT INTO mdm.node_attr (node_id, node_name, display_name, allows_children, valid_period)
VALUES ('00000000-0000-0000-0000-000000003221', 'XTOP', 'X top', true, daterange('2020-01-01', NULL));
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id)
VALUES ('00000000-0000-0000-0000-000000003231', 'X_H', 'X hierarchy', '00000000-0000-0000-0000-000000003221');

-- One approved request per call, effective 2030-01-01, with one item (owner, setup only).
CREATE FUNCTION pg_temp.approved(p_id uuid, p_action text, p_h uuid, p_node uuid, p_parent uuid, p_payload jsonb)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind, effective_from)
  VALUES (p_id, '00000000-0000-0000-0000-000000003211', 'X ' || p_id, '00000000-0000-0000-0000-000000003201', 'human', '2030-01-01');
  INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, target_parent_id, payload)
  VALUES (p_id, 1, p_action::mdm.change_action, p_h, p_node, p_parent, p_payload);
  UPDATE mdm.change_request SET status = 'submitted' WHERE change_request_id = p_id;
  UPDATE mdm.change_request SET status = 'approved', decided_by = '00000000-0000-0000-0000-000000003202',
         decided_at = now(), decision_basis = 'human_review' WHERE change_request_id = p_id;
$$;
CREATE FUNCTION pg_temp.apply(p_id uuid) RETURNS int LANGUAGE plpgsql AS $$
DECLARE v int;
BEGIN
  SET LOCAL ROLE nexus_api;                                     -- applied through the API's privileges
  v := mdm.apply_change_request(p_id, '00000000-0000-0000-0000-000000003202');
  RESET ROLE;
  RETURN v;
END $$;
CREATE FUNCTION pg_temp.attr(p_node uuid, p_d date) RETURNS text LANGUAGE sql AS $$
  SELECT node_name || '/' || coalesce(display_name, '-') || '/' || coalesce(description, '-') FROM mdm.node_attr
  WHERE node_id = p_node AND valid_period @> p_d AND upper_inf(recorded_period)
$$;

-- Display name (D1) --------------------------------------------------------------------------------------------
SELECT pg_temp.approved('00000000-0000-0000-0000-000000003241', 'add_node', '00000000-0000-0000-0000-000000003231',
  '00000000-0000-0000-0000-000000003222', '00000000-0000-0000-0000-000000003221',
  '{"name": "10110", "displayName": "FP and A Group", "description": "Cost center", "isLeaf": true}');
SELECT cmp_ok(pg_temp.apply('00000000-0000-0000-0000-000000003241'), '>', 0, 'An add_node item with a display name applies');
SELECT is(pg_temp.attr('00000000-0000-0000-0000-000000003222', '2030-01-01'), '10110/FP and A Group/Cost center',
  'The code is the node name, the display name and description are kept');

SELECT pg_temp.approved('00000000-0000-0000-0000-000000003242', 'add_node', '00000000-0000-0000-0000-000000003231',
  '00000000-0000-0000-0000-000000003223', '00000000-0000-0000-0000-000000003221',
  '{"name": "10120", "displayName": "FP and A Group", "isLeaf": true}');
SELECT cmp_ok(pg_temp.apply('00000000-0000-0000-0000-000000003242'), '>', 0,
  'Display names need not be unique (only node_name is the business key)');

SELECT pg_temp.approved('00000000-0000-0000-0000-000000003243', 'update_node', '00000000-0000-0000-0000-000000003231',
  '00000000-0000-0000-0000-000000003222', NULL,
  '{"displayName": "FP and A Group HQ", "expected": {"name": "10110", "displayName": "FP and A Group", "description": "Cost center"}}');
SELECT cmp_ok(pg_temp.apply('00000000-0000-0000-0000-000000003243'), '>', 0, 'update_node changes the display name alone');
SELECT is(pg_temp.attr('00000000-0000-0000-0000-000000003222', '2031-01-01'), '10110/FP and A Group HQ/Cost center',
  '… the name and description carry over');

SELECT pg_temp.approved('00000000-0000-0000-0000-000000003244', 'update_node', '00000000-0000-0000-0000-000000003231',
  '00000000-0000-0000-0000-000000003222', NULL,
  '{"displayName": "Stale edit", "expected": {"name": "10110", "displayName": "FP and A Group"}}');
SELECT is(pg_temp.apply('00000000-0000-0000-0000-000000003244'), -1,
  'An update drafted against an old display name is refused as a stale base');

-- add_hierarchy: top node display name and hierarchy description (D1, D8) ---------------------------------------
SELECT pg_temp.approved('00000000-0000-0000-0000-000000003245', 'add_hierarchy', NULL, '00000000-0000-0000-0000-000000003224',
  NULL, '{"code": "X_NEW", "name": "X new", "description": "Alternate view", "topNode": {"nodeKind": "structural",
          "name": "XNEWT", "displayName": "X new top"}}');
SELECT cmp_ok(pg_temp.apply('00000000-0000-0000-0000-000000003245'), '>', 0, 'add_hierarchy applies');
SELECT is((SELECT h.description || ' / ' || pg_temp.attr(h.top_node_id, '2030-01-01') FROM mdm.hierarchy h
           WHERE h.hierarchy_code = 'X_NEW'),
  'Alternate view / XNEWT/X new top/-', 'The hierarchy keeps its description and the top node its display name');

SELECT * FROM finish();
ROLLBACK;
