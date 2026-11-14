-- pgTAP: the sandbox overlay (Phase 5 NEW-08, increment 5-1b; ADR-028; Phase 5 LLD §5, §7.1–§7.3, §9; P-28).
-- The overlay is computed by a trial apply that is always rolled back. These tests hold it to that promise: for every
-- action kind, what the overlay shows before the sandbox is applied is exactly what the facts show after it is applied
-- (tree page, node detail, placements, resolved properties) on dates before, at and after its effective date. Then a
-- stale expected value becomes a conflict naming the request that changed the fact, rebase moves the base, the
-- incremental refresh agrees with a full one, and no fact row changes on the way. Synthetic data only.
BEGIN;
SELECT plan(53);

-- ---------------------------------------------------------------- fixtures (synthetic)
CREATE FUNCTION pg_temp.id(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('00000000-0000-0000-0000-00000023' || p)::uuid
$$;

INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  (pg_temp.id('a0a1'), 'so_owner',   'Overlay owner',   'human'),
  (pg_temp.id('a0a2'), 'so_checker', 'Overlay checker', 'human'),
  (pg_temp.id('a0a3'), 'so_other',   'Other maker',     'human');
INSERT INTO mdm.version (version_id, version_name, business_as_of) VALUES (pg_temp.id('b0b1'), 'SO_VERSION', current_date);

-- H1 (shared nodes allowed): T > A > X, Y;  T > B > Z, S;  T > W.   H2: T2 > C, D, E.
-- N and NT are identities only: add_node and add_hierarchy give them their attributes.
INSERT INTO mdm.node (node_id, node_kind)
SELECT pg_temp.id(n), 'structural' FROM unnest(ARRAY['c001', 'c002', 'c003', 'c004', 'c005', 'c006', 'c007', 'c008',
                                                     'c009', 'c00b', 'c021', 'c022', 'c023', 'c024']) n;
INSERT INTO mdm.node_attr (node_id, node_name, description, allows_children, valid_period, recorded_period)
SELECT pg_temp.id(n), name, descr, kids, daterange('2020-01-01', NULL), tstzrange(now() - interval '2 days', NULL) FROM (VALUES
  ('c001', 'SO T', NULL, true), ('c002', 'SO A', NULL, true), ('c003', 'SO B', NULL, true),
  ('c004', 'SO X', NULL, false), ('c005', 'SO Y', NULL, false), ('c006', 'SO Z', 'desc SO Z', false),
  ('c007', 'SO W', 'desc SO W', false), ('c009', 'SO S', NULL, false),
  ('c021', 'SO T2', NULL, true), ('c022', 'SO C', NULL, false), ('c023', 'SO D', NULL, false), ('c024', 'SO E', NULL, false)
) AS v(n, name, descr, kids);
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id, allow_shared_nodes) VALUES
  (pg_temp.id('d0d1'), 'SO_H1', 'Overlay one', pg_temp.id('c001'), true),
  (pg_temp.id('d0d2'), 'SO_H2', 'Overlay two', pg_temp.id('c021'), false);
INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, sort_order, valid_period, recorded_period)
SELECT pg_temp.id(h), pg_temp.id(p), pg_temp.id(c), s, daterange('2020-01-01', NULL), tstzrange(now() - interval '2 days', NULL)
FROM (VALUES
  ('d0d1', 'c001', 'c002', 1000), ('d0d1', 'c001', 'c003', 2000), ('d0d1', 'c001', 'c007', 3000),
  ('d0d1', 'c002', 'c004', 1000), ('d0d1', 'c002', 'c005', 2000),
  ('d0d1', 'c003', 'c006', 1000), ('d0d1', 'c003', 'c009', 2000),
  ('d0d2', 'c021', 'c022', 1000), ('d0d2', 'c021', 'c023', 2000), ('d0d2', 'c021', 'c024', 3000)
) AS v(h, p, c, s);
INSERT INTO mdm.property_definition (property_id, property_code, label, data_type, scope, inheritance, default_value) VALUES
  (pg_temp.id('e0e1'), 'SO.Code', 'Overlay code', 'string', 'global', 'inherit_from_ancestor', '"DEF"'),
  (pg_temp.id('e0e2'), 'SO.Note', 'Overlay note', 'string', 'global', 'none', NULL);
INSERT INTO mdm.property_value (node_id, property_id, value, valid_period, recorded_period)
SELECT pg_temp.id(n), pg_temp.id(p), v::jsonb, daterange('2020-01-01', NULL), tstzrange(now() - interval '2 days', NULL) FROM (VALUES
  ('c002', 'e0e1', '"A1"'), ('c006', 'e0e2', '"note Z"'), ('c007', 'e0e2', '"note W"')
) AS x(n, p, v);

