-- pgTAP: apply_change_request (Phase 1 LLD §7.1–§7.3, increment 1-8a): set-from-D, add_node, insert_node,
-- move_node, stale base, change events, all-or-nothing, traceability (D-29). Synthetic data only.
BEGIN;
SELECT plan(26);

-- Fixture ------------------------------------------------------------------------------------------------------
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-0000000009a1', 'g_steward',  'Steward',  'human'),
  ('00000000-0000-0000-0000-0000000009a2', 'g_approver', 'Approver', 'human');
INSERT INTO mdm.version (version_id, version_name, business_as_of)
VALUES ('00000000-0000-0000-0000-0000000009b1', 'G_VERSION', current_date);

INSERT INTO mdm.node (node_id, node_kind) VALUES
  ('00000000-0000-0000-0000-000000000901', 'structural'),   -- T  top of G_H1
  ('00000000-0000-0000-0000-000000000902', 'structural'),   -- A
  ('00000000-0000-0000-0000-000000000903', 'structural'),   -- B
  ('00000000-0000-0000-0000-000000000904', 'legal_entity'), -- X  leaf under A
  ('00000000-0000-0000-0000-000000000905', 'structural'),   -- C  under A
  ('00000000-0000-0000-0000-000000000906', 'legal_entity'), -- L  leaf under B
  ('00000000-0000-0000-0000-000000000907', 'structural'),   -- T2 top of G_H2 (no shared nodes)
  ('00000000-0000-0000-0000-000000000908', 'structural'),   -- P2 under T2
  ('00000000-0000-0000-0000-000000000909', 'structural'),   -- C2 under T2
  ('00000000-0000-0000-0000-000000000910', 'legal_entity'), -- N1 new
  ('00000000-0000-0000-0000-000000000911', 'legal_entity'), -- N2 new (all-or-nothing)
  ('00000000-0000-0000-0000-000000000912', 'legal_entity'); -- N3 new (under a leaf)
INSERT INTO mdm.node_attr (node_id, node_name, allows_children, valid_period)
SELECT n::uuid, name, kids, daterange('2020-01-01', NULL) FROM (VALUES
  ('00000000-0000-0000-0000-000000000901', 'G top', true),  ('00000000-0000-0000-0000-000000000902', 'G A', true),
  ('00000000-0000-0000-0000-000000000903', 'G B', true),    ('00000000-0000-0000-0000-000000000904', 'G X', false),
  ('00000000-0000-0000-0000-000000000905', 'G C', true),    ('00000000-0000-0000-0000-000000000906', 'G L', false),
  ('00000000-0000-0000-0000-000000000907', 'G top 2', true),('00000000-0000-0000-0000-000000000908', 'G P2', true),
  ('00000000-0000-0000-0000-000000000909', 'G C2', true)) AS v(n, name, kids);
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id, allow_shared_nodes) VALUES
  ('00000000-0000-0000-0000-0000000009c1', 'G_H1', 'G one', '00000000-0000-0000-0000-000000000901', true),
  ('00000000-0000-0000-0000-0000000009c2', 'G_H2', 'G two', '00000000-0000-0000-0000-000000000907', false);
INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, valid_period)
SELECT h::uuid, p::uuid, c::uuid, daterange('2020-01-01', NULL) FROM (VALUES
  ('00000000-0000-0000-0000-0000000009c1', '00000000-0000-0000-0000-000000000901', '00000000-0000-0000-0000-000000000902'),
  ('00000000-0000-0000-0000-0000000009c1', '00000000-0000-0000-0000-000000000901', '00000000-0000-0000-0000-000000000903'),
  ('00000000-0000-0000-0000-0000000009c1', '00000000-0000-0000-0000-000000000902', '00000000-0000-0000-0000-000000000904'),
  ('00000000-0000-0000-0000-0000000009c1', '00000000-0000-0000-0000-000000000902', '00000000-0000-0000-0000-000000000905'),
  ('00000000-0000-0000-0000-0000000009c1', '00000000-0000-0000-0000-000000000903', '00000000-0000-0000-0000-000000000906'),
  ('00000000-0000-0000-0000-0000000009c2', '00000000-0000-0000-0000-000000000907', '00000000-0000-0000-0000-000000000908'),
  ('00000000-0000-0000-0000-0000000009c2', '00000000-0000-0000-0000-000000000907', '00000000-0000-0000-0000-000000000909')
) AS v(h, p, c);

-- Test helpers (owner, setup only): a draft effective 2030-01-01, its items, and an approval by a second human.
CREATE FUNCTION pg_temp.cr(p_id uuid) RETURNS void LANGUAGE sql AS $$
  INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind, effective_from)
  VALUES (p_id, '00000000-0000-0000-0000-0000000009b1', 'G ' || p_id, '00000000-0000-0000-0000-0000000009a1', 'human', '2030-01-01')
