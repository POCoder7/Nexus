-- pgTAP: query foundations (Phase 5 increment 5-9; QRY-01, PRP-06, VER-04; Phase 5 LLD §17.3.7, §17.4.5, §17.5.1, §17.10).
-- resolve_properties_batch gives node_properties_resolved's answer for many nodes at once; the filter language gains
-- groups, operators and attributes while export filters written as bare arrays keep their meaning; SQL refuses to read a
-- CEL-derived property it would see as NULL (N2805, N2806); a version's type never changes. Synthetic data only.
BEGIN;
SELECT plan(25);

-- ---------------------------------------------------------------- fixtures (synthetic)
CREATE FUNCTION pg_temp.id(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('00000000-0000-0000-0000-00000025' || p)::uuid
$$;

INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  (pg_temp.id('a0a1'), 'qf_admin', 'Query version admin', 'human'),
  (pg_temp.id('a0a2'), 'qf_granter', 'Granter', 'human');
INSERT INTO mdm.user_role (user_id, role_code, granted_by, valid_period)
VALUES (pg_temp.id('a0a1'), 'VERSION_ADMIN', pg_temp.id('a0a2'), daterange('2000-01-01', NULL));

-- A generated hierarchy QF_H: a top node, 3 regions, 9 groups and 27 leaves (ids c000 to c027 and d000 to d026 below),
-- plus one shared placement. Every row is recorded two days ago, so a past recorded time sees the same tree.
CREATE TEMP TABLE qf_tree (n text PRIMARY KEY, parent text, name text, limb boolean);
INSERT INTO qf_tree VALUES ('c000', NULL, 'QF Top', true);
INSERT INTO qf_tree SELECT 'c00' || g, 'c000', 'QF Region ' || g, true FROM generate_series(1, 3) g;
INSERT INTO qf_tree SELECT 'c1' || lpad(g::text, 2, '0'), 'c00' || ((g - 1) / 3 + 1), 'QF Group ' || g, true
FROM generate_series(1, 9) g;
INSERT INTO qf_tree SELECT 'd0' || lpad(g::text, 2, '0'), 'c1' || lpad(((g - 1) / 3 + 1)::text, 2, '0'), 'QF Leaf ' || g, false
FROM generate_series(1, 27) g;

INSERT INTO mdm.node (node_id, node_kind)
SELECT pg_temp.id(n), CASE WHEN limb THEN 'structural' ELSE 'legal_entity' END::mdm.node_kind FROM qf_tree;
INSERT INTO mdm.node_attr (node_id, node_name, description, allows_children, valid_period, recorded_period)
SELECT pg_temp.id(n), name, 'Synthetic ' || name, limb, daterange('2020-01-01', NULL), tstzrange(now() - interval '2 days', NULL)
FROM qf_tree;
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id, allow_shared_nodes)
VALUES (pg_temp.id('b0b1'), 'QF_H', 'Query foundations', pg_temp.id('c000'), true);
INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, is_primary, sort_order, valid_period, recorded_period)
SELECT pg_temp.id('b0b1'), pg_temp.id(parent), pg_temp.id(n), true, 1000, daterange('2020-01-01', NULL),
       tstzrange(now() - interval '2 days', NULL)
FROM qf_tree WHERE parent IS NOT NULL
UNION ALL
SELECT pg_temp.id('b0b1'), pg_temp.id('c003'), pg_temp.id('d001'), false, 9000, daterange('2020-01-01', NULL),
       tstzrange(now() - interval '2 days', NULL);

