-- pgTAP: sandboxes, data layer (Phase 5 NEW-08, increment 5-1a; ADR-028; Phase 5 LLD §4, §9, §13).
-- The request kind and its one-way change at submit, the sandbox columns, origin and the item limit while drafting,
-- the delta tables and their privileges, layer separation, and that no sandbox operation changes a fact row.
-- Synthetic data only.
BEGIN;
SELECT plan(51);

-- ---------------------------------------------------------------- fixtures (synthetic)
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-0000000023a1', 'sbx_owner',   'Sandbox owner', 'human'),
  ('00000000-0000-0000-0000-0000000023a2', 'sbx_checker', 'Checker',       'human');
INSERT INTO mdm.version (version_id, version_name, business_as_of)
VALUES ('00000000-0000-0000-0000-0000000023b1', 'SBX_VERSION', current_date);
INSERT INTO mdm.node (node_id, node_kind) VALUES
  ('00000000-0000-0000-0000-0000000023c1', 'structural'),
  ('00000000-0000-0000-0000-0000000023c2', 'structural'),
  ('00000000-0000-0000-0000-0000000023c3', 'structural');
INSERT INTO mdm.node_attr (node_id, node_name, valid_period) VALUES
  ('00000000-0000-0000-0000-0000000023c1', 'SBX_TOP', daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-0000000023c2', 'SBX_A',   daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-0000000023c3', 'SBX_B',   daterange('2020-01-01', NULL));
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id)
VALUES ('00000000-0000-0000-0000-0000000023d1', 'SBX_H', 'Sandbox hierarchy', '00000000-0000-0000-0000-0000000023c1');
INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, valid_period) VALUES
  ('00000000-0000-0000-0000-0000000023d1', '00000000-0000-0000-0000-0000000023c1', '00000000-0000-0000-0000-0000000023c2', daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-0000000023d1', '00000000-0000-0000-0000-0000000023c1', '00000000-0000-0000-0000-0000000023c3', daterange('2020-01-01', NULL));
INSERT INTO mdm.property_definition (property_id, property_code, label, data_type, scope)
VALUES ('00000000-0000-0000-0000-0000000023e1', 'SBX.Code', 'Sandbox code', 'string', 'global');
INSERT INTO mdm.property_value (node_id, property_id, value, valid_period)
VALUES ('00000000-0000-0000-0000-0000000023c2', '00000000-0000-0000-0000-0000000023e1', '"OLD"', daterange('2020-01-01', NULL));

-- A fingerprint of every fact table and the outbox: any row inserted, closed or changed changes it (LLD §9).
-- mdm.node is left out on purpose: it holds identities only, and Phase 1 allocates them while drafting.
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
CREATE TEMP TABLE snap (label text PRIMARY KEY, facts text);
INSERT INTO snap VALUES ('before', pg_temp.facts());

-- ---------------------------------------------------------------- structure
SELECT has_column('mdm', 'change_request', 'kind', 'A change request has a kind');
SELECT col_default_is('mdm', 'change_request', 'kind', 'request', 'Its kind defaults to request');
SELECT has_column('mdm', 'change_request', 'sandbox_name', 'A sandbox has a name');
SELECT has_column('mdm', 'change_request', 'sandbox_base_recorded_at', 'A sandbox records the instant it is based on');
SELECT has_table('mdm', 'sandbox_delta_relationship', 'Overlay delta for placements');
SELECT has_table('mdm', 'sandbox_delta_node_attr', 'Overlay delta for node attributes');
SELECT has_table('mdm', 'sandbox_delta_value', 'Overlay delta for property values');
SELECT is((SELECT setting_value FROM mdm.system_setting WHERE setting_key = 'sandbox_max_items'), '20000',
  'A sandbox may hold up to 20 000 items (CR-04, F-2)');

-- ---------------------------------------------------------------- create (the API's rights)
SET LOCAL ROLE nexus_api;

SELECT lives_ok(
  $$INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind, effective_from)
    VALUES ('00000000-0000-0000-0000-0000000023f0', '00000000-0000-0000-0000-0000000023b1', 'SBX plain request',
            '00000000-0000-0000-0000-0000000023a1', 'human', '2030-01-01')$$,
  'An ordinary request is created as before');
SELECT lives_ok(
  $$INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind, effective_from,
                                    kind, origin, sandbox_name, sandbox_base_recorded_at)
    VALUES ('00000000-0000-0000-0000-0000000023f1', '00000000-0000-0000-0000-0000000023b1', 'SBX one',
            '00000000-0000-0000-0000-0000000023a1', 'human', '2030-01-01', 'sandbox', 'sandbox', 'Restructure one', now() - interval '1 day')$$,
  'The API creates a sandbox: a draft of kind sandbox and origin sandbox');
