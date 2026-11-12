-- pgTAP: apply handlers for remove_node, delete_node, update_node, add_hierarchy (Phase 1 LLD §7.2, increment 1-8b),
-- including the refusals N2002, N2005, N2006 and stale base. Synthetic data only.
BEGIN;
SELECT plan(24);

-- Fixture ------------------------------------------------------------------------------------------------------
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-000000000aa1', 'h_steward',  'Steward',  'human'),
  ('00000000-0000-0000-0000-000000000aa2', 'h_approver', 'Approver', 'human');
INSERT INTO mdm.version (version_id, version_name, business_as_of)
VALUES ('00000000-0000-0000-0000-000000000ab1', 'H_VERSION', current_date);

INSERT INTO mdm.node (node_id, node_kind)
SELECT ('00000000-0000-0000-0000-000000000a' || n)::uuid, k::mdm.node_kind FROM (VALUES
  ('01', 'structural'),   -- T  top of H_H1 (shared allowed)
  ('02', 'structural'),   -- A  under T; also under T2 in H_H2
  ('03', 'structural'),   -- B  under A
  ('04', 'legal_entity'), -- X  leaf under B, shared under S
  ('05', 'structural'),   -- S  under T
  ('06', 'legal_entity'), -- R  under T, referenced by T's H.Ref value
  ('07', 'legal_entity'), -- E  under T, has a stored value; deleted
  ('08', 'legal_entity'), -- U  under T; updated
  ('09', 'structural'),   -- T2 top of H_H2
  ('0a', 'structural'),   -- new top node for add_hierarchy
  ('0b', 'structural'),   -- P  under T with child Q
  ('0c', 'legal_entity'), -- Q  under P
  ('0d', 'legal_entity'), -- W  under T, renamed from 2031 (a change scheduled after D)
  ('0e', 'structural')    -- second new top node (duplicate code)
) AS v(n, k);
INSERT INTO mdm.node_attr (node_id, node_name, description, allows_children, valid_period)
SELECT ('00000000-0000-0000-0000-000000000a' || n)::uuid, name, 'desc ' || name, kids, daterange(lo::date, hi::date) FROM (VALUES
  ('01', 'H top', true, '2020-01-01', NULL), ('02', 'H A', true, '2020-01-01', NULL), ('03', 'H B', true, '2020-01-01', NULL),
  ('04', 'H X', false, '2020-01-01', NULL), ('05', 'H S', true, '2020-01-01', NULL), ('06', 'H R', false, '2020-01-01', NULL),
  ('07', 'H E', false, '2020-01-01', NULL), ('08', 'H U', false, '2020-01-01', NULL), ('09', 'H top 2', true, '2020-01-01', NULL),
  ('0b', 'H P', true, '2020-01-01', NULL), ('0c', 'H Q', false, '2020-01-01', NULL),
  ('0d', 'H W', false, '2020-01-01', '2031-01-01'), ('0d', 'H W later', false, '2031-01-01', NULL)
) AS v(n, name, kids, lo, hi);
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id, allow_shared_nodes) VALUES
  ('00000000-0000-0000-0000-000000000ac1', 'H_H1', 'H one', '00000000-0000-0000-0000-000000000a01', true),
  ('00000000-0000-0000-0000-000000000ac2', 'H_H2', 'H two', '00000000-0000-0000-0000-000000000a09', false);
INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, is_primary, valid_period)
SELECT ('00000000-0000-0000-0000-000000000ac' || h)::uuid, ('00000000-0000-0000-0000-000000000a' || p)::uuid,
       ('00000000-0000-0000-0000-000000000a' || c)::uuid, pri, daterange('2020-01-01', NULL) FROM (VALUES
  ('1', '01', '02', true), ('1', '02', '03', true), ('1', '03', '04', true), ('1', '05', '04', false),
  ('1', '01', '05', true), ('1', '01', '06', true), ('1', '01', '07', true), ('1', '01', '08', true),
  ('1', '01', '0b', true), ('1', '0b', '0c', true), ('1', '01', '0d', true), ('2', '09', '02', true)
) AS v(h, p, c, pri);
INSERT INTO mdm.property_definition (property_id, property_code, label, data_type, scope) VALUES
  ('00000000-0000-0000-0000-000000000ad1', 'H.Ref', 'Reference', 'node_ref', 'global'),
  ('00000000-0000-0000-0000-000000000ad2', 'H.Txt', 'Text', 'string', 'global');