-- Three sandboxes, effective 2030-01-01, based on the facts as recorded a day ago.
INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind, effective_from,
                                kind, origin, sandbox_name, sandbox_base_recorded_at)
SELECT pg_temp.id(s), pg_temp.id('b0b1'), 'SO ' || s, pg_temp.id('a0a1'), 'human', '2030-01-01',
       'sandbox', 'sandbox', 'Overlay ' || s, now() - interval '1 day'
FROM unnest(ARRAY['f0f1', 'f0f2', 'f0f3']) s;

-- S1: one item of every action kind, and one item (11) that changes a row an earlier item (1) inserted.
INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, target_parent_id, property_id, payload) VALUES
  (pg_temp.id('f0f1'),  1, 'add_node',       pg_temp.id('d0d1'), pg_temp.id('c008'), pg_temp.id('c002'), NULL,
   '{"name": "SO N", "description": "new"}'),
  (pg_temp.id('f0f1'),  2, 'insert_node',    pg_temp.id('d0d1'), pg_temp.id('c009'), pg_temp.id('c002'), NULL,
   jsonb_build_object('expected', jsonb_build_object('parentIds', jsonb_build_array(pg_temp.id('c003'))))),
  (pg_temp.id('f0f1'),  3, 'move_node',      pg_temp.id('d0d1'), pg_temp.id('c004'), pg_temp.id('c003'), NULL,
   jsonb_build_object('expected', jsonb_build_object('parentId', pg_temp.id('c002'), 'parentIds', jsonb_build_array(pg_temp.id('c002'))))),
  (pg_temp.id('f0f1'),  4, 'remove_node',    pg_temp.id('d0d1'), pg_temp.id('c005'), NULL, NULL,
   jsonb_build_object('expected', jsonb_build_object('parentIds', jsonb_build_array(pg_temp.id('c002'))))),
  (pg_temp.id('f0f1'),  5, 'delete_node',    pg_temp.id('d0d1'), pg_temp.id('c006'), NULL, NULL,
   '{"expected": {"name": "SO Z", "description": "desc SO Z"}}'),
  (pg_temp.id('f0f1'),  6, 'update_node',    pg_temp.id('d0d1'), pg_temp.id('c007'), NULL, NULL,
   '{"name": "SO W2", "expected": {"name": "SO W"}}'),
  (pg_temp.id('f0f1'),  7, 'set_property',   pg_temp.id('d0d1'), pg_temp.id('c003'), NULL, pg_temp.id('e0e1'),
   '{"value": "B1", "expected": {"present": false}}'),
  (pg_temp.id('f0f1'),  8, 'clear_property', pg_temp.id('d0d1'), pg_temp.id('c007'), NULL, pg_temp.id('e0e2'),
   '{"expected": {"present": true, "value": "note W"}}'),
  (pg_temp.id('f0f1'),  9, 'set_property',   pg_temp.id('d0d1'), pg_temp.id('c002'), NULL, pg_temp.id('e0e2'),
   '{"value": "temp", "validTo": "2031-01-01"}'),
  (pg_temp.id('f0f1'), 10, 'add_hierarchy',  NULL, pg_temp.id('c00b'), NULL, NULL,
   '{"code": "SO_H_NEW", "name": "SO new hierarchy", "topNode": {"name": "SO NT", "description": "new top"}}'),
  (pg_temp.id('f0f1'), 11, 'update_node',    pg_temp.id('d0d1'), pg_temp.id('c008'), NULL, NULL,
   '{"name": "SO N2", "expected": {"name": "SO N"}}');

-- A fingerprint of every fact table and the outbox (as in 23_sandboxes): any row inserted, closed or changed changes it.
CREATE FUNCTION pg_temp.facts() RETURNS text LANGUAGE sql AS $$
  SELECT md5(string_agg(x, '|' ORDER BY x)) FROM (
              SELECT 'node_attr '              || t::text FROM mdm.node_attr t
    UNION ALL SELECT 'node_identifier '        || t::text FROM mdm.node_identifier t
    UNION ALL SELECT 'legal_entity_profile '   || t::text FROM mdm.legal_entity_profile t
    UNION ALL SELECT 'hierarchy '              || t::text FROM mdm.hierarchy t
    UNION ALL SELECT 'hierarchy_relationship ' || t::text FROM mdm.hierarchy_relationship t
    UNION ALL SELECT 'property_value '         || t::text FROM mdm.property_value t
    UNION ALL SELECT 'user_role '              || t::text FROM mdm.user_role t
    UNION ALL SELECT 'change_event '           || t::text FROM mdm.change_event t) s(x)