-- Properties of every kind the resolver handles, and one per filter data type.
INSERT INTO mdm.property_definition (property_id, property_code, label, data_type, scope, inheritance, default_value,
                                     origin, derivation_engine, derivation_expr) VALUES
  (pg_temp.id('e001'), 'QF.Ccy',    'Currency (inherited)', 'string',   'global', 'inherit_from_ancestor', '"XXX"', 'stored', NULL, NULL),
  (pg_temp.id('e002'), 'QF.Seg',    'Segment (local)',      'string',   'local',  'inherit_from_ancestor', NULL,    'stored', NULL, NULL),
  (pg_temp.id('e003'), 'QF.Note',   'Note',                 'memo',     'global', 'none',                  NULL,    'stored', NULL, NULL),
  (pg_temp.id('e004'), 'QF.AsOf',   'As-of (sql derived)',  'string',   'global', 'none',                  NULL,    'derived', 'sql', 'to_jsonb($3::text)'),
  (pg_temp.id('e005'), 'QF.Cel',    'CEL derived',          'string',   'global', 'none',                  NULL,    'derived', 'cel', 'node.name'),
  (pg_temp.id('e011'), 'QF.Str',    'String',               'string',   'global', 'none', NULL, 'stored', NULL, NULL),
  (pg_temp.id('e012'), 'QF.Int',    'Integer',              'integer',  'global', 'none', NULL, 'stored', NULL, NULL),
  (pg_temp.id('e013'), 'QF.Dec',    'Decimal',              'decimal',  'global', 'none', NULL, 'stored', NULL, NULL),
  (pg_temp.id('e014'), 'QF.Date',   'Date',                 'date',     'global', 'none', NULL, 'stored', NULL, NULL),
  (pg_temp.id('e015'), 'QF.Ts',     'Date and time',        'datetime', 'global', 'none', NULL, 'stored', NULL, NULL),
  (pg_temp.id('e016'), 'QF.Bool',   'Boolean',              'boolean',  'global', 'none', NULL, 'stored', NULL, NULL),
  (pg_temp.id('e017'), 'QF.Blank',  'Never set',            'string',   'global', 'none', NULL, 'stored', NULL, NULL);

-- Values: currency on the top and one region, overridden with an explicit blank on one group; a local segment on a
-- region; a note on some leaves; one currency value recorded wrongly and corrected yesterday (a past recorded time sees
-- the old value); the filter values on leaf d005.
INSERT INTO mdm.property_value (node_id, property_id, hierarchy_id, value, valid_period, recorded_period)
SELECT pg_temp.id(n), pg_temp.id(p), CASE WHEN p = 'e002' THEN pg_temp.id('b0b1') END, v::jsonb,
       daterange('2020-01-01', NULL), tstzrange(now() - interval '2 days', NULL)
FROM (VALUES ('c000', 'e001', '"EUR"'), ('c002', 'e001', '"USD"'), ('c104', 'e001', 'null'), ('c001', 'e002', '"Retail"'),
             ('d003', 'e003', '"first"'), ('d010', 'e003', '"second"'),
             ('d005', 'e011', '"Alpha Beta"'), ('d005', 'e012', '42'), ('d005', 'e013', '3.5'),
             ('d005', 'e014', '"2024-03-15"'), ('d005', 'e015', '"2024-03-15T10:00:00Z"'), ('d005', 'e016', 'true')) x(n, p, v);
INSERT INTO mdm.property_value (node_id, property_id, value, valid_period, recorded_period) VALUES
  (pg_temp.id('c003'), pg_temp.id('e001'), '"GBX"', daterange('2020-01-01', NULL), tstzrange(now() - interval '2 days', now() - interval '1 day')),
  (pg_temp.id('c003'), pg_temp.id('e001'), '"GBP"', daterange('2020-01-01', NULL), tstzrange(now() - interval '1 day', NULL));

CREATE TEMP TABLE qf_nodes AS SELECT pg_temp.id(n) AS node_id FROM qf_tree;
CREATE TEMP TABLE qf_props AS SELECT pg_temp.id(p) AS property_id
FROM unnest(ARRAY['e001', 'e002', 'e003', 'e004', 'e005', 'e011', 'e012', 'e013', 'e014', 'e015', 'e016', 'e017']) p;