INSERT INTO mdm.property_value (node_id, property_id, value, valid_period) VALUES
  ('00000000-0000-0000-0000-000000000a01', '00000000-0000-0000-0000-000000000ad1', '"00000000-0000-0000-0000-000000000a06"', daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-000000000a07', '00000000-0000-0000-0000-000000000ad2', '"kept until deleted"', daterange('2020-01-01', NULL));

-- Helpers (owner, setup only): one approved request per call, effective 2030-01-01, with one item.
CREATE FUNCTION pg_temp.approved(p_id uuid, p_action text, p_h uuid, p_node uuid, p_payload jsonb) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind, effective_from)
  VALUES (p_id, '00000000-0000-0000-0000-000000000ab1', 'H ' || p_id, '00000000-0000-0000-0000-000000000aa1', 'human', '2030-01-01');
  INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, payload)
  VALUES (p_id, 1, p_action::mdm.change_action, p_h, p_node, p_payload);
  UPDATE mdm.change_request SET status = 'submitted' WHERE change_request_id = p_id;
  UPDATE mdm.change_request SET status = 'approved', decided_by = '00000000-0000-0000-0000-000000000aa2',
         decided_at = now(), decision_basis = 'human_review' WHERE change_request_id = p_id;
$$;
CREATE FUNCTION pg_temp.apply(p_id uuid) RETURNS int LANGUAGE plpgsql AS $$
DECLARE v int;
BEGIN
  SET LOCAL ROLE nexus_api;                                     -- applied through the API's privileges
  v := mdm.apply_change_request(p_id, '00000000-0000-0000-0000-000000000aa2');
  RESET ROLE;
  RETURN v;
END $$;
CREATE FUNCTION pg_temp.error(p_id uuid) RETURNS text LANGUAGE sql AS $$
  SELECT left(apply_error, 5) FROM mdm.change_request WHERE change_request_id = p_id AND status = 'apply_failed'
$$;
CREATE FUNCTION pg_temp.placed(p_h uuid, p_node uuid, p_d date) RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM mdm.hierarchy_relationship
  WHERE hierarchy_id = p_h AND child_node_id = p_node AND valid_period @> p_d AND upper_inf(recorded_period)
$$;

-- remove_node ----------------------------------------------------------------------------------------------------
SELECT pg_temp.approved('00000000-0000-0000-0000-000000000ae1', 'remove_node', '00000000-0000-0000-0000-000000000ac1',
  '00000000-0000-0000-0000-000000000a02', '{}');
SELECT is(pg_temp.apply('00000000-0000-0000-0000-000000000ae1'), -1, 'Removing a node with children needs cascade');
SELECT is(pg_temp.error('00000000-0000-0000-0000-000000000ae1'), 'N2005', '… and the refusal is N2005');

SELECT pg_temp.approved('00000000-0000-0000-0000-000000000ae2', 'remove_node', '00000000-0000-0000-0000-000000000ac1',
  '00000000-0000-0000-0000-000000000a02',
  '{"cascade": true, "expected": {"parentIds": ["00000000-0000-0000-0000-000000000a01"]}}');
SELECT ok(pg_temp.apply('00000000-0000-0000-0000-000000000ae2') > 0, 'Removing with cascade is applied');
SELECT is(pg_temp.placed('00000000-0000-0000-0000-000000000ac1', '00000000-0000-0000-0000-000000000a02', '2030-01-01')
        + pg_temp.placed('00000000-0000-0000-0000-000000000ac1', '00000000-0000-0000-0000-000000000a03', '2030-01-01')
        + pg_temp.placed('00000000-0000-0000-0000-000000000ac1', '00000000-0000-0000-0000-000000000a04', '2030-01-01'),
  0, 'The node and its sub-tree leave the hierarchy, shared placements of members included');