$$;
-- A sandbox's overlay rows, as text, for comparing two refreshes.
CREATE FUNCTION pg_temp.delta(p uuid) RETURNS SETOF text LANGUAGE sql AS $$
            SELECT 'rel '  || (d.hierarchy_id, d.parent_node_id, d.child_node_id, d.is_primary, d.sort_order, d.valid_period, d.op)::text
            FROM mdm.sandbox_delta_relationship d WHERE d.sandbox_id = p
  UNION ALL SELECT 'attr ' || (d.node_id, d.node_name, d.description, d.is_active, d.allows_children, d.valid_period, d.op)::text
            FROM mdm.sandbox_delta_node_attr d WHERE d.sandbox_id = p
  UNION ALL SELECT 'val '  || (d.node_id, d.property_id, d.hierarchy_key, d.value, d.valid_period, d.op)::text
            FROM mdm.sandbox_delta_value d WHERE d.sandbox_id = p
$$;
-- Decisions and apply as in 10_apply_structure: a human checker decides; apply runs with the API's rights.
CREATE FUNCTION pg_temp.approve(p_id uuid) RETURNS void LANGUAGE sql AS $$
  UPDATE mdm.change_request SET status = 'approved', decided_by = pg_temp.id('a0a2'), decided_at = now(),
         decision_basis = 'human_review' WHERE change_request_id = p_id;
$$;
CREATE FUNCTION pg_temp.apply(p_id uuid) RETURNS int LANGUAGE plpgsql AS $$
DECLARE v int; v_checker uuid := pg_temp.id('a0a2');
BEGIN
  SET LOCAL ROLE nexus_api;
  v := mdm.apply_change_request(p_id, v_checker);
  RESET ROLE;
  RETURN v;
END $$;

CREATE TEMP TABLE snap (label text PRIMARY KEY, facts text);
INSERT INTO snap VALUES ('before', pg_temp.facts());
CREATE TEMP TABLE as_of_dates (d date);
INSERT INTO as_of_dates VALUES ('2029-06-01'), ('2030-06-01'), ('2031-06-01');   -- before, at and after the change
CREATE TEMP TABLE h1_nodes (node_id uuid);
INSERT INTO h1_nodes SELECT pg_temp.id(n) FROM unnest(ARRAY['c001', 'c002', 'c003', 'c004', 'c005', 'c006', 'c007', 'c008', 'c009']) n;

-- ================================================================ 1. the overlay of every action kind
SET LOCAL ROLE nexus_api;
SELECT is((SELECT count(*)::int FROM mdm.refresh_sandbox_delta('00000000-0000-0000-0000-00000023f0f1')), 0,
  'The API refreshes a sandbox overlay; every item applies, so no failure is reported');
RESET ROLE;
SELECT is((SELECT string_agg(op || node_name, ',' ORDER BY op, node_name) FROM mdm.sandbox_delta_node_attr
           WHERE sandbox_id = pg_temp.id('f0f1') AND node_id = pg_temp.id('c008')),
  '+SO N2', 'A row the trial inserted and closed again leaves no trace: the new node has one + row, its final name');

