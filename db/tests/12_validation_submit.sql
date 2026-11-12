-- pgTAP: validate_change_request (trial apply + rules, always rolled back) and submit_change_request
-- (Phase 1 LLD §7.4, §4.7, increment 1-9). Synthetic data only.
BEGIN;
SELECT plan(17);

-- Fixture ------------------------------------------------------------------------------------------------------
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-000000000ca1', 'v_steward', 'Steward', 'human'),
  ('00000000-0000-0000-0000-000000000ca2', 'v_other',   'Other',   'human');
INSERT INTO mdm.version (version_id, version_name, business_as_of)
VALUES ('00000000-0000-0000-0000-000000000cb1', 'V_VERSION', '2030-01-01');   -- the requests' date, so NEXUS.VERSION_DATE (V11) stays quiet here
INSERT INTO mdm.node (node_id, node_kind) VALUES
  ('00000000-0000-0000-0000-000000000c01', 'structural'),   -- T top
  ('00000000-0000-0000-0000-000000000c02', 'structural'),   -- A
  ('00000000-0000-0000-0000-000000000c03', 'legal_entity'), -- X leaf under A
  ('00000000-0000-0000-0000-000000000c04', 'legal_entity'), -- Z badly named, not touched by any request
  ('00000000-0000-0000-0000-000000000c05', 'legal_entity'), -- new, well named
  ('00000000-0000-0000-0000-000000000c06', 'legal_entity'), -- new, badly named
  ('00000000-0000-0000-0000-000000000c07', 'legal_entity'); -- new, under a leaf
INSERT INTO mdm.node_attr (node_id, node_name, allows_children, valid_period) VALUES
  ('00000000-0000-0000-0000-000000000c01', 'V top', true, daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-000000000c02', 'V A', true, daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-000000000c03', 'V X', false, daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-000000000c04', 'zz untouched', false, daterange('2020-01-01', NULL));
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id) VALUES
  ('00000000-0000-0000-0000-000000000cc1', 'V_H1', 'V one', '00000000-0000-0000-0000-000000000c01');
INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, valid_period) VALUES
  ('00000000-0000-0000-0000-000000000cc1', '00000000-0000-0000-0000-000000000c01', '00000000-0000-0000-0000-000000000c02', daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-000000000cc1', '00000000-0000-0000-0000-000000000c02', '00000000-0000-0000-0000-000000000c03', daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-000000000cc1', '00000000-0000-0000-0000-000000000c01', '00000000-0000-0000-0000-000000000c04', daterange('2020-01-01', NULL));
INSERT INTO mdm.validation_rule (rule_code, description, level, severity, engine, expression, is_active) VALUES
  ('V.NAME', 'Names start with V', 'node', 'error', 'sql',
   $r$SELECT a.node_id, NULL::uuid AS hierarchy_id, 'Name must start with V: ' || a.node_name AS message
      FROM mdm.node_attr a WHERE a.valid_period @> $1 AND a.recorded_period @> $2 AND a.node_name NOT LIKE 'V%'$r$, true),
  ('V.CEL', 'A rule for a later engine', 'node', 'error', 'cel', 'node.name != ""', true),
  ('V.BROKEN', 'A rule with bad SQL', 'node', 'error', 'sql', 'SELECT nonsense FROM nowhere', false);

-- Helpers (owner, setup only)
CREATE FUNCTION pg_temp.cr(p_id uuid) RETURNS void LANGUAGE sql AS $$
  INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind, effective_from)
  VALUES (p_id, '00000000-0000-0000-0000-000000000cb1', 'V ' || p_id, '00000000-0000-0000-0000-000000000ca1', 'human', '2030-01-01')
$$;
CREATE FUNCTION pg_temp.add(p_cr uuid, p_node uuid, p_parent uuid, p_name text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, target_parent_id, payload)
  VALUES (p_cr, 1, 'add_node', '00000000-0000-0000-0000-000000000cc1', p_node, p_parent, jsonb_build_object('name', p_name))
$$;
CREATE TEMP TABLE findings (cr uuid, rule_code text, severity text, node_id uuid, hierarchy_id uuid, message text,
                            evaluated_at timestamptz);