SELECT is(pg_temp.placed('00000000-0000-0000-0000-000000000ac1', '00000000-0000-0000-0000-000000000a04', '2029-12-31'),
  2, 'Before the effective date the sub-tree is unchanged');
SELECT is(pg_temp.placed('00000000-0000-0000-0000-000000000ac2', '00000000-0000-0000-0000-000000000a02', '2030-01-01'),
  1, 'The node keeps its place in other hierarchies');
SELECT is((SELECT count(*)::int FROM mdm.node_attr WHERE node_id = '00000000-0000-0000-0000-000000000a02'
           AND valid_period @> '2030-01-01'::date AND upper_inf(recorded_period)),
  1, 'Removing from a hierarchy does not delete the node');

-- update_node ----------------------------------------------------------------------------------------------------
SELECT pg_temp.approved('00000000-0000-0000-0000-000000000ae3', 'update_node', '00000000-0000-0000-0000-000000000ac1',
  '00000000-0000-0000-0000-000000000a08',
  '{"name": "H U renamed", "description": null, "expected": {"name": "H U", "description": "desc H U"}}');
SELECT is(pg_temp.apply('00000000-0000-0000-0000-000000000ae3'), 3, 'An update closes one row and writes before and from D');
SELECT is((SELECT node_name || '/' || coalesce(description, '-') FROM mdm.node_attr
           WHERE node_id = '00000000-0000-0000-0000-000000000a08' AND valid_period @> '2030-01-01'::date AND upper_inf(recorded_period)),
  'H U renamed/-', 'From D the node has the new name and no description');
SELECT is((SELECT node_name FROM mdm.node_attr
           WHERE node_id = '00000000-0000-0000-0000-000000000a08' AND valid_period @> '2029-12-31'::date AND upper_inf(recorded_period)),
  'H U', 'Before D it keeps the old name');
SELECT is((SELECT allows_children FROM mdm.node_attr
           WHERE node_id = '00000000-0000-0000-0000-000000000a08' AND valid_period @> '2030-01-01'::date AND upper_inf(recorded_period)),
  false, 'Attributes not in the item carry over');

SELECT pg_temp.approved('00000000-0000-0000-0000-000000000ae4', 'update_node', '00000000-0000-0000-0000-000000000ac1',
  '00000000-0000-0000-0000-000000000a08', '{"name": "H U again", "expected": {"name": "H U"}}');
SELECT is(pg_temp.apply('00000000-0000-0000-0000-000000000ae4'), -1, 'An update drafted against an old name is refused');
SELECT is(pg_temp.error('00000000-0000-0000-0000-000000000ae4'), 'N3001', '… as a stale base');

-- delete_node ----------------------------------------------------------------------------------------------------
SELECT pg_temp.approved('00000000-0000-0000-0000-000000000ae5', 'delete_node', '00000000-0000-0000-0000-000000000ac1',
  '00000000-0000-0000-0000-000000000a07', '{"expected": {"name": "H E", "description": "desc H E"}}');
SELECT is(pg_temp.apply('00000000-0000-0000-0000-000000000ae5'), 6,
  'Delete ends the placement, the stored value and the attributes (closed + re-stated each)');
SELECT is((SELECT count(*)::int FROM mdm.node_attr WHERE node_id = '00000000-0000-0000-0000-000000000a07'
           AND valid_period @> '2030-01-01'::date AND upper_inf(recorded_period)),
  0, 'From D the deleted node has no attributes');
SELECT is((SELECT count(*)::int FROM mdm.property_value WHERE node_id = '00000000-0000-0000-0000-000000000a07'
           AND valid_period @> '2030-01-01'::date AND upper_inf(recorded_period)),
  0, 'From D its stored values have ended');