-- What the overlay shows (read as the owner of the test; the API's rights are checked below).
CREATE TEMP TABLE ov_tree AS
SELECT d.d AS as_of, p.node_id AS parent_id, c.ord, c.child_node_id, c.node_name, c.description, c.is_active,
       c.is_primary, c.sort_order, c.has_children, c.changed
FROM as_of_dates d CROSS JOIN h1_nodes p
CROSS JOIN LATERAL mdm.sandbox_children(pg_temp.id('f0f1'), pg_temp.id('d0d1'), p.node_id, d.d, NULL, NULL, NULL, 1000)
  WITH ORDINALITY AS c(child_node_id, node_name, description, is_active, is_primary, sort_order, has_children, changed, ord);
CREATE TEMP TABLE ov_attr AS
SELECT d.d AS as_of, n.node_id, a.node_name, a.description, a.is_active, a.allows_children, a.changed
FROM as_of_dates d CROSS JOIN (SELECT node_id FROM h1_nodes UNION ALL SELECT pg_temp.id('c00b')) n
CROSS JOIN LATERAL mdm.sandbox_node(pg_temp.id('f0f1'), n.node_id, d.d) a;
CREATE TEMP TABLE ov_place AS
SELECT d.d AS as_of, n.node_id, p.parent_node_id, p.is_primary, p.sort_order, p.changed
FROM as_of_dates d CROSS JOIN h1_nodes n
CROSS JOIN LATERAL mdm.sandbox_placements(pg_temp.id('f0f1'), pg_temp.id('d0d1'), n.node_id, d.d) p;
CREATE TEMP TABLE ov_props AS
SELECT d.d AS as_of, n.node_id, p.property_id, p.value, p.provenance, p.source_node_id, p.changed
FROM as_of_dates d CROSS JOIN h1_nodes n
CROSS JOIN LATERAL mdm.sandbox_node_properties(pg_temp.id('f0f1'), n.node_id, pg_temp.id('d0d1'), d.d) p
WHERE p.property_id IN (pg_temp.id('e0e1'), pg_temp.id('e0e2'));

SELECT is((SELECT count(*)::int FROM ov_tree), 21, 'The overlay tree has seven placements on each of the three dates');
SELECT is((SELECT count(*)::int FROM ov_tree WHERE as_of = '2029-06-01' AND changed)
        + (SELECT count(*)::int FROM ov_attr WHERE as_of = '2029-06-01' AND changed)
        + (SELECT count(*)::int FROM ov_place WHERE as_of = '2029-06-01' AND changed)
        + (SELECT count(*)::int FROM ov_props WHERE as_of = '2029-06-01' AND changed),
  0, 'Before the effective date nothing is marked changed, although the trial re-stated history rows');
SELECT set_eq(
  $$SELECT parent_id, child_node_id FROM ov_tree WHERE as_of = '2030-06-01' AND changed$$,
  $$SELECT pg_temp.id(p) AS p, pg_temp.id(c) AS c FROM (VALUES ('c002', 'c008'), ('c002', 'c009'), ('c003', 'c004'), ('c001', 'c007')) v(p, c)$$,
  'The tree marks what the sandbox changes: the added node, the shared placement, the moved node and the renamed node');
SELECT set_eq(
  $$SELECT node_id FROM ov_attr WHERE as_of = '2030-06-01' AND changed$$,
  $$SELECT pg_temp.id(n) FROM unnest(ARRAY['c007', 'c008', 'c00b']) n$$,
  'Node detail marks the renamed node, the added node and the new top node');
SELECT set_eq(
  $$SELECT node_id, parent_node_id FROM ov_place WHERE as_of = '2030-06-01' AND changed$$,
  $$SELECT pg_temp.id(n) AS n, pg_temp.id(p) AS p FROM (VALUES ('c004', 'c003'), ('c009', 'c002'), ('c008', 'c002')) v(n, p)$$,
  'Placements mark the moved node, the shared placement and the added node');
SELECT set_eq(
  $$SELECT node_id, property_id FROM ov_props WHERE as_of = '2030-06-01' AND changed$$,
  $$SELECT pg_temp.id(n) AS n, pg_temp.id(p) AS p FROM (VALUES ('c003', 'e0e1'), ('c004', 'e0e1'), ('c009', 'e0e1'), ('c008', 'e0e1'),
                                                     ('c005', 'e0e1'), ('c006', 'e0e2'), ('c007', 'e0e2'), ('c002', 'e0e2')) v(n, p)$$,
  'Properties mark set, cleared and ended values, and every inherited value that a move, removal or new value changes');
SELECT is((SELECT string_agg(node_name, ',' ORDER BY sort_order)
           FROM mdm.sandbox_children(pg_temp.id('f0f1'), pg_temp.id('d0d1'), pg_temp.id('c002'), '2030-06-01',
                                     3000, 'SO N2', pg_temp.id('c008'), 10)),
  'SO S', 'An overlay page continues after its keyset (sort order, name, node id), as a Phase 1 page does');

SET LOCAL ROLE nexus_api;
SELECT is((SELECT string_agg(node_name, ',' ORDER BY sort_order)
           FROM mdm.sandbox_children('00000000-0000-0000-0000-00000023f0f1', '00000000-0000-0000-0000-00000023d0d1',
                                     '00000000-0000-0000-0000-00000023c003', '2030-06-01'))
          || '|' || (SELECT node_name FROM mdm.sandbox_node('00000000-0000-0000-0000-00000023f0f1',
                                                            '00000000-0000-0000-0000-00000023c007', '2030-06-01'))
          || '|' || (SELECT count(*) FROM mdm.sandbox_placements('00000000-0000-0000-0000-00000023f0f1',
                       '00000000-0000-0000-0000-00000023d0d1', '00000000-0000-0000-0000-00000023c009', '2030-06-01'))
          || '|' || (SELECT value #>> '{}' FROM mdm.sandbox_node_properties('00000000-0000-0000-0000-00000023f0f1',
                       '00000000-0000-0000-0000-00000023c004', '00000000-0000-0000-0000-00000023d0d1', '2030-06-01')
                     WHERE property_id = '00000000-0000-0000-0000-00000023e0e1'),
  'SO S,SO X|SO W2|2|B1', 'The API reads the overlay: tree page, node detail, placements and resolved properties');
