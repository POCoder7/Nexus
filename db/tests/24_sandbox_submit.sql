-- pgTAP: leaving a sandbox (Phase 5 NEW-08, increment 5-2; ADR-028; Phase 5 LLD §5, §6.1, §9).
-- Submit first turns a sandbox into an ordinary draft request, and is refused while an item conflicts (N2301). Discard
-- withdraws it. Both clear the overlay, only the owner may do either, and neither changes a fact. A sandbox is not
-- listed among a person's drafts in the worklist. Synthetic data only.
BEGIN;
SELECT plan(20);

-- ---------------------------------------------------------------- fixtures (synthetic)
CREATE FUNCTION pg_temp.id(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('00000000-0000-0000-0000-00000024' || p)::uuid
$$;

INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  (pg_temp.id('a0a1'), 'ss_owner',   'Submit owner', 'human'),
  (pg_temp.id('a0a2'), 'ss_checker', 'Checker',      'human'),
  (pg_temp.id('a0a3'), 'ss_other',   'Other maker',  'human');
INSERT INTO mdm.version (version_id, version_name, business_as_of) VALUES (pg_temp.id('b0b1'), 'SS_VERSION', current_date);
INSERT INTO mdm.node (node_id, node_kind)
SELECT pg_temp.id(n), 'structural' FROM unnest(ARRAY['c001', 'c002', 'c003']) n;
INSERT INTO mdm.node_attr (node_id, node_name, valid_period, recorded_period)
SELECT pg_temp.id(n), name, daterange('2020-01-01', NULL), tstzrange(now() - interval '2 days', NULL)
FROM (VALUES ('c001', 'SS T'), ('c002', 'SS A'), ('c003', 'SS B')) v(n, name);
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id)
VALUES (pg_temp.id('d0d1'), 'SS_H', 'Submit hierarchy', pg_temp.id('c001'));
INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, valid_period, recorded_period)
SELECT pg_temp.id('d0d1'), pg_temp.id('c001'), pg_temp.id(c), daterange('2020-01-01', NULL), tstzrange(now() - interval '2 days', NULL)
FROM unnest(ARRAY['c002', 'c003']) c;

-- Three sandboxes of the owner: S1 renames A, S2 renames B, S3 is discarded.
INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind, effective_from,
                                kind, origin, sandbox_name, sandbox_base_recorded_at)
SELECT pg_temp.id(s), pg_temp.id('b0b1'), 'SS ' || s, pg_temp.id('a0a1'), 'human', '2030-01-01',
       'sandbox', 'sandbox', 'Submit ' || s, now() - interval '1 day'
FROM unnest(ARRAY['f0f1', 'f0f2', 'f0f3']) s;
INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, payload) VALUES
  (pg_temp.id('f0f1'), 1, 'update_node', pg_temp.id('d0d1'), pg_temp.id('c002'), '{"name": "SS A2", "expected": {"name": "SS A"}}'),
  (pg_temp.id('f0f2'), 1, 'update_node', pg_temp.id('d0d1'), pg_temp.id('c003'), '{"name": "SS B2", "expected": {"name": "SS B"}}'),
  (pg_temp.id('f0f3'), 1, 'update_node', pg_temp.id('d0d1'), pg_temp.id('c003'), '{"name": "SS B3", "expected": {"name": "SS B"}}');
SELECT mdm.refresh_sandbox_delta(pg_temp.id(s)) FROM unnest(ARRAY['f0f1', 'f0f2', 'f0f3']) s;

-- Meanwhile another maker renames B, so S2 conflicts.
INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind, effective_from)
VALUES (pg_temp.id('f0a1'), pg_temp.id('b0b1'), 'SS other rename', pg_temp.id('a0a3'), 'human', '2030-01-01');
INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, payload)
VALUES (pg_temp.id('f0a1'), 1, 'update_node', pg_temp.id('d0d1'), pg_temp.id('c003'), '{"name": "SS B other"}');
UPDATE mdm.change_request SET status = 'submitted', submitted_at = now() WHERE change_request_id = pg_temp.id('f0a1');
UPDATE mdm.change_request SET status = 'approved', decided_by = pg_temp.id('a0a2'), decided_at = now(),
       decision_basis = 'human_review' WHERE change_request_id = pg_temp.id('f0a1');
SELECT mdm.apply_change_request(pg_temp.id('f0a1'), pg_temp.id('a0a2'));

CREATE FUNCTION pg_temp.facts() RETURNS text LANGUAGE sql AS $$
  SELECT md5(string_agg(x, '|' ORDER BY x)) FROM (
              SELECT 'node_attr '              || t::text FROM mdm.node_attr t
    UNION ALL SELECT 'hierarchy_relationship ' || t::text FROM mdm.hierarchy_relationship t
    UNION ALL SELECT 'property_value '         || t::text FROM mdm.property_value t
    UNION ALL SELECT 'change_event '           || t::text FROM mdm.change_event t) s(x)