-- ================================================================ resolve_properties_batch
SELECT set_eq(
  $$SELECT b.node_id, b.property_id, b.value, b.provenance, b.source_node_id, b.source_property_value_id
    FROM mdm.resolve_properties_batch((SELECT array_agg(node_id) FROM qf_nodes), '00000000-0000-0000-0000-00000025b0b1',
                                      '2025-06-01', NULL) b
    WHERE b.property_id IN (SELECT property_id FROM qf_props)$$,
  $$SELECT n.node_id, r.property_id, r.value, r.provenance, r.source_node_id, r.source_property_value_id
    FROM qf_nodes n CROSS JOIN LATERAL mdm.node_properties_resolved(n.node_id, '00000000-0000-0000-0000-00000025b0b1', '2025-06-01') r
    WHERE r.property_id IN (SELECT property_id FROM qf_props)$$,
  'The batch resolver equals node_properties_resolved row for row: stored, inherited, local, blank, default, derived');
SELECT set_eq(
  $$SELECT b.node_id, b.property_id, b.value, b.provenance, b.source_node_id
    FROM mdm.resolve_properties_batch((SELECT array_agg(node_id) FROM qf_nodes), '00000000-0000-0000-0000-00000025b0b1',
                                      '2025-06-01', now() - interval '36 hours') b
    WHERE b.property_id IN (SELECT property_id FROM qf_props)$$,
  $$SELECT n.node_id, r.property_id, r.value, r.provenance, r.source_node_id
    FROM qf_nodes n CROSS JOIN LATERAL mdm.node_properties_resolved(n.node_id, '00000000-0000-0000-0000-00000025b0b1',
                                                                    '2025-06-01', now() - interval '36 hours') r
    WHERE r.property_id IN (SELECT property_id FROM qf_props)$$,
  'and at a past recorded time, where the corrected value is not yet known');
SELECT set_eq(
  $$SELECT b.node_id, b.property_id, b.value, b.provenance
    FROM mdm.resolve_properties_batch((SELECT array_agg(node_id) FROM qf_nodes), NULL, '2025-06-01', NULL) b
    WHERE b.property_id IN (SELECT property_id FROM qf_props)$$,
  $$SELECT n.node_id, r.property_id, r.value, r.provenance
    FROM qf_nodes n CROSS JOIN LATERAL mdm.node_properties_resolved(n.node_id, NULL, '2025-06-01') r
    WHERE r.property_id IN (SELECT property_id FROM qf_props)$$,
  'and with no hierarchy (global properties only, nothing inherited)');
SELECT is((SELECT value #>> '{}' || '/' || provenance || '/' || (source_node_id = pg_temp.id('c003'))::text
           FROM mdm.resolve_properties_batch(ARRAY[pg_temp.id('d021')], pg_temp.id('b0b1'), '2025-06-01', NULL, ARRAY[pg_temp.id('e001')])),
  'GBP/inherited/true', 'A leaf under the corrected region inherits the corrected value from it');
SELECT is((SELECT count(*)::int FROM mdm.resolve_properties_batch(ARRAY[pg_temp.id('d001')], pg_temp.id('b0b1'), '2025-06-01', NULL,
                                                                ARRAY[pg_temp.id('e001'), pg_temp.id('e012')])),
  2, 'Asking for some properties returns only those');
SELECT is((SELECT coalesce(value::text, 'NULL') || '/' || provenance FROM mdm.resolve_properties_batch(ARRAY[pg_temp.id('d001')],
             pg_temp.id('b0b1'), '2025-06-01', NULL, ARRAY[pg_temp.id('e005')])),
  'NULL/derived', 'A CEL-derived property comes back empty and marked derived, for the Java resolver to fill');

