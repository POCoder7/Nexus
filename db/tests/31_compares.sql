-- pgTAP: compares (QRY-02; Phase 5 LLD §17.4, increment 5-12). One synthetic hierarchy with known edits on 2024-06-01;
-- comparing 2024-01-01 (left) with 2025-01-01 (right) must report exactly those edits. Synthetic data only.
BEGIN;
SELECT plan(14);

INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-0000000031a1', 'cmp_user', 'Comparer', 'human');
-- top, A, B (parents), move (A → B), gone (until June), new (from June), shared (under A; also under B from June)
INSERT INTO mdm.node (node_id, node_kind) VALUES
  ('00000000-0000-0000-0000-0000000031c0', 'structural'), ('00000000-0000-0000-0000-0000000031c1', 'structural'),
  ('00000000-0000-0000-0000-0000000031c2', 'structural'), ('00000000-0000-0000-0000-0000000031c3', 'legal_entity'),
  ('00000000-0000-0000-0000-0000000031c4', 'legal_entity'), ('00000000-0000-0000-0000-0000000031c5', 'legal_entity'),
  ('00000000-0000-0000-0000-0000000031c6', 'legal_entity');
INSERT INTO mdm.node_attr (node_id, node_name, valid_period) VALUES
  ('00000000-0000-0000-0000-0000000031c0', 'CMP top', daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-0000000031c1', 'CMP A', daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-0000000031c2', 'CMP B', daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-0000000031c3', 'CMP mover', daterange('2020-01-01', '2024-06-01')),
  ('00000000-0000-0000-0000-0000000031c3', 'CMP mover renamed', daterange('2024-06-01', NULL)),
  ('00000000-0000-0000-0000-0000000031c4', 'CMP gone', daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-0000000031c5', 'CMP new', daterange('2024-06-01', NULL)),
  ('00000000-0000-0000-0000-0000000031c6', 'CMP shared', daterange('2020-01-01', NULL));
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id, allow_shared_nodes)
VALUES ('00000000-0000-0000-0000-0000000031d1', 'CMP_H', 'Compare', '00000000-0000-0000-0000-0000000031c0', true);
INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, is_primary, valid_period) VALUES
  ('00000000-0000-0000-0000-0000000031d1', '00000000-0000-0000-0000-0000000031c0', '00000000-0000-0000-0000-0000000031c1', true, daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-0000000031d1', '00000000-0000-0000-0000-0000000031c0', '00000000-0000-0000-0000-0000000031c2', true, daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-0000000031d1', '00000000-0000-0000-0000-0000000031c1', '00000000-0000-0000-0000-0000000031c3', true, daterange('2020-01-01', '2024-06-01')),
  ('00000000-0000-0000-0000-0000000031d1', '00000000-0000-0000-0000-0000000031c2', '00000000-0000-0000-0000-0000000031c3', true, daterange('2024-06-01', NULL)),
  ('00000000-0000-0000-0000-0000000031d1', '00000000-0000-0000-0000-0000000031c1', '00000000-0000-0000-0000-0000000031c4', true, daterange('2020-01-01', '2024-06-01')),
  ('00000000-0000-0000-0000-0000000031d1', '00000000-0000-0000-0000-0000000031c2', '00000000-0000-0000-0000-0000000031c5', true, daterange('2024-06-01', NULL)),
  ('00000000-0000-0000-0000-0000000031d1', '00000000-0000-0000-0000-0000000031c1', '00000000-0000-0000-0000-0000000031c6', true, daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-0000000031d1', '00000000-0000-0000-0000-0000000031c2', '00000000-0000-0000-0000-0000000031c6', false, daterange('2024-06-01', NULL));
INSERT INTO mdm.property_definition (property_id, property_code, label, data_type, scope, inheritance)
VALUES ('00000000-0000-0000-0000-0000000031e1', 'CMP.Ccy', 'Currency', 'string', 'global', 'inherit_from_ancestor');
INSERT INTO mdm.property_value (node_id, property_id, value, valid_period) VALUES
  ('00000000-0000-0000-0000-0000000031c0', '00000000-0000-0000-0000-0000000031e1', '"EUR"', daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-0000000031c2', '00000000-0000-0000-0000-0000000031e1', '"USD"', daterange('2024-06-01', NULL));

-- A run over the two dates, as the API creates it; then filled.
CREATE FUNCTION pg_temp.run(p_id text, p_left date, p_right date, p_options jsonb DEFAULT '{}') RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO mdm.compare_run (compare_run_id, requested_by, definition, slice_key, is_frozen, expires_at)
  VALUES (('00000000-0000-0000-0000-0000000031' || p_id)::uuid, '00000000-0000-0000-0000-0000000031a1',
          jsonb_build_object('left', jsonb_build_object('hierarchyId', '00000000-0000-0000-0000-0000000031d1', 'asOf', p_left, 'recordedAsOf', now()),
                             'right', jsonb_build_object('hierarchyId', '00000000-0000-0000-0000-0000000031d1', 'asOf', p_right, 'recordedAsOf', now()),
                             'kinds', '["structure", "rename", "property"]'::jsonb) || p_options,
          p_id, false, now() + interval '1 day')
  RETURNING compare_run_id
$$;
CREATE FUNCTION pg_temp.rows(p_id text, p_kind text) RETURNS SETOF text LANGUAGE sql AS $$
  SELECT node_name || ':' || coalesce(detail ->> 'change', detail ->> 'propertyCode', 'rename')
  FROM mdm.compare_row WHERE compare_run_id = ('00000000-0000-0000-0000-0000000031' || p_id)::uuid AND kind = p_kind
$$;

SELECT pg_temp.run('f1', '2024-01-01', '2025-01-01');
SELECT is(mdm.compare_fill('00000000-0000-0000-0000-0000000031f1'),
  '{"structure": 4, "rename": 1, "property": 2}'::jsonb, 'The run is filled and reports its counts per kind');
SELECT is((SELECT status FROM mdm.compare_run WHERE compare_run_id = '00000000-0000-0000-0000-0000000031f1'), 'done', '… and is done');
SELECT set_eq($$SELECT pg_temp.rows('f1', 'structure')$$,
  $$VALUES ('CMP new:added'), ('CMP gone:removed'), ('CMP mover renamed:moved'), ('CMP shared:shared_added')$$,
  'Structure: added, removed, moved, and a shared placement added');
SELECT is((SELECT detail ->> 'leftParentName' || ' → ' || (detail ->> 'rightParentName') FROM mdm.compare_row
           WHERE compare_run_id = '00000000-0000-0000-0000-0000000031f1' AND detail ->> 'change' = 'moved'),
  'CMP A → CMP B', 'A move names the old and the new parent');
SELECT set_eq($$SELECT pg_temp.rows('f1', 'rename')$$, $$VALUES ('CMP mover renamed:rename')$$,
  'Rename: the same node under a new name is a rename, not a removal and an addition');
SELECT is((SELECT detail ->> 'leftName' FROM mdm.compare_row WHERE compare_run_id = '00000000-0000-0000-0000-0000000031f1' AND kind = 'rename'),
  'CMP mover', '… with the old name');
SELECT set_eq($$SELECT pg_temp.rows('f1', 'property')$$,
  $$VALUES ('CMP B:CMP.Ccy'), ('CMP mover renamed:CMP.Ccy')$$,
  'Property: B''s new value and the mover''s inherited one; the shared node inherits through its primary parent (A, still EUR)');
SELECT results_eq($$SELECT detail ->> 'leftValue', detail ->> 'rightValue', detail ->> 'leftProvenance', detail ->> 'rightProvenance'
                    FROM mdm.compare_row WHERE compare_run_id = '00000000-0000-0000-0000-0000000031f1' AND kind = 'property'
                      AND node_name = 'CMP mover renamed'$$,
  $$VALUES ('EUR', 'USD', 'inherited', 'inherited')$$,
  'An inherited value that changed shows both values and where each came from');

-- Boundaries and options
SELECT pg_temp.run('f2', '2025-01-01', '2025-01-01');
SELECT is(mdm.compare_fill('00000000-0000-0000-0000-0000000031f2'), '{"structure": 0, "rename": 0, "property": 0}'::jsonb,
  'Identical slices give no rows');
SELECT pg_temp.run('f3', '2024-01-01', '2025-01-01', '{"subtreeRootId": "00000000-0000-0000-0000-0000000031c2", "kinds": ["structure"]}');
SELECT mdm.compare_fill('00000000-0000-0000-0000-0000000031f3');
SELECT set_eq($$SELECT pg_temp.rows('f3', 'structure')$$,
  $$VALUES ('CMP new:added'), ('CMP mover renamed:added'), ('CMP shared:shared_added')$$,
  'A sub-tree compare sees only what is under its root on each side (the mover arrives in B)');
SELECT throws_ok($$SELECT mdm.compare_fill('00000000-0000-0000-0000-0000000031f3')$$, 'N2808', NULL,
  'A run is filled once');

-- Two hierarchies: every node of the other hierarchy is "added" or "removed"
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id)
VALUES ('00000000-0000-0000-0000-0000000031d2', 'CMP_H2', 'Compare two', '00000000-0000-0000-0000-0000000031c1');
INSERT INTO mdm.compare_run (compare_run_id, requested_by, definition, slice_key, is_frozen, expires_at)
VALUES ('00000000-0000-0000-0000-0000000031f4', '00000000-0000-0000-0000-0000000031a1',
        jsonb_build_object('left', jsonb_build_object('hierarchyId', '00000000-0000-0000-0000-0000000031d1', 'asOf', '2025-01-01', 'recordedAsOf', now()),
                           'right', jsonb_build_object('hierarchyId', '00000000-0000-0000-0000-0000000031d2', 'asOf', '2025-01-01', 'recordedAsOf', now()),
                           'kinds', '["structure"]'::jsonb), 'f4', false, now() + interval '1 day');
SELECT mdm.compare_fill('00000000-0000-0000-0000-0000000031f4');
SELECT ok((SELECT count(*) FROM mdm.compare_row WHERE compare_run_id = '00000000-0000-0000-0000-0000000031f4'
           AND detail ->> 'change' = 'removed') = 5
          AND (SELECT detail ->> 'change' FROM mdm.compare_row WHERE compare_run_id = '00000000-0000-0000-0000-0000000031f4'
               AND node_name = 'CMP A') = 'moved',
  'Two hierarchies: the other''s nodes are removed, and its top (CMP A) moves from under the top to no parent');

-- Rows go with their run, and only the API writes runs
DELETE FROM mdm.compare_run WHERE compare_run_id = '00000000-0000-0000-0000-0000000031f1';
SELECT is((SELECT count(*)::int FROM mdm.compare_row WHERE compare_run_id = '00000000-0000-0000-0000-0000000031f1'), 0,
  'Deleting an expired run deletes its rows');
SET LOCAL ROLE nexus_readonly;
SELECT throws_ok($$INSERT INTO mdm.compare_row (compare_run_id, seq, kind, node_id, node_name, detail)
                   VALUES ('00000000-0000-0000-0000-0000000031f2', 99, 'rename', gen_random_uuid(), 'x', '{}')$$,
  '42501', NULL, 'A read-only role cannot write compare rows');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