RESET ROLE;

SELECT is(pg_temp.facts(), (SELECT facts FROM snap WHERE label = 'before'), 'Refreshing and reading the overlay changed no fact row');

-- ================================================================ 2. the overlay equals the applied result
UPDATE mdm.change_request SET kind = 'request', status = 'submitted', submitted_at = now()
WHERE change_request_id = pg_temp.id('f0f1');
SELECT pg_temp.approve(pg_temp.id('f0f1'));
CREATE TEMP TABLE delta_s1 AS SELECT pg_temp.delta(pg_temp.id('f0f1')) AS x;
SELECT set_config('mdm.sandbox_capture', pg_temp.id('f0f1')::text, true);   -- as if a trial had left capture on
SELECT ok(pg_temp.apply(pg_temp.id('f0f1')) > 0, 'The sandbox, now a request, is approved and applied');
SELECT set_eq($$SELECT pg_temp.delta(pg_temp.id('f0f1'))$$, $$SELECT x FROM delta_s1$$,
  'A committed apply never writes an overlay, even with capture left on');

-- The facts after apply, read the way Phase 1 reads them (current rows; the children page in keyset order).
CREATE TEMP TABLE f_tree AS
SELECT d.d AS as_of, p.node_id AS parent_id,
       row_number() OVER (PARTITION BY d.d, p.node_id ORDER BY r.sort_order, coalesce(a.node_name, ''), r.child_node_id) AS ord,
       r.child_node_id, a.node_name, a.description, coalesce(a.is_active, false) AS is_active, r.is_primary, r.sort_order,
       EXISTS (SELECT 1 FROM mdm.hierarchy_relationship k WHERE k.hierarchy_id = r.hierarchy_id AND k.parent_node_id = r.child_node_id
                 AND k.valid_period @> d.d AND upper_inf(k.recorded_period)) AS has_children
FROM as_of_dates d CROSS JOIN h1_nodes p
JOIN mdm.hierarchy_relationship r ON r.hierarchy_id = pg_temp.id('d0d1') AND r.parent_node_id = p.node_id
 AND r.valid_period @> d.d AND upper_inf(r.recorded_period)
LEFT JOIN mdm.node_attr a ON a.node_id = r.child_node_id AND a.valid_period @> d.d AND upper_inf(a.recorded_period);

SELECT set_eq(
  $$SELECT as_of, parent_id, ord, child_node_id, node_name, description, is_active, is_primary, sort_order, has_children FROM ov_tree$$,
  $$SELECT as_of, parent_id, ord, child_node_id, node_name, description, is_active, is_primary, sort_order, has_children FROM f_tree$$,
  'The overlay tree equals the applied tree on every date: placements, names, sort order, page order and has-children');
SELECT set_eq(
  $$SELECT as_of, node_id, node_name, description, is_active, allows_children FROM ov_attr$$,
  $$SELECT d.d, n.node_id, a.node_name, a.description, a.is_active, a.allows_children
    FROM as_of_dates d CROSS JOIN (SELECT node_id FROM h1_nodes UNION ALL SELECT pg_temp.id('c00b')) n
    JOIN mdm.node_attr a ON a.node_id = n.node_id AND a.valid_period @> d.d AND upper_inf(a.recorded_period)$$,
  'Overlay node detail equals the applied node attributes, including the deleted, added and new top nodes');
SELECT set_eq(
  $$SELECT as_of, node_id, parent_node_id, is_primary, sort_order FROM ov_place$$,
  $$SELECT d.d, n.node_id, r.parent_node_id, r.is_primary, r.sort_order FROM as_of_dates d CROSS JOIN h1_nodes n
    JOIN mdm.hierarchy_relationship r ON r.hierarchy_id = pg_temp.id('d0d1') AND r.child_node_id = n.node_id
     AND r.valid_period @> d.d AND upper_inf(r.recorded_period)$$,
  'Overlay placements equal the applied placements');
SELECT set_eq(
  $$SELECT as_of, node_id, property_id, value, provenance, source_node_id FROM ov_props$$,
  $$SELECT d.d, n.node_id, p.property_id, p.value, p.provenance, p.source_node_id FROM as_of_dates d CROSS JOIN h1_nodes n
    CROSS JOIN LATERAL mdm.node_properties_resolved(n.node_id, pg_temp.id('d0d1'), d.d) p
    WHERE p.property_id IN (pg_temp.id('e0e1'), pg_temp.id('e0e2'))$$,
  'Overlay properties equal the applied resolution: stored, inherited (with its source) and default, on every date');