-- ================================================================ the filter language
-- Every operator against every data type, on leaf d005 (QF Leaf 5, level 4, a leaf, active, a legal entity).
CREATE TEMP TABLE qf_cases (label text, filter jsonb, expected boolean);
INSERT INTO qf_cases VALUES
  ('string =',            '{"property": "QF.Str", "op": "=", "value": "Alpha Beta"}', true),
  ('string <>',           '{"property": "QF.Str", "op": "<>", "value": "Alpha"}', true),
  ('string in',           '{"property": "QF.Str", "op": "in", "value": ["x", "Alpha Beta"]}', true),
  ('string not_in',       '{"property": "QF.Str", "op": "not_in", "value": ["Alpha Beta"]}', false),
  ('string contains',     '{"property": "QF.Str", "op": "contains", "value": "ha Be"}', true),
  ('string contains case','{"property": "QF.Str", "op": "contains", "value": "alpha"}', false),
  ('string contains ci',  '{"property": "QF.Str", "op": "contains", "value": "ALPHA", "ci": true}', true),
  ('string starts_with',  '{"property": "QF.Str", "op": "starts_with", "value": "Alp"}', true),
  ('string ends_with',    '{"property": "QF.Str", "op": "ends_with", "value": "Beta"}', true),
  ('string like',         '{"property": "QF.Str", "op": "like", "value": "Al%Be_a"}', true),
  ('string gt (code point)', '{"property": "QF.Str", "op": "gt", "value": "Alpha"}', true),
  ('string between',      '{"property": "QF.Str", "op": "between", "value": ["A", "B"]}', true),
  ('integer =',           '{"property": "QF.Int", "op": "=", "value": 42}', true),
  ('integer gt',          '{"property": "QF.Int", "op": "gt", "value": 9}', true),
  ('integer gt numeric not text', '{"property": "QF.Int", "op": "lt", "value": 100}', true),
  ('integer between',     '{"property": "QF.Int", "op": "between", "value": [42, 50]}', true),
  ('integer le',          '{"property": "QF.Int", "op": "le", "value": 41}', false),
  ('decimal ge',          '{"property": "QF.Dec", "op": "ge", "value": 3.5}', true),
  ('decimal lt',          '{"property": "QF.Dec", "op": "lt", "value": 3.4}', false),
  ('decimal = 3.50',      '{"property": "QF.Dec", "op": "=", "value": 3.50}', true),
  ('date gt',             '{"property": "QF.Date", "op": "gt", "value": "2024-03-01"}', true),
  ('date between',        '{"property": "QF.Date", "op": "between", "value": ["2024-03-15", "2024-03-31"]}', true),
  ('date lt',             '{"property": "QF.Date", "op": "lt", "value": "2024-03-15"}', false),
  ('datetime ge',         '{"property": "QF.Ts", "op": "ge", "value": "2024-03-15T05:00:00-05:00"}', true),
  ('datetime gt',         '{"property": "QF.Ts", "op": "gt", "value": "2024-03-15T10:00:00Z"}', false),
  ('boolean =',           '{"property": "QF.Bool", "op": "=", "value": true}', true),
  ('boolean <>',          '{"property": "QF.Bool", "op": "<>", "value": true}', false),
  ('no value is_null',    '{"property": "QF.Blank", "op": "is_null"}', true),
  ('no value not_null',   '{"property": "QF.Blank", "op": "not_null"}', false),
  ('no value <>',         '{"property": "QF.Blank", "op": "<>", "value": "x"}', true),
  ('no value contains',   '{"property": "QF.Blank", "op": "contains", "value": ""}', false),
  ('no value gt',         '{"property": "QF.Blank", "op": "gt", "value": "A"}', false),
  ('inherited value =',   '{"property": "QF.Ccy", "op": "=", "value": "EUR"}', true),
  ('blank override is_null', '{"property": "QF.Ccy", "op": "is_null"}', false),
  ('attribute name starts_with ci', '{"attribute": "name", "op": "starts_with", "value": "qf leaf", "ci": true}', true),
  ('attribute description contains', '{"attribute": "description", "op": "contains", "value": "Synthetic"}', true),
  ('attribute kind =',    '{"attribute": "kind", "op": "=", "value": "legal_entity"}', true),
  ('attribute level =',   '{"attribute": "level", "op": "=", "value": 4}', true),
  ('attribute level ge',  '{"attribute": "level", "op": "ge", "value": 5}', false),
  ('attribute isLeaf',    '{"attribute": "isLeaf", "op": "=", "value": true}', true),
  ('attribute isActive',  '{"attribute": "isActive", "op": "=", "value": false}', false),
  ('group all',           '{"all": [{"property": "QF.Int", "op": "=", "value": 42}, {"attribute": "isLeaf", "op": "=", "value": true}]}', true),
  ('group any',           '{"any": [{"property": "QF.Int", "op": "=", "value": 1}, {"property": "QF.Dec", "op": "=", "value": 3.5}]}', true),
  ('group any none',      '{"any": [{"property": "QF.Int", "op": "=", "value": 1}, {"property": "QF.Dec", "op": "=", "value": 1}]}', false),
  ('nested groups',       '{"all": [{"any": [{"property": "QF.Int", "op": "=", "value": 1}, {"all": [{"attribute": "level", "op": "=", "value": 4},
                              {"any": [{"property": "QF.Str", "op": "ends_with", "value": "Beta"}]}]}]},
                              {"property": "QF.Bool", "op": "=", "value": true}]}', true),
  ('empty all',           '{"all": []}', true),
  ('empty any',           '{"any": []}', false),
  ('bare array (export filter), all hold', '[{"property": "QF.Int", "op": "=", "value": 42}, {"property": "QF.Str", "op": "not_null"}]', true),
  ('bare array (export filter), one fails', '[{"property": "QF.Int", "op": "=", "value": 42}, {"property": "QF.Str", "op": "is_null"}]', false),
  ('empty bare array',    '[]', true);