$$;
CREATE FUNCTION pg_temp.item(p_cr uuid, p_seq int, p_action text, p_h uuid, p_node uuid, p_target uuid, p_payload jsonb)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, target_parent_id, payload)
  VALUES (p_cr, p_seq, p_action::mdm.change_action, p_h, p_node, p_target, p_payload)
$$;
CREATE FUNCTION pg_temp.approve(p_cr uuid) RETURNS void LANGUAGE sql AS $$
  UPDATE mdm.change_request SET status = 'submitted' WHERE change_request_id = p_cr;
  UPDATE mdm.change_request SET status = 'approved', decided_by = '00000000-0000-0000-0000-0000000009a2',
         decided_at = now(), decision_basis = 'human_review' WHERE change_request_id = p_cr;
$$;
CREATE FUNCTION pg_temp.parent(p_h uuid, p_node uuid, p_d date) RETURNS uuid LANGUAGE sql AS $$
  SELECT parent_node_id FROM mdm.hierarchy_relationship
  WHERE hierarchy_id = p_h AND child_node_id = p_node AND is_primary AND valid_period @> p_d AND upper_inf(recorded_period)
$$;

-- 1. add_node ------------------------------------------------------------------------------------------------
SELECT pg_temp.cr('00000000-0000-0000-0000-0000000009d1');
SELECT pg_temp.item('00000000-0000-0000-0000-0000000009d1', 1, 'add_node', '00000000-0000-0000-0000-0000000009c1',
  '00000000-0000-0000-0000-000000000910', '00000000-0000-0000-0000-000000000903', '{"name": "G New", "isLeaf": true}');
SELECT pg_temp.approve('00000000-0000-0000-0000-0000000009d1');

SET LOCAL ROLE nexus_api;
SELECT throws_ok(
  $$INSERT INTO mdm.node_attr (node_id, node_name) VALUES ('00000000-0000-0000-0000-000000000910', 'G direct')$$,
  '42501', NULL, 'The API cannot write facts directly');
SELECT is(mdm.apply_change_request('00000000-0000-0000-0000-0000000009d1', '00000000-0000-0000-0000-0000000009a2'), 2,
  'Applying add_node writes the attributes and the placement');
SELECT is(mdm.apply_change_request('00000000-0000-0000-0000-0000000009d1', '00000000-0000-0000-0000-0000000009a2'), 0,
  'Applying an applied request again does nothing');
RESET ROLE;

SELECT is((SELECT status::text FROM mdm.change_request WHERE change_request_id = '00000000-0000-0000-0000-0000000009d1'),
  'applied', 'The request is applied');
SELECT is((SELECT valid_period FROM mdm.node_attr WHERE node_id = '00000000-0000-0000-0000-000000000910'),
  daterange('2030-01-01', NULL), 'The new node exists from the effective date');
SELECT is((SELECT allows_children FROM mdm.node_attr WHERE node_id = '00000000-0000-0000-0000-000000000910'),
  false, 'isLeaf makes the new node a leaf');
SELECT is(pg_temp.parent('00000000-0000-0000-0000-0000000009c1', '00000000-0000-0000-0000-000000000910', '2030-01-01'),
  '00000000-0000-0000-0000-000000000903'::uuid, 'The new node is placed under its parent on the effective date');
SELECT is(pg_temp.parent('00000000-0000-0000-0000-0000000009c1', '00000000-0000-0000-0000-000000000910', '2029-12-31'),
  NULL, 'The new node is not placed before the effective date');
SELECT is((SELECT payload -> 'items' -> 0 ->> 'action' FROM mdm.change_event
           WHERE change_request_id = '00000000-0000-0000-0000-0000000009d1'),
  'add_node', 'Applying records one change event with the items');
SELECT throws_ok(
  $$UPDATE mdm.change_event SET event_type = 'change_request_applied'$$, 'N2011', NULL, 'Change events are append-only');

-- 2. Traceability (D-29) -------------------------------------------------------------------------------------
SELECT is((SELECT count(*)::int FROM mdm.audit_log
           WHERE change_request_id = '00000000-0000-0000-0000-0000000009d1'
             AND table_name IN ('node_attr', 'hierarchy_relationship')
             AND actor_id = '00000000-0000-0000-0000-0000000009a2'),
  2, 'Every fact row written by apply is audited with the actor and the request');