SELECT throws_ok(
  $$INSERT INTO mdm.change_request (version_id, title, requester_id, requester_kind, kind, origin, sandbox_name, sandbox_base_recorded_at)
    VALUES ('00000000-0000-0000-0000-0000000023b1', 'SBX bad origin', '00000000-0000-0000-0000-0000000023a1', 'human',
            'sandbox', 'user', 'Bad', now())$$,
  'N2303', NULL, 'A sandbox must have origin sandbox (N2303)');
SELECT throws_ok(
  $$INSERT INTO mdm.change_request (version_id, title, requester_id, requester_kind, origin)
    VALUES ('00000000-0000-0000-0000-0000000023b1', 'SBX sandbox origin', '00000000-0000-0000-0000-0000000023a1', 'human', 'sandbox')$$,
  'N2303', NULL, 'Origin sandbox, and its larger item limit, is reached only by creating a sandbox (N2303)');
SELECT throws_ok(
  $$INSERT INTO mdm.change_request (version_id, title, requester_id, requester_kind, status, kind, origin, sandbox_name, sandbox_base_recorded_at)
    VALUES ('00000000-0000-0000-0000-0000000023b1', 'SBX submitted', '00000000-0000-0000-0000-0000000023a1', 'human',
            'submitted', 'sandbox', 'sandbox', 'Bad', now())$$,
  'N2303', NULL, 'A sandbox is always created as a draft (N2303)');
SELECT throws_ok(
  $$INSERT INTO mdm.change_request (version_id, title, requester_id, requester_kind, kind, origin, sandbox_base_recorded_at)
    VALUES ('00000000-0000-0000-0000-0000000023b1', 'SBX no name', '00000000-0000-0000-0000-0000000023a1', 'human',
            'sandbox', 'sandbox', now())$$,
  '23514', NULL, 'A sandbox needs a name');
SELECT throws_ok(
  $$INSERT INTO mdm.change_request (version_id, title, requester_id, requester_kind, sandbox_name)
    VALUES ('00000000-0000-0000-0000-0000000023b1', 'SBX named request', '00000000-0000-0000-0000-0000000023a1', 'human', 'Named')$$,
  '23514', NULL, 'Only a sandbox, or a request made from one, carries sandbox fields');

RESET ROLE;

SELECT is((SELECT kind || '/' || origin FROM mdm.change_request WHERE change_request_id = '00000000-0000-0000-0000-0000000023f0'),
  'request/user', 'An ordinary request has kind request and origin user');
SELECT is((SELECT kind || '/' || origin || '/' || status FROM mdm.change_request WHERE change_request_id = '00000000-0000-0000-0000-0000000023f1'),
  'sandbox/sandbox/draft', 'A new sandbox is a draft of kind and origin sandbox');

-- ---------------------------------------------------------------- items and the limit while drafting (N2302)
UPDATE mdm.system_setting SET setting_value = '3' WHERE setting_key = 'sandbox_max_items';   -- test only; rolled back

SET LOCAL ROLE nexus_api;
SELECT lives_ok(
  $$INSERT INTO mdm.change_item (change_request_id, seq, action, node_id, property_id, payload)
    SELECT '00000000-0000-0000-0000-0000000023f1', s, 'set_property', '00000000-0000-0000-0000-0000000023c2',
           '00000000-0000-0000-0000-0000000023e1', jsonb_build_object('value', 'NEW' || s)
    FROM generate_series(1, 3) s$$,
  'Items up to the limit are added to a sandbox');
SELECT throws_ok(
  $$INSERT INTO mdm.change_item (change_request_id, seq, action, node_id, property_id, payload)
    VALUES ('00000000-0000-0000-0000-0000000023f1', 4, 'set_property', '00000000-0000-0000-0000-0000000023c2',
            '00000000-0000-0000-0000-0000000023e1', '{"value": "NEW4"}')$$,
  'N2302', NULL, 'One item over the limit is refused while drafting (N2302)');