SELECT is_empty(
  $$SELECT label FROM qf_cases
    WHERE mdm.node_passes_filter('00000000-0000-0000-0000-00000025d005', '00000000-0000-0000-0000-00000025b0b1', filter,
                                 '2025-06-01', now()) IS DISTINCT FROM expected$$,
  'Every operator, data type, attribute and group gives the expected answer (failures are listed by label)');
SELECT is((SELECT count(*)::int FROM qf_cases), 50, 'and all 50 cases ran');
SELECT is((SELECT count(*)::int FROM qf_nodes n WHERE mdm.node_passes_filter(n.node_id, pg_temp.id('b0b1'),
             '{"attribute": "level", "op": "=", "value": 2}', '2025-06-01', now())), 3,
  'level counts along the primary path: the three regions are level 2');
SELECT is((SELECT count(*)::int FROM qf_nodes n WHERE mdm.node_passes_filter(n.node_id, pg_temp.id('b0b1'),
             '{"attribute": "isLeaf", "op": "=", "value": true}', '2025-06-01', now())), 27,
  'isLeaf is "no children in this hierarchy": the 27 leaves');

-- refusals
SELECT throws_ok($$SELECT mdm.node_passes_filter('00000000-0000-0000-0000-00000025d005', NULL, '{"property": "QF.Str", "op": "regex", "value": "x"}', '2025-06-01', now())$$,
  'N2604', NULL, 'An unknown operator is refused (N2604)');
SELECT throws_ok($$SELECT mdm.node_passes_filter('00000000-0000-0000-0000-00000025d005', NULL, '{"property": "QF.Nope", "op": "is_null"}', '2025-06-01', now())$$,
  'N2605', NULL, 'An unknown property is refused (N2605)');
SELECT throws_ok($$SELECT mdm.node_passes_filter('00000000-0000-0000-0000-00000025d005', NULL, '{"attribute": "colour", "op": "is_null"}', '2025-06-01', now())$$,
  'N2605', NULL, 'and so is an unknown attribute');
SELECT throws_ok($$SELECT mdm.node_passes_filter('00000000-0000-0000-0000-00000025d005', NULL,
                     '{"all": [{"all": [{"all": [{"all": [{"all": [{"all": [{"property": "QF.Str", "op": "is_null"}]}]}]}]}]}]}', '2025-06-01', now())$$,
  'N2807', NULL, 'Groups nest at most 5 deep (N2807)');
SELECT throws_ok(format($$SELECT mdm.node_passes_filter('00000000-0000-0000-0000-00000025d005', NULL, %L, '2025-06-01', now())$$,
                        (SELECT jsonb_agg('{"property": "QF.Str", "op": "not_null"}'::jsonb) FROM generate_series(1, 51))),
  'N2807', NULL, 'A filter has at most 50 conditions (N2807)');
SELECT throws_ok($$SELECT mdm.node_passes_filter('00000000-0000-0000-0000-00000025d005', NULL, '{"property": "QF.Int", "op": "between", "value": [1]}', '2025-06-01', now())$$,
  'N2807', NULL, 'between needs two bounds (N2807)');
