-- pgTAP: resolved properties with provenance (Phase 1 LLD §7.6, D-18, D-40). Values must equal property_value_asof,
-- which exports depend on. Tree (synthetic): T (top) -> A -> B, hierarchy P_H.
BEGIN;
SELECT plan(12);

INSERT INTO mdm.node (node_id, node_kind) VALUES
  ('00000000-0000-0000-0000-0000000007c1', 'structural'),
  ('00000000-0000-0000-0000-0000000007c2', 'legal_entity'),
  ('00000000-0000-0000-0000-0000000007c3', 'legal_entity');
INSERT INTO mdm.node_attr (node_id, node_name) VALUES
  ('00000000-0000-0000-0000-0000000007c1', 'P_T'), ('00000000-0000-0000-0000-0000000007c2', 'P_A'),
  ('00000000-0000-0000-0000-0000000007c3', 'P_B');
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id)
VALUES ('00000000-0000-0000-0000-0000000007d1', 'P_H', 'Resolution', '00000000-0000-0000-0000-0000000007c1');
INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id) VALUES
  ('00000000-0000-0000-0000-0000000007d1', '00000000-0000-0000-0000-0000000007c1', '00000000-0000-0000-0000-0000000007c2'),
  ('00000000-0000-0000-0000-0000000007d1', '00000000-0000-0000-0000-0000000007c2', '00000000-0000-0000-0000-0000000007c3');

INSERT INTO mdm.property_definition (property_id, property_code, label, data_type, scope, inheritance, default_value, origin, derivation_engine, derivation_expr) VALUES
  ('00000000-0000-0000-0000-0000000007e1', 'P.Inh',   'Inherited global', 'string', 'global', 'inherit_from_ancestor', '"dflt"', 'stored', NULL, NULL),
  ('00000000-0000-0000-0000-0000000007e2', 'P.Loc',   'Inherited local',  'string', 'local',  'inherit_from_ancestor', NULL,     'stored', NULL, NULL),
  ('00000000-0000-0000-0000-0000000007e3', 'P.Plain', 'Plain with default', 'string', 'global', 'none',              '"x"',    'stored', NULL, NULL),
  ('00000000-0000-0000-0000-0000000007e4', 'P.None',  'No value anywhere', 'string', 'global', 'none',               NULL,     'stored', NULL, NULL),
  ('00000000-0000-0000-0000-0000000007e5', 'P.Der',   'Derived',          'string', 'global', 'none',                NULL,     'derived', 'sql', $q$'"d"'$q$);

INSERT INTO mdm.property_value (node_id, property_id, hierarchy_id, value) VALUES
  ('00000000-0000-0000-0000-0000000007c1', '00000000-0000-0000-0000-0000000007e1', NULL, '"T-val"'),
  ('00000000-0000-0000-0000-0000000007c3', '00000000-0000-0000-0000-0000000007e1', NULL, 'null'),      -- explicit blank override
  ('00000000-0000-0000-0000-0000000007c1', '00000000-0000-0000-0000-0000000007e2', '00000000-0000-0000-0000-0000000007d1', '"loc"');

CREATE TEMP VIEW r AS
SELECT n.node_id, x.*
FROM (VALUES ('00000000-0000-0000-0000-0000000007c1'::uuid), ('00000000-0000-0000-0000-0000000007c2'::uuid),
             ('00000000-0000-0000-0000-0000000007c3'::uuid)) AS n(node_id)
CROSS JOIN LATERAL mdm.node_properties_resolved(n.node_id, '00000000-0000-0000-0000-0000000007d1', current_date, now()) x;

SELECT is((SELECT provenance || ':' || value::text || ':' || source_node_id::text FROM r
           WHERE node_id = '00000000-0000-0000-0000-0000000007c2' AND property_id = '00000000-0000-0000-0000-0000000007e1'),
          'inherited:"T-val":00000000-0000-0000-0000-0000000007c1', 'A inherits P.Inh from T, and says so');
SELECT is((SELECT provenance || ':' || value::text FROM r
           WHERE node_id = '00000000-0000-0000-0000-0000000007c3' AND property_id = '00000000-0000-0000-0000-0000000007e1'),
          'stored:null', 'B''s explicit blank is stored and blocks inheritance');
SELECT is((SELECT provenance FROM r
           WHERE node_id = '00000000-0000-0000-0000-0000000007c1' AND property_id = '00000000-0000-0000-0000-0000000007e1'),
          'stored', 'T''s own value is stored');
SELECT is((SELECT provenance || ':' || value::text FROM r
           WHERE node_id = '00000000-0000-0000-0000-0000000007c2' AND property_id = '00000000-0000-0000-0000-0000000007e3'),
          'default:"x"', 'A gets the default where nothing is stored and nothing inherits');
SELECT is((SELECT provenance || ':' || value::text FROM r
           WHERE node_id = '00000000-0000-0000-0000-0000000007c3' AND property_id = '00000000-0000-0000-0000-0000000007e2'),
          'inherited:"loc"', 'B inherits the local property through two levels');
SELECT is((SELECT provenance || ':' || coalesce(value::text, 'SQL NULL') FROM r
           WHERE node_id = '00000000-0000-0000-0000-0000000007c2' AND property_id = '00000000-0000-0000-0000-0000000007e4'),
          'none:SQL NULL', 'A property with no value anywhere is reported as none');
SELECT is((SELECT provenance || ':' || value::text FROM r
           WHERE node_id = '00000000-0000-0000-0000-0000000007c2' AND property_id = '00000000-0000-0000-0000-0000000007e5'),
          'derived:"d"', 'A derived property is computed and marked derived');

SELECT is_empty(
  $$SELECT r.node_id, r.property_id FROM r
    WHERE r.value IS DISTINCT FROM mdm.property_value_asof(r.node_id, r.property_id, '00000000-0000-0000-0000-0000000007d1', current_date, now())$$,
  'Every resolved value equals property_value_asof (with a hierarchy)');

SELECT is_empty(
  $$SELECT x.property_id
    FROM mdm.node_properties_resolved('00000000-0000-0000-0000-0000000007c2', NULL, current_date, now()) x
    WHERE x.value IS DISTINCT FROM mdm.property_value_asof('00000000-0000-0000-0000-0000000007c2', x.property_id, NULL, current_date, now())$$,
  'Every resolved value equals property_value_asof (without a hierarchy)');

SELECT ok(
  NOT EXISTS (SELECT 1 FROM mdm.node_properties_resolved('00000000-0000-0000-0000-0000000007c2', NULL, current_date, now())
              WHERE property_id = '00000000-0000-0000-0000-0000000007e2'),
  'Local properties are left out when no hierarchy is given');

SELECT is((SELECT provenance FROM mdm.node_properties_resolved('00000000-0000-0000-0000-0000000007c2', NULL, current_date, now())
           WHERE property_id = '00000000-0000-0000-0000-0000000007e1'),
          'default', 'Without a hierarchy nothing inherits (same rule as property_value_asof)');

SELECT is((SELECT source_property_value_id IS NOT NULL FROM r
           WHERE node_id = '00000000-0000-0000-0000-0000000007c2' AND property_id = '00000000-0000-0000-0000-0000000007e1'),
          true, 'An inherited value points at the stored row it came from');

SELECT * FROM finish();
ROLLBACK;