SELECT throws_ok(
  $$INSERT INTO mdm.change_item (change_request_id, seq, action, node_id, property_id, payload)
    SELECT '00000000-0000-0000-0000-0000000023f1', s, 'set_property', '00000000-0000-0000-0000-0000000023c2',
           '00000000-0000-0000-0000-0000000023e1', jsonb_build_object('value', 'NEW' || s)
    FROM generate_series(5, 6) s$$,
  'N2302', NULL, 'A bulk insert over the limit is refused (N2302)');
SELECT lives_ok(
  $$INSERT INTO mdm.change_item (change_request_id, seq, action, node_id, property_id, payload)
    SELECT '00000000-0000-0000-0000-0000000023f0', s, 'set_property', '00000000-0000-0000-0000-0000000023c2',
           '00000000-0000-0000-0000-0000000023e1', jsonb_build_object('value', 'NEW' || s)
    FROM generate_series(1, 4) s$$,
  'An ordinary request is not bounded while drafting; apply bounds it (N2103)');
SELECT lives_ok(
  $$DELETE FROM mdm.change_item WHERE change_request_id = '00000000-0000-0000-0000-0000000023f1' AND seq = 3$$,
  'The owner removes an item from a sandbox');
SELECT lives_ok(
  $$INSERT INTO mdm.change_item (change_request_id, seq, action, node_id, property_id, payload)
    VALUES ('00000000-0000-0000-0000-0000000023f1', 3, 'set_property', '00000000-0000-0000-0000-0000000023c2',
            '00000000-0000-0000-0000-0000000023e1', '{"value": "NEW3b"}')$$,
  'Space freed by a removal can be used again');

-- Validation is a trial apply, always rolled back; on a sandbox it must leave the facts alone.
SELECT lives_ok(
  $$SELECT * FROM mdm.validate_change_request('00000000-0000-0000-0000-0000000023f1', '2030-01-01')$$,
  'A sandbox can be validated');

-- The API holds no right to change a request's kind or sandbox fields directly (5-1b adds the functions that do).
SELECT ok(NOT has_column_privilege('mdm.change_request', 'kind', 'UPDATE'), 'nexus_api cannot change a request''s kind');
SELECT ok(NOT has_column_privilege('mdm.change_request', 'sandbox_base_recorded_at', 'UPDATE'), 'nexus_api cannot move a sandbox''s base');
RESET ROLE;

UPDATE mdm.system_setting SET setting_value = '20000' WHERE setting_key = 'sandbox_max_items';

-- ---------------------------------------------------------------- the kind changes once, at submit (N2303)
SELECT throws_ok(
  $$UPDATE mdm.change_request SET status = 'submitted', submitted_at = now()
    WHERE change_request_id = '00000000-0000-0000-0000-0000000023f1'$$,
  'N2303', NULL, 'A sandbox cannot be submitted as it is; it must become a request first (N2303)');
SELECT throws_ok(
  $$UPDATE mdm.change_request SET status = 'in_review' WHERE change_request_id = '00000000-0000-0000-0000-0000000023f1'$$,
  'N2303', NULL, 'A sandbox cannot enter a workflow (N2303)');
SELECT throws_ok(
  $$UPDATE mdm.change_request SET kind = 'sandbox' WHERE change_request_id = '00000000-0000-0000-0000-0000000023f0'$$,
  'N2303', NULL, 'A request never becomes a sandbox (N2303)');
SELECT lives_ok(
  $$UPDATE mdm.change_request SET sandbox_base_recorded_at = now() WHERE change_request_id = '00000000-0000-0000-0000-0000000023f1'$$,
  'While a sandbox is a draft its base can move (rebase)');
SELECT lives_ok(
  $$UPDATE mdm.change_request SET kind = 'request', status = 'submitted', submitted_at = now()
    WHERE change_request_id = '00000000-0000-0000-0000-0000000023f1'$$,
  'At submit the sandbox becomes a request');
SELECT is((SELECT kind || '/' || origin || '/' || status || '/' || sandbox_name FROM mdm.change_request
           WHERE change_request_id = '00000000-0000-0000-0000-0000000023f1'),
  'request/sandbox/submitted/Restructure one', 'It keeps origin sandbox, so apply uses the sandbox limit (CR-04), and its name');