-- ================================================================ 3. conflicts and rebase
INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, property_id, payload) VALUES
  (pg_temp.id('f0f2'), 1, 'update_node',  pg_temp.id('d0d2'), pg_temp.id('c022'), NULL, '{"name": "SO C2", "expected": {"name": "SO C"}}'),
  (pg_temp.id('f0f2'), 2, 'set_property', pg_temp.id('d0d2'), pg_temp.id('c022'), pg_temp.id('e0e2'),
   '{"value": "c note", "expected": {"present": false}}');
SET LOCAL ROLE nexus_api;
SELECT is((SELECT count(*)::int FROM mdm.refresh_sandbox_delta('00000000-0000-0000-0000-00000023f0f2')), 0,
  'A second sandbox refreshes cleanly');
SELECT is((SELECT count(*)::int FROM mdm.sandbox_conflicts('00000000-0000-0000-0000-00000023f0f2')), 0,
  'While its base is current it has no conflicts');
RESET ROLE;

-- Meanwhile another maker renames C through an ordinary request.
INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind, effective_from)
VALUES (pg_temp.id('f0a1'), pg_temp.id('b0b1'), 'SO other rename', pg_temp.id('a0a3'), 'human', '2030-01-01');
INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, payload)
VALUES (pg_temp.id('f0a1'), 1, 'update_node', pg_temp.id('d0d2'), pg_temp.id('c022'), '{"name": "SO C other"}');
UPDATE mdm.change_request SET status = 'submitted', submitted_at = now() WHERE change_request_id = pg_temp.id('f0a1');
SELECT pg_temp.approve(pg_temp.id('f0a1'));
SELECT ok(pg_temp.apply(pg_temp.id('f0a1')) > 0, 'Another request renames C after the sandbox''s base');
INSERT INTO snap VALUES ('after_other', pg_temp.facts());

SET LOCAL ROLE nexus_api;
SELECT is((SELECT jsonb_agg(jsonb_build_object('seq', c.seq, 'action', c.action, 'field', c.field, 'expected', c.expected,
                                               'actual', c.actual, 'by', c.changed_by_request))
           FROM mdm.sandbox_conflicts('00000000-0000-0000-0000-00000023f0f2') c),
  '[{"seq": 1, "action": "update_node", "field": "name", "expected": "SO C", "actual": "SO C other",
     "by": "00000000-0000-0000-0000-00000023f0a1"}]'::jsonb,
  'A conflict names the item, the field, what it expected, what is there now, and the request that changed it');
SELECT is((SELECT changed_at FROM mdm.sandbox_conflicts('00000000-0000-0000-0000-00000023f0f2')), now(),
  'and when that request changed it');
SELECT is((SELECT string_agg(seq || ':' || error_code, ',' ORDER BY seq)
           FROM mdm.refresh_sandbox_delta('00000000-0000-0000-0000-00000023f0f2')),
  '1:N3001', 'Refresh reports the stale item and carries on with the others');
SELECT is((SELECT node_name FROM mdm.sandbox_node('00000000-0000-0000-0000-00000023f0f2',
                                                  '00000000-0000-0000-0000-00000023c022', '2030-06-01')),
  'SO C', 'The stale item is left out of the overlay, which still shows the sandbox''s base');
SELECT is((SELECT value FROM mdm.sandbox_node_properties('00000000-0000-0000-0000-00000023f0f2', '00000000-0000-0000-0000-00000023c022',
                                                         '00000000-0000-0000-0000-00000023d0d2', '2030-06-01')
           WHERE property_id = '00000000-0000-0000-0000-00000023e0e2'),
  '"c note"'::jsonb, 'The items after it still show');
SELECT throws_ok(
  $$SELECT * FROM mdm.rebase_sandbox('00000000-0000-0000-0000-00000023f0f2', '00000000-0000-0000-0000-00000023a0a3')$$,
  'N1025', NULL, 'Only the sandbox''s owner may rebase it (N1025)');
RESET ROLE;

CREATE TEMP TABLE s2_before AS
SELECT sandbox_base_recorded_at, row_version FROM mdm.change_request WHERE change_request_id = pg_temp.id('f0f2');
SET LOCAL ROLE nexus_api;
SELECT is((SELECT string_agg(seq || ':' || error_code, ',' ORDER BY seq)
           FROM mdm.rebase_sandbox('00000000-0000-0000-0000-00000023f0f2', '00000000-0000-0000-0000-00000023a0a1')),
  '1:N3001', 'Rebase moves the base and refreshes; the conflicting item stays flagged');