$$;
CREATE FUNCTION pg_temp.delta_rows(p uuid) RETURNS int LANGUAGE sql AS $$
  SELECT (SELECT count(*) FROM mdm.sandbox_delta_relationship WHERE sandbox_id = p)::int
       + (SELECT count(*) FROM mdm.sandbox_delta_node_attr WHERE sandbox_id = p)::int
       + (SELECT count(*) FROM mdm.sandbox_delta_value WHERE sandbox_id = p)::int
$$;
CREATE TEMP TABLE snap AS SELECT pg_temp.facts() AS facts;
GRANT SELECT ON snap TO nexus_api;

-- ================================================================ the worklist
SELECT is((SELECT count(*)::int FROM wf.worklist_rows(pg_temp.id('a0a1'), 'drafted')), 0,
  'A sandbox is not listed among its owner''s drafts in the worklist');

-- ================================================================ convert (the first step of submit)
SET LOCAL ROLE nexus_api;
SELECT throws_ok($$SELECT mdm.convert_sandbox('00000000-0000-0000-0000-00000024f0f1', '00000000-0000-0000-0000-00000024a0a3')$$,
  'N1025', NULL, 'Only the owner may submit a sandbox (N1025)');
SELECT throws_ok($$SELECT mdm.convert_sandbox('00000000-0000-0000-0000-00000024f0f2', '00000000-0000-0000-0000-00000024a0a1')$$,
  'N2301', NULL, 'A sandbox with a conflicting item cannot be submitted (N2301)');
SELECT lives_ok($$SELECT mdm.convert_sandbox('00000000-0000-0000-0000-00000024f0f1', '00000000-0000-0000-0000-00000024a0a1')$$,
  'The owner submits a sandbox without conflicts');
RESET ROLE;
SELECT is((SELECT kind || '/' || status FROM mdm.change_request WHERE change_request_id = pg_temp.id('f0f1')), 'request/draft',
  'It is now an ordinary draft request');
SELECT is((SELECT origin || '/' || sandbox_name FROM mdm.change_request WHERE change_request_id = pg_temp.id('f0f1')),
  'sandbox/Submit f0f1', 'It keeps its origin, and so the sandbox item limit, and its name');
SELECT is(pg_temp.delta_rows(pg_temp.id('f0f1')), 0, 'Its overlay is cleared');
SELECT is(pg_temp.delta_rows(pg_temp.id('f0f2')) > 0, true, 'The refused sandbox keeps its overlay');
SELECT is((SELECT kind FROM mdm.change_request WHERE change_request_id = pg_temp.id('f0f2')), 'sandbox', 'and stays a sandbox');
SELECT is((SELECT count(*)::int FROM wf.worklist_rows(pg_temp.id('a0a1'), 'drafted')), 1,
  'The converted request is listed among its owner''s drafts');

SET LOCAL ROLE nexus_api;
SELECT lives_ok($$SELECT mdm.submit_change_request('00000000-0000-0000-0000-00000024f0f1', '00000000-0000-0000-0000-00000024a0a1')$$,
  'and is submitted as any draft');
SELECT throws_ok($$SELECT mdm.convert_sandbox('00000000-0000-0000-0000-00000024f0f1', '00000000-0000-0000-0000-00000024a0a1')$$,
  'N2303', NULL, 'A request that is no longer a sandbox cannot be converted again (N2303)');

-- ================================================================ discard
SELECT throws_ok($$SELECT mdm.discard_sandbox('00000000-0000-0000-0000-00000024f0f3', '00000000-0000-0000-0000-00000024a0a3')$$,
  'N1025', NULL, 'Only the owner may discard a sandbox (N1025)');
SELECT lives_ok($$SELECT mdm.discard_sandbox('00000000-0000-0000-0000-00000024f0f3', '00000000-0000-0000-0000-00000024a0a1')$$,
  'The owner discards a sandbox');
RESET ROLE;
SELECT is((SELECT kind || '/' || status FROM mdm.change_request WHERE change_request_id = pg_temp.id('f0f3')), 'sandbox/withdrawn',
  'A discarded sandbox is withdrawn');
SELECT is(pg_temp.delta_rows(pg_temp.id('f0f3')), 0, 'and its overlay is cleared');

-- ================================================================ privileges, layer separation, facts
SELECT is((SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'mdm' AND p.proname IN ('convert_sandbox', 'discard_sandbox')
             AND p.prosecdef AND pg_get_userbyid(p.proowner) = 'nexus_apply'
             AND has_function_privilege('nexus_api', p.oid, 'EXECUTE')
             AND NOT has_function_privilege('nexus_readonly', p.oid, 'EXECUTE')),
  2, 'Convert and discard run as nexus_apply and only the API may call them');
SELECT ok(NOT has_column_privilege('nexus_api', 'mdm.change_request', 'kind', 'UPDATE'),
  'The API still cannot change a request''s kind itself');
SELECT is((SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'mdm' AND p.proname IN ('convert_sandbox', 'discard_sandbox') AND p.prosrc ~* '\mwf(_bridge)?\.'),
  0, 'Neither refers to wf or wf_bridge (CLAUDE.md rule 3)');
SELECT is(pg_temp.facts(), (SELECT facts FROM snap), 'Converting, submitting and discarding changed no fact row');

SELECT * FROM finish();
ROLLBACK;