SELECT throws_ok(
  $$UPDATE mdm.change_request SET kind = 'sandbox' WHERE change_request_id = '00000000-0000-0000-0000-0000000023f1'$$,
  'N2303', NULL, 'The change is one way: a submitted request cannot go back to a sandbox (N2303)');
SELECT throws_ok(
  $$UPDATE mdm.change_request SET sandbox_name = 'Renamed' WHERE change_request_id = '00000000-0000-0000-0000-0000000023f1'$$,
  'N2102', NULL, 'Sandbox fields are frozen once the request leaves draft (N2102)');
SELECT throws_ok(
  $$UPDATE mdm.change_request SET sandbox_base_recorded_at = now() + interval '1 second'
    WHERE change_request_id = '00000000-0000-0000-0000-0000000023f1'$$,
  'N2102', NULL, 'So is its base');

-- Discard: a sandbox is withdrawn like any draft, and stays a sandbox.
INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind, effective_from,
                                kind, origin, sandbox_name, sandbox_base_recorded_at)
VALUES ('00000000-0000-0000-0000-0000000023f2', '00000000-0000-0000-0000-0000000023b1', 'SBX two',
        '00000000-0000-0000-0000-0000000023a1', 'human', '2030-01-01', 'sandbox', 'sandbox', 'Restructure two', now());
INSERT INTO mdm.change_item (change_request_id, seq, action, node_id, payload)
VALUES ('00000000-0000-0000-0000-0000000023f2', 1, 'update_node', '00000000-0000-0000-0000-0000000023c3', '{"name": "SBX_B2"}');
SET LOCAL ROLE nexus_api;
SELECT lives_ok(
  $$SELECT mdm.withdraw_change_request('00000000-0000-0000-0000-0000000023f2', '00000000-0000-0000-0000-0000000023a1')$$,
  'The owner discards a sandbox (withdraw)');
RESET ROLE;
SELECT is((SELECT kind || '/' || status FROM mdm.change_request WHERE change_request_id = '00000000-0000-0000-0000-0000000023f2'),
  'sandbox/withdrawn', 'A discarded sandbox is withdrawn and stays a sandbox');
SELECT throws_ok(
  $$UPDATE mdm.change_request SET kind = 'request' WHERE change_request_id = '00000000-0000-0000-0000-0000000023f2'$$,
  'N2303', NULL, 'A discarded sandbox cannot become a request (N2303)');

-- ---------------------------------------------------------------- delta tables (derived overlay)
INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind, effective_from,
                                kind, origin, sandbox_name, sandbox_base_recorded_at)
VALUES ('00000000-0000-0000-0000-0000000023f3', '00000000-0000-0000-0000-0000000023b1', 'SBX three',
        '00000000-0000-0000-0000-0000000023a1', 'human', '2030-01-01', 'sandbox', 'sandbox', 'Restructure three', now());

SET LOCAL ROLE nexus_api;
SELECT throws_ok(
  $$INSERT INTO mdm.sandbox_delta_relationship (sandbox_id, hierarchy_id, parent_node_id, child_node_id, is_primary, sort_order, valid_period, op)
    VALUES ('00000000-0000-0000-0000-0000000023f3', '00000000-0000-0000-0000-0000000023d1', '00000000-0000-0000-0000-0000000023c2',
            '00000000-0000-0000-0000-0000000023c3', true, 1000, daterange('2030-01-01', NULL), '+')$$,
  '42501', NULL, 'nexus_api cannot write the overlay; only the refresh does');
SELECT ok(has_table_privilege('mdm.sandbox_delta_value', 'SELECT'), 'nexus_api reads the overlay');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM unnest(ARRAY['mdm.sandbox_delta_relationship', 'mdm.sandbox_delta_node_attr', 'mdm.sandbox_delta_value']) t,
                  unnest(ARRAY['INSERT', 'DELETE']) p
           WHERE has_table_privilege('nexus_apply', t, p)),
  6, 'nexus_apply, which owns the trial apply, inserts and deletes overlay rows in all three tables');
SELECT ok(NOT has_table_privilege('nexus_apply', 'mdm.sandbox_delta_value', 'UPDATE'),
  'The overlay is rebuilt, never updated in place');