RESET ROLE;
SELECT ok((SELECT c.sandbox_base_recorded_at = now() AND c.sandbox_base_recorded_at > b.sandbox_base_recorded_at
                  AND c.row_version > b.row_version
           FROM mdm.change_request c, s2_before b WHERE c.change_request_id = pg_temp.id('f0f2')),
  'The base is now, and the sandbox''s row version changed');
SELECT is((SELECT count(*)::int FROM mdm.sandbox_conflicts(pg_temp.id('f0f2'))), 1,
  'The conflict is listed until the owner changes the item');
SELECT is((SELECT node_name FROM mdm.sandbox_node(pg_temp.id('f0f2'), pg_temp.id('c022'), '2030-06-01')),
  'SO C other', 'After rebase the overlay shows the other request''s change');
SELECT is(pg_temp.facts(), (SELECT facts FROM snap WHERE label = 'after_other'),
  'Refresh, conflicts and rebase changed no fact row');

-- ================================================================ 4. incremental refresh
SELECT is((SELECT setting_value FROM mdm.system_setting WHERE setting_key = 'sandbox_incremental_threshold'), '1000',
  'Above 1 000 items a new last item may be refreshed on its own (LLD §7.1)');
UPDATE mdm.system_setting SET setting_value = '2' WHERE setting_key = 'sandbox_incremental_threshold';   -- test only; rolled back

INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, property_id, payload) VALUES
  (pg_temp.id('f0f3'), 1, 'set_property', pg_temp.id('d0d2'), pg_temp.id('c023'), pg_temp.id('e0e2'), '{"value": "d1"}'),
  (pg_temp.id('f0f3'), 2, 'set_property', pg_temp.id('d0d2'), pg_temp.id('c024'), pg_temp.id('e0e2'),
   '{"value": "e1", "expected": {"present": true}}');
SELECT is((SELECT string_agg(seq || ':' || error_code, ',' ORDER BY seq) FROM mdm.refresh_sandbox_delta(pg_temp.id('f0f3'))),
  '2:N3001', 'A full refresh reports the failing item');

INSERT INTO mdm.change_item (change_item_id, change_request_id, seq, action, hierarchy_id, node_id, payload)
VALUES (pg_temp.id('9003'), pg_temp.id('f0f3'), 3, 'update_node', pg_temp.id('d0d2'), pg_temp.id('c021'),
        '{"name": "SO T2b", "expected": {"name": "SO T2"}}');
SET LOCAL ROLE nexus_api;
SELECT is((SELECT count(*)::int FROM mdm.refresh_sandbox_delta('00000000-0000-0000-0000-00000023f0f3',
                                                               '00000000-0000-0000-0000-000000239003')), 0,
  'Above the threshold, a new last item on a node no earlier item touched is tried on its own: only its outcome is reported');
RESET ROLE;
CREATE TEMP TABLE delta_inc AS SELECT pg_temp.delta(pg_temp.id('f0f3')) AS x;
SELECT is((SELECT count(*)::int FROM mdm.refresh_sandbox_delta(pg_temp.id('f0f3'))), 1, 'A full refresh still finds the earlier failure');
SELECT set_eq($$SELECT x FROM delta_inc$$, $$SELECT pg_temp.delta(pg_temp.id('f0f3'))$$,
  'The overlay the new item was appended to equals the full refresh''s');

INSERT INTO mdm.change_item (change_item_id, change_request_id, seq, action, hierarchy_id, node_id, property_id, payload)
VALUES (pg_temp.id('9004'), pg_temp.id('f0f3'), 4, 'set_property', pg_temp.id('d0d2'), pg_temp.id('c023'), pg_temp.id('e0e2'),
        '{"value": "d2"}');
SELECT is((SELECT string_agg(seq || ':' || error_code, ',' ORDER BY seq) FROM mdm.refresh_sandbox_delta(pg_temp.id('f0f3'), pg_temp.id('9004'))),
  '2:N3001', 'A new item on a node an earlier item touched is refreshed in full');
INSERT INTO mdm.change_item (change_item_id, change_request_id, seq, action, hierarchy_id, node_id, payload)
VALUES (pg_temp.id('9005'), pg_temp.id('f0f3'), 5, 'update_node', pg_temp.id('d0d2'), pg_temp.id('c024'), '{"name": "SO T2b"}');
SELECT is((SELECT string_agg(seq || ':' || error_code, ',' ORDER BY seq) FROM mdm.refresh_sandbox_delta(pg_temp.id('f0f3'), pg_temp.id('9005'))),
  '2:N3001,5:23P01', 'A new name that an earlier item uses falls back to a full refresh, which finds the clash');