-- 3. move_node keeps history ---------------------------------------------------------------------------------
SELECT pg_temp.cr('00000000-0000-0000-0000-0000000009d2');
SELECT pg_temp.item('00000000-0000-0000-0000-0000000009d2', 1, 'move_node', '00000000-0000-0000-0000-0000000009c1',
  '00000000-0000-0000-0000-000000000904', '00000000-0000-0000-0000-000000000903',
  '{"expected": {"parentId": "00000000-0000-0000-0000-000000000902", "parentIds": ["00000000-0000-0000-0000-000000000902"]}}');
SELECT pg_temp.approve('00000000-0000-0000-0000-0000000009d2');
SET LOCAL ROLE nexus_api;
SELECT is(mdm.apply_change_request('00000000-0000-0000-0000-0000000009d2', '00000000-0000-0000-0000-0000000009a2'), 3,
  'A move closes the old placement, re-states its history and inserts the new one');
RESET ROLE;
SELECT is(pg_temp.parent('00000000-0000-0000-0000-0000000009c1', '00000000-0000-0000-0000-000000000904', '2030-01-01'),
  '00000000-0000-0000-0000-000000000903'::uuid, 'After the move the node is under the target from the effective date');
SELECT is(pg_temp.parent('00000000-0000-0000-0000-0000000009c1', '00000000-0000-0000-0000-000000000904', '2029-12-31'),
  '00000000-0000-0000-0000-000000000902'::uuid, 'Before the effective date the node is still under its old parent');
SELECT is((SELECT count(*)::int FROM mdm.hierarchy_relationship
           WHERE child_node_id = '00000000-0000-0000-0000-000000000904' AND NOT upper_inf(recorded_period)),
  1, 'The old belief is kept as a closed row, not changed');
SELECT is((SELECT count(*)::int FROM mdm.hierarchy_relationship
           WHERE change_request_id = '00000000-0000-0000-0000-0000000009d2' AND upper_inf(recorded_period)),
  2, 'Rows written by the move carry the request id');

-- 4. insert_node (shared) ------------------------------------------------------------------------------------
SELECT pg_temp.cr('00000000-0000-0000-0000-0000000009d3');
SELECT pg_temp.item('00000000-0000-0000-0000-0000000009d3', 1, 'insert_node', '00000000-0000-0000-0000-0000000009c1',
  '00000000-0000-0000-0000-000000000904', '00000000-0000-0000-0000-000000000902',
  '{"expected": {"parentIds": ["00000000-0000-0000-0000-000000000903"]}}');
SELECT pg_temp.approve('00000000-0000-0000-0000-0000000009d3');
SELECT is(mdm.apply_change_request('00000000-0000-0000-0000-0000000009d3', '00000000-0000-0000-0000-0000000009a2'), 1,
  'insert_node adds a placement');
SELECT is((SELECT is_primary FROM mdm.hierarchy_relationship
           WHERE child_node_id = '00000000-0000-0000-0000-000000000904' AND parent_node_id = '00000000-0000-0000-0000-000000000902'
             AND valid_period @> '2030-01-01'::date AND upper_inf(recorded_period)),
  false, 'A node that already has a primary parent is inserted as shared');

-- 5. Rule failures leave facts unchanged and the request apply_failed -----------------------------------------
-- shared node in a hierarchy that does not allow them (N2003)
SELECT pg_temp.cr('00000000-0000-0000-0000-0000000009d4');
SELECT pg_temp.item('00000000-0000-0000-0000-0000000009d4', 1, 'insert_node', '00000000-0000-0000-0000-0000000009c2',
  '00000000-0000-0000-0000-000000000909', '00000000-0000-0000-0000-000000000908', '{}');
SELECT pg_temp.approve('00000000-0000-0000-0000-0000000009d4');
-- cycle: A under its own child C (N2001)
SELECT pg_temp.cr('00000000-0000-0000-0000-0000000009d5');
SELECT pg_temp.item('00000000-0000-0000-0000-0000000009d5', 1, 'move_node', '00000000-0000-0000-0000-0000000009c1',
  '00000000-0000-0000-0000-000000000902', '00000000-0000-0000-0000-000000000905', '{}');
SELECT pg_temp.approve('00000000-0000-0000-0000-0000000009d5');
-- stale base: drafted when X was under A; it is under B now (N3001)
SELECT pg_temp.cr('00000000-0000-0000-0000-0000000009d6');
SELECT pg_temp.item('00000000-0000-0000-0000-0000000009d6', 1, 'move_node', '00000000-0000-0000-0000-0000000009c1',
  '00000000-0000-0000-0000-000000000904', '00000000-0000-0000-0000-000000000905',
  '{"expected": {"parentId": "00000000-0000-0000-0000-000000000902"}}');