SET LOCAL ROLE nexus_apply;
SELECT lives_ok(
  $$INSERT INTO mdm.sandbox_delta_relationship (sandbox_id, hierarchy_id, parent_node_id, child_node_id, is_primary, sort_order, valid_period, op) VALUES
      ('00000000-0000-0000-0000-0000000023f3', '00000000-0000-0000-0000-0000000023d1', '00000000-0000-0000-0000-0000000023c1',
       '00000000-0000-0000-0000-0000000023c3', true, 1000, daterange('2020-01-01', NULL), '-'),
      ('00000000-0000-0000-0000-0000000023f3', '00000000-0000-0000-0000-0000000023d1', '00000000-0000-0000-0000-0000000023c1',
       '00000000-0000-0000-0000-0000000023c3', true, 1000, daterange('2020-01-01', '2030-01-01'), '+'),
      ('00000000-0000-0000-0000-0000000023f3', '00000000-0000-0000-0000-0000000023d1', '00000000-0000-0000-0000-0000000023c2',
       '00000000-0000-0000-0000-0000000023c3', true, 1000, daterange('2030-01-01', NULL), '+')$$,
  'A move is one closed placement and two new ones: the same pair, told apart by valid period');
SELECT lives_ok(
  $$INSERT INTO mdm.sandbox_delta_node_attr (sandbox_id, node_id, node_name, description, is_active, allows_children, valid_period, op)
    VALUES ('00000000-0000-0000-0000-0000000023f3', '00000000-0000-0000-0000-0000000023c3', 'SBX_B', NULL, true, true, daterange('2020-01-01', NULL), '-')$$,
  'Node attribute rows go to their delta table');
SELECT lives_ok(
  $$INSERT INTO mdm.sandbox_delta_value (sandbox_id, node_id, property_id, hierarchy_key, value, valid_period, op)
    VALUES ('00000000-0000-0000-0000-0000000023f3', '00000000-0000-0000-0000-0000000023c3', '00000000-0000-0000-0000-0000000023e1',
            '00000000-0000-0000-0000-000000000000', '"X"', daterange('2030-01-01', NULL), '+')$$,
  'Value rows go to theirs; a global value has the zero hierarchy key');
RESET ROLE;
SELECT throws_ok(
  $$INSERT INTO mdm.sandbox_delta_node_attr (sandbox_id, node_id, node_name, is_active, allows_children, valid_period, op)
    VALUES ('00000000-0000-0000-0000-0000000023f3', '00000000-0000-0000-0000-0000000023c2', 'SBX_A', true, true, daterange('2030-01-01', NULL), '*')$$,
  '23514', NULL, 'A delta row is either + or -');
DELETE FROM mdm.change_request WHERE change_request_id = '00000000-0000-0000-0000-0000000023f3';
SELECT is((SELECT count(*)::int FROM mdm.sandbox_delta_relationship WHERE sandbox_id = '00000000-0000-0000-0000-0000000023f3')
        + (SELECT count(*)::int FROM mdm.sandbox_delta_node_attr WHERE sandbox_id = '00000000-0000-0000-0000-0000000023f3')
        + (SELECT count(*)::int FROM mdm.sandbox_delta_value WHERE sandbox_id = '00000000-0000-0000-0000-0000000023f3'),
  0, 'Deleting a draft sandbox removes its overlay');

-- ---------------------------------------------------------------- layer separation (CLAUDE.md rule 3)
SELECT ok((SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'mdm' AND p.proname LIKE '%sandbox%') >= 2,
  'The sandbox functions exist in mdm');
SELECT is((SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'mdm' AND p.proname LIKE '%sandbox%' AND p.prosrc ~* '\mwf(_bridge)?\.'),
  0, 'No sandbox function refers to wf or wf_bridge');
SELECT is((SELECT count(*)::int FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid
           JOIN pg_namespace tn ON tn.oid = t.relnamespace
           JOIN pg_class r ON r.oid = c.confrelid JOIN pg_namespace rn ON rn.oid = r.relnamespace
           WHERE tn.nspname = 'mdm' AND t.relname LIKE 'sandbox%' AND rn.nspname <> 'mdm'),
  0, 'The delta tables reference only mdm');

-- ---------------------------------------------------------------- no fact row changed (LLD §9)
SELECT is(pg_temp.facts(), (SELECT facts FROM snap WHERE label = 'before'),
  'No sandbox operation (create, items, validate, rebase, submit, discard, overlay rows) changed a fact row');

SELECT * FROM finish();
ROLLBACK;