-- ================================================================ 5. privileges, refusals, layer separation
SELECT is((SELECT count(*)::int FROM unnest(ARRAY[
             'mdm.refresh_sandbox_delta(uuid, uuid)', 'mdm.sandbox_conflicts(uuid)', 'mdm.rebase_sandbox(uuid, uuid)',
             'mdm.sandbox_children(uuid, uuid, uuid, date, numeric, text, uuid, integer)', 'mdm.sandbox_node(uuid, uuid, date)',
             'mdm.sandbox_placements(uuid, uuid, uuid, date)', 'mdm.sandbox_node_properties(uuid, uuid, uuid, date)']) f
           WHERE has_function_privilege('nexus_api', f, 'EXECUTE')),
  7, 'The API may refresh, list conflicts, rebase and read the overlay');
SELECT ok(NOT has_function_privilege('nexus_api', 'mdm.sandbox_trial(uuid, uuid[], boolean)', 'EXECUTE'),
  'The API cannot run a trial apply itself');
SELECT ok(NOT has_function_privilege('nexus_api', 'mdm.apply_capture(text, text, jsonb)', 'EXECUTE'),
  'nor call the capture hook');
SELECT ok(NOT has_function_privilege('nexus_readonly', 'mdm.refresh_sandbox_delta(uuid, uuid)', 'EXECUTE'),
  'A read-only role cannot refresh an overlay');
SELECT ok(NOT has_column_privilege('nexus_api', 'mdm.change_request', 'sandbox_base_recorded_at', 'UPDATE'),
  'The API still cannot move a base except through rebase');

SET LOCAL ROLE nexus_api;
SELECT throws_ok($$SELECT * FROM mdm.refresh_sandbox_delta('00000000-0000-0000-0000-00000023f0f1')$$,
  'N2303', NULL, 'A sandbox that became a request has no overlay to refresh (N2303)');
SELECT throws_ok($$SELECT * FROM mdm.sandbox_children('00000000-0000-0000-0000-00000023f0f1', '00000000-0000-0000-0000-00000023d0d1',
                                                     '00000000-0000-0000-0000-00000023c001', '2030-06-01')$$,
  'N2303', NULL, 'and no overlay to read (N2303)');
SELECT throws_ok($$SELECT * FROM mdm.rebase_sandbox('00000000-0000-0000-0000-00000023f0f1', '00000000-0000-0000-0000-00000023a0a1')$$,
  'N2303', NULL, 'or to rebase (N2303)');
SELECT lives_ok($$SELECT mdm.withdraw_change_request('00000000-0000-0000-0000-00000023f0f3', '00000000-0000-0000-0000-00000023a0a1')$$,
  'The owner discards a sandbox');
SELECT throws_ok($$SELECT * FROM mdm.refresh_sandbox_delta('00000000-0000-0000-0000-00000023f0f3')$$,
  'N2303', NULL, 'A discarded sandbox is no longer refreshed (N2303)');
SELECT throws_ok($$SELECT * FROM mdm.sandbox_conflicts('00000000-0000-0000-0000-00000023ffff')$$,
  'N2102', NULL, 'An unknown sandbox is reported as not found (N2102)');
RESET ROLE;

SELECT is((SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'mdm' AND p.proname IN ('refresh_sandbox_delta', 'sandbox_conflicts', 'rebase_sandbox')
             AND p.prosecdef AND pg_get_userbyid(p.proowner) = 'nexus_apply'),
  3, 'Refresh, conflicts and rebase run as nexus_apply, the fact writer whose trial is always rolled back');
SELECT is((SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'mdm' AND p.proname IN ('sandbox_children', 'sandbox_node', 'sandbox_placements', 'sandbox_node_properties')
             AND NOT p.prosecdef AND p.provolatile = 's'),
  4, 'The overlay reads run with the caller''s rights and write nothing (STABLE)');
SELECT is((SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'mdm' AND (p.proname LIKE '%sandbox%' OR p.proname = 'apply_capture')
             AND p.prosrc ~* '\mwf(_bridge)?\.'),
  0, 'No sandbox function refers to wf or wf_bridge (CLAUDE.md rule 3)');
SELECT is(pg_temp.facts(), (SELECT facts FROM snap WHERE label = 'after_other'),
  'No refresh, conflict check, rebase or discard changed a fact row');

SELECT * FROM finish();
ROLLBACK;