SELECT pg_temp.approve('00000000-0000-0000-0000-0000000009d6');
-- all or nothing: a valid add_node, then an add under a leaf (N2004)
SELECT pg_temp.cr('00000000-0000-0000-0000-0000000009d7');
SELECT pg_temp.item('00000000-0000-0000-0000-0000000009d7', 1, 'add_node', '00000000-0000-0000-0000-0000000009c1',
  '00000000-0000-0000-0000-000000000911', '00000000-0000-0000-0000-000000000905', '{"name": "G Kept out"}');
SELECT pg_temp.item('00000000-0000-0000-0000-0000000009d7', 2, 'add_node', '00000000-0000-0000-0000-0000000009c1',
  '00000000-0000-0000-0000-000000000912', '00000000-0000-0000-0000-000000000906', '{"name": "G Under leaf"}');
SELECT pg_temp.approve('00000000-0000-0000-0000-0000000009d7');
-- an action whose handler is not built yet (property actions arrive in 1-8c)
SELECT pg_temp.cr('00000000-0000-0000-0000-0000000009d8');
SELECT pg_temp.item('00000000-0000-0000-0000-0000000009d8', 1, 'clear_property', '00000000-0000-0000-0000-0000000009c1',
  '00000000-0000-0000-0000-000000000906', NULL, '{}');
SELECT pg_temp.approve('00000000-0000-0000-0000-0000000009d8');

SET LOCAL ROLE nexus_api;
SELECT is(ARRAY[
    mdm.apply_change_request('00000000-0000-0000-0000-0000000009d4', '00000000-0000-0000-0000-0000000009a2'),
    mdm.apply_change_request('00000000-0000-0000-0000-0000000009d5', '00000000-0000-0000-0000-0000000009a2'),
    mdm.apply_change_request('00000000-0000-0000-0000-0000000009d6', '00000000-0000-0000-0000-0000000009a2'),
    mdm.apply_change_request('00000000-0000-0000-0000-0000000009d7', '00000000-0000-0000-0000-0000000009a2'),
    mdm.apply_change_request('00000000-0000-0000-0000-0000000009d8', '00000000-0000-0000-0000-0000000009a2')],
  ARRAY[-1, -1, -1, -1, -1], 'Each failing request reports failure');
RESET ROLE;

SELECT is((SELECT string_agg(left(apply_error, 5), ',' ORDER BY change_request_id) FROM mdm.change_request
           WHERE change_request_id BETWEEN '00000000-0000-0000-0000-0000000009d4' AND '00000000-0000-0000-0000-0000000009d8'
             AND status = 'apply_failed'),
  'N2003,N2001,N3001,N2004,N2105', 'Each failed request records why: shared, cycle, stale base, leaf, not available');
SELECT is((SELECT count(*)::int FROM mdm.node_attr WHERE node_id = '00000000-0000-0000-0000-000000000911'),
  0, 'A failed request writes none of its items, not even the valid ones');
SELECT is(pg_temp.parent('00000000-0000-0000-0000-0000000009c1', '00000000-0000-0000-0000-000000000902', '2030-01-01'),
  '00000000-0000-0000-0000-000000000901'::uuid, 'A refused move leaves the tree unchanged');
SELECT is((SELECT count(*)::int FROM mdm.change_event
           WHERE change_request_id BETWEEN '00000000-0000-0000-0000-0000000009d4' AND '00000000-0000-0000-0000-0000000009d8'),
  0, 'Failed requests publish no change event');

-- 6. Preconditions --------------------------------------------------------------------------------------------
SELECT pg_temp.cr('00000000-0000-0000-0000-0000000009d9');
SELECT throws_ok(
  $$SELECT mdm.apply_change_request('00000000-0000-0000-0000-0000000009d9', '00000000-0000-0000-0000-0000000009a2')$$,
  'N2101', NULL, 'Only approved requests can be applied');

-- 7. Set-from-D with an end date keeps what is true before and after (LLD §7.1, A-2) -----------------------------
SELECT set_config('mdm.apply_date', '2030-01-01', true), set_config('mdm.change_request_id', '00000000-0000-0000-0000-0000000009d1', true);
SELECT is(mdm.apply_fact('node_attr', NULL, '{"node_id": "00000000-0000-0000-0000-000000000906"}',
                         '{"node_name": "G L renamed"}', '2030-02-01', false),
  4, 'A bounded set closes one row and writes before, during and after');
SELECT is((SELECT string_agg(node_name, ',' ORDER BY d) FROM (VALUES (date '2029-12-31'), ('2030-01-15'), ('2030-02-01')) AS v(d)
           JOIN mdm.node_attr a ON a.node_id = '00000000-0000-0000-0000-000000000906'
            AND a.valid_period @> v.d AND upper_inf(a.recorded_period)),
  'G L,G L renamed,G L', 'The value changes only inside the bounded period');

SELECT * FROM finish();
ROLLBACK;