CREATE FUNCTION pg_temp.validate(p_cr uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  SET LOCAL ROLE nexus_api;                                     -- validated through the API's privileges
  INSERT INTO findings SELECT p_cr, f.* FROM mdm.validate_change_request(p_cr, '2030-01-01') f;
  RESET ROLE;
END $$;

SELECT pg_temp.cr('00000000-0000-0000-0000-000000000cd1');
SELECT pg_temp.add('00000000-0000-0000-0000-000000000cd1', '00000000-0000-0000-0000-000000000c05', '00000000-0000-0000-0000-000000000c02', 'V new');
SELECT pg_temp.cr('00000000-0000-0000-0000-000000000cd2');
SELECT pg_temp.add('00000000-0000-0000-0000-000000000cd2', '00000000-0000-0000-0000-000000000c06', '00000000-0000-0000-0000-000000000c02', 'bad name');
SELECT pg_temp.cr('00000000-0000-0000-0000-000000000cd3');
SELECT pg_temp.add('00000000-0000-0000-0000-000000000cd3', '00000000-0000-0000-0000-000000000c07', '00000000-0000-0000-0000-000000000c03', 'V under leaf');
GRANT INSERT ON findings TO nexus_api;

-- Validation -------------------------------------------------------------------------------------------------
SELECT lives_ok($$SELECT pg_temp.validate('00000000-0000-0000-0000-000000000cd1')$$, 'The API can validate a draft');
SELECT is((SELECT count(*)::int FROM findings WHERE cr = '00000000-0000-0000-0000-000000000cd1' AND severity = 'error'),
  0, 'A clean request has no errors');
SELECT is((SELECT string_agg(rule_code || ':' || severity, ',') FROM findings WHERE cr = '00000000-0000-0000-0000-000000000cd1'),
  'V.CEL:warning', 'A rule for an engine that is not built yet is reported as skipped, not run');
SELECT is((SELECT count(*)::int FROM mdm.node_attr WHERE node_id = '00000000-0000-0000-0000-000000000c05'),
  0, 'The trial apply leaves no facts behind');
SELECT is((SELECT status::text FROM mdm.change_request WHERE change_request_id = '00000000-0000-0000-0000-000000000cd1')
          || '/' || (SELECT count(*) FROM mdm.change_event WHERE change_request_id = '00000000-0000-0000-0000-000000000cd1'),
  'draft/0', 'Validation changes no status and publishes no event');
SELECT is((SELECT count(*)::int FROM mdm.validation_result WHERE change_request_id = '00000000-0000-0000-0000-000000000cd1'),
  1, 'The findings are stored with the request');

SELECT pg_temp.validate('00000000-0000-0000-0000-000000000cd2');
SELECT is((SELECT string_agg(rule_code || ':' || node_id, ',') FROM findings
           WHERE cr = '00000000-0000-0000-0000-000000000cd2' AND severity = 'error'),
  'V.NAME:00000000-0000-0000-0000-000000000c06',
  'Rules see the state after the trial and report only nodes the request affects');

SELECT pg_temp.validate('00000000-0000-0000-0000-000000000cd3');
SELECT is((SELECT rule_code || ':' || left(message, 14) || ':' || node_id FROM findings
           WHERE cr = '00000000-0000-0000-0000-000000000cd3' AND severity = 'error'),
  'NEXUS.TRIAL_APPLY:N2004 (item 1):00000000-0000-0000-0000-000000000c07',
  'A guard failure in the trial is an error finding on the item''s node');

UPDATE mdm.validation_rule SET is_active = true WHERE rule_code = 'V.BROKEN';
SELECT pg_temp.validate('00000000-0000-0000-0000-000000000cd1');
SELECT ok((SELECT bool_or(message LIKE 'Rule V.BROKEN could not be evaluated%') FROM findings
           WHERE cr = '00000000-0000-0000-0000-000000000cd1' AND rule_code = 'V.BROKEN'),
  'A rule that fails is reported as an error finding instead of failing the validation');
UPDATE mdm.validation_rule SET is_active = false WHERE rule_code = 'V.BROKEN';

-- Submit -----------------------------------------------------------------------------------------------------
SELECT pg_temp.cr('00000000-0000-0000-0000-000000000cd4');                   -- no items
SET LOCAL ROLE nexus_api;
SELECT throws_ok($$SELECT mdm.submit_change_request('00000000-0000-0000-0000-000000000cd1', '00000000-0000-0000-0000-000000000ca2')$$,
  'N1025', NULL, 'Only the requester can submit');
SELECT throws_ok($$SELECT mdm.submit_change_request('00000000-0000-0000-0000-000000000cd4', '00000000-0000-0000-0000-000000000ca1')$$,
  'N2106', NULL, 'An empty request cannot be submitted');
SELECT lives_ok($$SELECT mdm.submit_change_request('00000000-0000-0000-0000-000000000cd1', '00000000-0000-0000-0000-000000000ca1')$$,
  'The requester can submit a draft');
SELECT throws_ok($$SELECT mdm.submit_change_request('00000000-0000-0000-0000-000000000cd1', '00000000-0000-0000-0000-000000000ca1')$$,
  'N2101', NULL, 'A submitted request cannot be submitted again');
SELECT throws_ok($$UPDATE mdm.change_request SET status = 'submitted' WHERE change_request_id = '00000000-0000-0000-0000-000000000cd2'$$,
  '42501', NULL, 'The API cannot set a status itself');
SELECT lives_ok($$SELECT * FROM mdm.validate_change_request('00000000-0000-0000-0000-000000000cd1', '2030-01-01')$$,
  'A submitted request can still be validated (reviewers re-check it)');
RESET ROLE;

SELECT ok((SELECT status = 'submitted' AND submitted_at IS NOT NULL FROM mdm.change_request
           WHERE change_request_id = '00000000-0000-0000-0000-000000000cd1'), 'Submit records the status and the time');

UPDATE mdm.change_request SET status = 'withdrawn' WHERE change_request_id = '00000000-0000-0000-0000-000000000cd2';
SELECT throws_ok($$SELECT * FROM mdm.validate_change_request('00000000-0000-0000-0000-000000000cd2', '2030-01-01')$$,
  'N2101', NULL, 'A withdrawn request is not validated');

SELECT * FROM finish();
ROLLBACK;