SELECT throws_ok($$SELECT mdm.node_passes_filter('00000000-0000-0000-0000-00000025d005', NULL, '{"property": "QF.Cel", "op": "not_null"}', '2025-06-01', now())$$,
  'N2806', NULL, 'SQL refuses a condition on a CEL-derived property, which it would read as empty (N2806)');

-- exports
INSERT INTO mdm.version (version_id, version_name, business_as_of) VALUES (pg_temp.id('f0f1'), 'QF_VERSION', '2025-06-01');
INSERT INTO mdm.export_profile (export_profile_id, profile_code, profile_name, export_type, hierarchy_id, node_filter) VALUES
  (pg_temp.id('f101'), 'QF_LEAVES', 'Leaves with a note', 'hierarchy', pg_temp.id('b0b1'), '[{"property": "QF.Note", "op": "not_null"}]'),
  (pg_temp.id('f102'), 'QF_CEL_COL', 'A CEL column', 'hierarchy', pg_temp.id('b0b1'), '[]'),
  (pg_temp.id('f103'), 'QF_CEL_FILTER', 'A CEL filter', 'hierarchy', pg_temp.id('b0b1'), '{"any": [{"property": "QF.Cel", "op": "not_null"}]}');
INSERT INTO mdm.export_profile_column (export_profile_id, seq, header_label, column_source, property_id) VALUES
  (pg_temp.id('f101'), 1, 'Name', 'node_name', NULL), (pg_temp.id('f101'), 2, 'Note', 'property', pg_temp.id('e003')),
  (pg_temp.id('f102'), 1, 'Name', 'node_name', NULL), (pg_temp.id('f102'), 2, 'Cel', 'property', pg_temp.id('e005'));
SELECT is((SELECT string_agg(line, '|' ORDER BY line_no) FROM mdm.export_drm('QF_LEAVES', 'QF_VERSION')),
  'Name,Note|QF Leaf 3,first|QF Leaf 10,second', 'An export with a bare-array filter gives the same rows as before, in hierarchy order');
SELECT throws_ok($$SELECT * FROM mdm.export_drm('QF_CEL_COL', 'QF_VERSION')$$, 'N2805', NULL,
  'An export profile with a CEL-derived column must run through the export service (N2805)');
SELECT throws_ok($$SELECT * FROM mdm.export_drm('QF_CEL_FILTER', 'QF_VERSION')$$, 'N2805', NULL,
  'and so must one that filters on a CEL-derived property, even inside a group');

-- ================================================================ version types and the hard limit
SELECT is((SELECT version_type FROM mdm.version WHERE version_id = pg_temp.id('f0f1')), 'normal', 'A version is normal unless created as another type');
CREATE TEMP TABLE qf_baseline AS
SELECT mdm.create_version('QF_BASELINE', '2025-06-01', NULL, 'Kept for compares', pg_temp.id('a0a1'), 'baseline') AS version_id;
SELECT is((SELECT v.version_type FROM mdm.version v JOIN qf_baseline b USING (version_id)),
  'baseline', 'A version administrator creates a baseline');
SELECT throws_ok($$UPDATE mdm.version SET version_type = 'normal' WHERE version_name = 'QF_BASELINE'$$, 'N2701', NULL,
  'A version''s type never changes (N2701)');
SELECT ok((SELECT bool_or(pg_get_constraintdef(c.oid) LIKE '%set_property_derivation%') FROM pg_constraint c
           WHERE c.conrelid = 'wf.commit_policy'::regclass AND c.contype = 'c'),
  'No commit policy may allow a formula change: it is on the hard-limit list');
SELECT is((SELECT count(*)::int FROM mdm.system_setting WHERE setting_key IN ('cel_max_expr_chars', 'cel_max_iterations', 'query_scan_max',
             'query_max_conditions', 'query_max_columns', 'saved_query_max_per_user', 'compare_parallelism', 'compare_timeout_min',
             'compare_result_ttl_h')),
  9, 'The §17.15 limits are settings');

SELECT * FROM finish();
ROLLBACK;