SELECT is(pg_temp.placed('00000000-0000-0000-0000-000000000ac1', '00000000-0000-0000-0000-000000000a07', '2029-12-31'),
  1, 'Before D it is still in the hierarchy');

SELECT pg_temp.approved('00000000-0000-0000-0000-000000000ae6', 'delete_node', '00000000-0000-0000-0000-000000000ac1',
  '00000000-0000-0000-0000-000000000a06', '{}');
SELECT pg_temp.approved('00000000-0000-0000-0000-000000000ae7', 'delete_node', '00000000-0000-0000-0000-000000000ac1',
  '00000000-0000-0000-0000-000000000a01', '{}');
SELECT pg_temp.approved('00000000-0000-0000-0000-000000000ae8', 'delete_node', '00000000-0000-0000-0000-000000000ac1',
  '00000000-0000-0000-0000-000000000a0b', '{}');
SELECT pg_temp.approved('00000000-0000-0000-0000-000000000ae9', 'delete_node', '00000000-0000-0000-0000-000000000ac1',
  '00000000-0000-0000-0000-000000000a0d', '{}');
SELECT is(ARRAY[pg_temp.apply('00000000-0000-0000-0000-000000000ae6'), pg_temp.apply('00000000-0000-0000-0000-000000000ae7'),
                pg_temp.apply('00000000-0000-0000-0000-000000000ae8'), pg_temp.apply('00000000-0000-0000-0000-000000000ae9')],
  ARRAY[-1, -1, -1, -1], 'Deletes that would leave something depending on the node are refused');
SELECT is(ARRAY[pg_temp.error('00000000-0000-0000-0000-000000000ae6'), pg_temp.error('00000000-0000-0000-0000-000000000ae7'),
                pg_temp.error('00000000-0000-0000-0000-000000000ae8'), pg_temp.error('00000000-0000-0000-0000-000000000ae9')],
  ARRAY['N2006', 'N2002', 'N2005', 'N2105'], 'Referenced (N2006), top node (N2002), has children (N2005), scheduled change (N2105)');
SELECT is(pg_temp.placed('00000000-0000-0000-0000-000000000ac1', '00000000-0000-0000-0000-000000000a06', '2030-01-01'),
  1, 'A refused delete changes nothing');

-- add_hierarchy --------------------------------------------------------------------------------------------------
SELECT pg_temp.approved('00000000-0000-0000-0000-000000000aea', 'add_hierarchy', NULL, '00000000-0000-0000-0000-000000000a0a',
  '{"code": "H_NEW", "name": "H new", "purpose": "management", "allowSharedNodes": true,
    "topNode": {"nodeKind": "structural", "name": "H new top"}}');
SELECT is(pg_temp.apply('00000000-0000-0000-0000-000000000aea'), 2, 'add_hierarchy writes the top node and the hierarchy');
SELECT is((SELECT hierarchy_name || '/' || purpose || '/' || allow_shared_nodes FROM mdm.hierarchy
           WHERE hierarchy_code = 'H_NEW' AND top_node_id = '00000000-0000-0000-0000-000000000a0a'),
  'H new/management/true', 'The hierarchy exists with its top node and settings');
SELECT is((SELECT valid_period FROM mdm.node_attr WHERE node_id = '00000000-0000-0000-0000-000000000a0a'),
  daterange('2030-01-01', NULL), 'The top node exists from the effective date');

SELECT pg_temp.approved('00000000-0000-0000-0000-000000000aeb', 'add_hierarchy', NULL, '00000000-0000-0000-0000-000000000a0e',
  '{"code": "H_NEW", "name": "H duplicate", "topNode": {"nodeKind": "structural", "name": "H dup top"}}');
SELECT is(pg_temp.apply('00000000-0000-0000-0000-000000000aeb') || '/' || pg_temp.error('00000000-0000-0000-0000-000000000aeb'),
  '-1/23505', 'A duplicate hierarchy code fails the apply');

SELECT * FROM finish();
ROLLBACK;
