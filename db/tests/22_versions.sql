-- pgTAP: versions (V11; VER-01 create and copy, VER-02 lifecycle; ADR-037; Phase 3 LLD "Third scope extension:
-- versions", V.4 and V.7). Every guard and code, the pin, four eyes, people only, requests in working versions only,
-- the R2 freeze check, the log, the CHECK, privileges and the NEXUS.VERSION_DATE warning. Synthetic data only.
BEGIN;
SELECT plan(77);

-- ---------------------------------------------------------------- fixtures (synthetic)
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-0000000022a1', 'ver_admin1', 'Version admin one', 'human'),
  ('00000000-0000-0000-0000-0000000022a2', 'ver_admin2', 'Version admin two', 'human'),
  ('00000000-0000-0000-0000-0000000022a3', 'ver_steward', 'Steward', 'human'),
  ('00000000-0000-0000-0000-0000000022a5', 'ver_granter', 'Granter', 'human');
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-0000000022a4', 'ver_agent', 'Agent', 'ai_agent');
INSERT INTO mdm.user_role (user_id, role_code, granted_by, valid_period) VALUES
  ('00000000-0000-0000-0000-0000000022a1', 'VERSION_ADMIN', '00000000-0000-0000-0000-0000000022a5', daterange('2000-01-01', NULL)),
  ('00000000-0000-0000-0000-0000000022a2', 'VERSION_ADMIN', '00000000-0000-0000-0000-0000000022a5', daterange('2000-01-01', NULL));
-- The AI agent holds no role: only people can (V1 roles.human_only). Its tests below show the version guards refuse it anyway.

-- Helpers (owner, setup only)
CREATE FUNCTION pg_temp.vid(p_name text) RETURNS uuid LANGUAGE sql AS $$
  SELECT version_id FROM mdm.version WHERE version_name = p_name
$$;
CREATE FUNCTION pg_temp.cr(p_id uuid, p_version text, p_effective date DEFAULT current_date) RETURNS void LANGUAGE sql AS $$
  INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind, effective_from)
  VALUES (p_id, pg_temp.vid(p_version), 'T22 ' || p_id, '00000000-0000-0000-0000-0000000022a3', 'human', p_effective)
$$;
CREATE FUNCTION pg_temp.to_status(p_id uuid, p_status text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_status IN ('approved', 'rejected') THEN
    UPDATE mdm.change_request SET status = p_status::mdm.cr_status, decided_by = '00000000-0000-0000-0000-0000000022a5',
                                  decided_at = now(), decision_basis = 'human_review'
    WHERE change_request_id = p_id;
  ELSE
    UPDATE mdm.change_request SET status = p_status::mdm.cr_status WHERE change_request_id = p_id;
  END IF;
END $$;
CREATE TEMP TABLE pins (version_name text PRIMARY KEY, pinned timestamptz);

-- ---------------------------------------------------------------- structure and role
SELECT has_table('mdm', 'version_transition', 'Version transitions are logged');
SELECT has_column('mdm', 'version', 'revision', 'A version has a revision (the ETag)');
SELECT has_column('mdm', 'user_preference', 'working_version_id', 'A user can choose a working version');
SELECT is((SELECT description FROM mdm.role WHERE role_code = 'VERSION_ADMIN'),
  'Create versions and move them through their lifecycle', 'VERSION_ADMIN is a role');
SELECT ok(mdm.is_version_admin('00000000-0000-0000-0000-0000000022a1'), 'A person with VERSION_ADMIN is a version administrator');
SELECT ok(NOT mdm.is_version_admin('00000000-0000-0000-0000-0000000022a3'), 'A steward is not');
SELECT ok(NOT mdm.is_version_admin('00000000-0000-0000-0000-0000000022a4'), 'An AI agent is not a version administrator');

-- ---------------------------------------------------------------- create and copy (VER-01)
SELECT throws_ok(
  $$SELECT mdm.create_version('T22 X', current_date, NULL, NULL, '00000000-0000-0000-0000-0000000022a3')$$,
  'N1028', 'Only a version administrator can create or change versions', 'A steward cannot create a version (N1028)');
SELECT throws_ok(
  $$SELECT mdm.create_version('T22 X', current_date, NULL, NULL, '00000000-0000-0000-0000-0000000022a4')$$,
  'N1028', NULL, 'An AI agent cannot create a version (N1028)');
SELECT lives_ok(
  $$SELECT mdm.create_version('T22 A', current_date, NULL, 'Month end', '00000000-0000-0000-0000-0000000022a1')$$,
  'A version administrator creates a version');
SELECT is((SELECT status::text || '/' || revision || '/' || (created_by = '00000000-0000-0000-0000-0000000022a1')
                  || '/' || (recorded_as_of IS NULL)
           FROM mdm.version WHERE version_name = 'T22 A'),
  'working/1/true/true', 'A new version is working, unpinned, revision 1, with its creator');
SELECT lives_ok(
  $$SELECT mdm.create_version('T22 B', current_date, NULL, NULL, '00000000-0000-0000-0000-0000000022a2')$$,
  'A second administrator creates another');
SELECT lives_ok(
  $$SELECT mdm.create_version('T22 C', current_date, pg_temp.vid('T22 A'), 'Copy of A', '00000000-0000-0000-0000-0000000022a1')$$,
  'A version can be copied from another');
SELECT is((SELECT base_version_id FROM mdm.version WHERE version_name = 'T22 C'), pg_temp.vid('T22 A'),
  'A copy records its base and copies no rows (a named slice, ADR-037 D2)');
SELECT throws_ok(
  $$INSERT INTO mdm.version (version_name, business_as_of, status, recorded_as_of) VALUES ('T22 Z', current_date, 'submitted', now())$$,
  'N2706', NULL, 'A version cannot be created submitted (N2706)');
SELECT throws_ok(
  $$INSERT INTO mdm.version (version_name, business_as_of, recorded_as_of) VALUES ('T22 Z', current_date, now())$$,
  'N2706', NULL, 'A version cannot be created pinned (N2706)');
SELECT is((SELECT count(*)::int FROM mdm.audit_log WHERE table_name = 'version' AND action = 'INSERT'
                                                     AND actor_id = '00000000-0000-0000-0000-0000000022a1'),
  2, 'Creating a version is audited with its creator');

-- ---------------------------------------------------------------- R2 baseline: no pin yet, an apply goes through
SELECT pg_temp.cr('00000000-0000-0000-0000-0000000022c1', 'T22 B');
SELECT pg_temp.to_status('00000000-0000-0000-0000-0000000022c1', 'submitted');
SELECT pg_temp.to_status('00000000-0000-0000-0000-0000000022c1', 'approved');
SELECT lives_ok(
  $$UPDATE mdm.change_request SET status = 'applied', applied_at = now() WHERE change_request_id = '00000000-0000-0000-0000-0000000022c1'$$,
  'With no version pinned during this transaction, a request in a working version is applied');

-- ---------------------------------------------------------------- edit
SELECT lives_ok(
  $$SELECT mdm.update_version(pg_temp.vid('T22 A'), 'T22 A1', 'Month end close', '00000000-0000-0000-0000-0000000022a2')$$,
  'An administrator renames a working version');
SELECT is((SELECT revision FROM mdm.version WHERE version_name = 'T22 A1'), 2, 'Every update bumps the revision');
SELECT throws_ok(
  $$SELECT mdm.update_version(pg_temp.vid('T22 A1'), 'T22 Q', NULL, '00000000-0000-0000-0000-0000000022a3')$$,
  'N1028', NULL, 'A steward cannot rename a version (N1028)');
SELECT lives_ok(
  $$UPDATE mdm.version SET business_as_of = current_date - 1 WHERE version_name = 'T22 C'$$,
  'The business date changes while the version is working');

-- ---------------------------------------------------------------- transitions that do not exist
SELECT throws_ok(
  $$SELECT mdm.transition_version(pg_temp.vid('T22 A1'), 'submitted', NULL, '00000000-0000-0000-0000-0000000022a3')$$,
  'N1028', NULL, 'A steward cannot submit a version (N1028)');
SELECT throws_ok(
  $$SELECT mdm.transition_version(pg_temp.vid('T22 A1'), 'finalized', NULL, '00000000-0000-0000-0000-0000000022a2')$$,
  'N2701', 'Version T22 A1 cannot move from working to finalized', 'A working version cannot be finalized (N2701)');
SELECT throws_ok(
  $$SELECT mdm.transition_version(pg_temp.vid('T22 A1'), 'working', NULL, '00000000-0000-0000-0000-0000000022a1')$$,
  'N2701', NULL, 'A version cannot move to the status it has (N2701)');
SELECT throws_ok(
  $$SELECT mdm.transition_version(pg_temp.vid('T22 A1'), 'archived', NULL, '00000000-0000-0000-0000-0000000022a1')$$,
  'N2701', NULL, 'There is no such status (N2701)');

-- ---------------------------------------------------------------- submit: requests in flight block it, drafts do not (R1)
SELECT pg_temp.cr('00000000-0000-0000-0000-0000000022d1', 'T22 A1');        -- stays a draft
SELECT pg_temp.cr('00000000-0000-0000-0000-0000000022d2', 'T22 A1');        -- submitted
SELECT pg_temp.cr('00000000-0000-0000-0000-0000000022d3', 'T22 A1');        -- approved
SELECT pg_temp.cr('00000000-0000-0000-0000-0000000022d4', 'T22 A1');        -- a draft, withdrawn after the freeze
SELECT pg_temp.to_status('00000000-0000-0000-0000-0000000022d2', 'submitted');
SELECT pg_temp.to_status('00000000-0000-0000-0000-0000000022d3', 'submitted');
SELECT pg_temp.to_status('00000000-0000-0000-0000-0000000022d3', 'approved');
SELECT throws_ok(
  $$SELECT mdm.transition_version(pg_temp.vid('T22 A1'), 'submitted', NULL, '00000000-0000-0000-0000-0000000022a1')$$,
  'N2704', '2 requests in this version are still in flight (1 submitted, 1 approved)',
  'Submit is refused while requests are in flight, with the counts (N2704)');
SELECT pg_temp.to_status('00000000-0000-0000-0000-0000000022d2', 'withdrawn');
SELECT pg_temp.to_status('00000000-0000-0000-0000-0000000022d3', 'apply_failed');
SELECT lives_ok(
  $$SELECT mdm.transition_version(pg_temp.vid('T22 A1'), 'submitted', 'Month end freeze', '00000000-0000-0000-0000-0000000022a1')$$,
  'Submit goes through with only drafts left in the version (R1)');
INSERT INTO pins SELECT version_name, recorded_as_of FROM mdm.version WHERE version_name = 'T22 A1';
SELECT ok((SELECT recorded_as_of > now() AND recorded_as_of <= clock_timestamp() FROM mdm.version WHERE version_name = 'T22 A1'),
  'Submit pins the version at the clock time of the submit');
SELECT is((SELECT status::text || '/' || (submitted_by = '00000000-0000-0000-0000-0000000022a1') || '/' || (submitted_at IS NOT NULL)
           FROM mdm.version WHERE version_name = 'T22 A1'),
  'submitted/true/true', 'Submit records who submitted and when');
SELECT is((SELECT from_status || '>' || to_status || '/' || reason || '/' || (pinned_at = v.recorded_as_of)
                  || '/' || (actor_id = '00000000-0000-0000-0000-0000000022a1')
           FROM mdm.version_transition t JOIN mdm.version v USING (version_id) WHERE v.version_name = 'T22 A1'),
  'working>submitted/Month end freeze/true/true', 'The transition is logged with its actor, reason and pin');
SELECT is((SELECT count(*)::int FROM mdm.audit_log WHERE table_name = 'version' AND action = 'UPDATE'
                                                     AND (new_row ->> 'status') = 'submitted'
                                                     AND actor_id = '00000000-0000-0000-0000-0000000022a1'),
  1, 'The submit is audited with its actor');

-- ---------------------------------------------------------------- frozen fields (N2702)
SELECT throws_ok(
  $$UPDATE mdm.version SET recorded_as_of = recorded_as_of - interval '1 day' WHERE version_name = 'T22 A1'$$,
  'N2702', NULL, 'The pin never changes without a transition (N2702)');
SELECT throws_ok(
  $$UPDATE mdm.version SET business_as_of = current_date - 7 WHERE version_name = 'T22 A1'$$,
  'N2702', NULL, 'The business date of a submitted version is frozen (N2702)');
SELECT throws_ok(
  $$UPDATE mdm.version SET base_version_id = pg_temp.vid('T22 B') WHERE version_name = 'T22 A1'$$,
  'N2702', NULL, 'The base of a submitted version is frozen (N2702)');
SELECT lives_ok(
  $$SELECT mdm.update_version(pg_temp.vid('T22 A1'), 'T22 A1', 'Month end close, frozen', '00000000-0000-0000-0000-0000000022a1')$$,
  'The description of a submitted version can still change');

-- ---------------------------------------------------------------- requests live in working versions (N2703)
SELECT throws_ok(
  $$SELECT pg_temp.cr('00000000-0000-0000-0000-0000000022e1', 'T22 A1')$$,
  'N2703', 'Version T22 A1 is submitted, not working: requests cannot be raised in it, moved to it or advanced in it',
  'A request cannot be raised in a submitted version (N2703)');
SELECT throws_ok(
  $$SELECT pg_temp.to_status('00000000-0000-0000-0000-0000000022d1', 'submitted')$$,
  'N2703', NULL, 'A draft in a submitted version cannot be submitted (N2703)');
SELECT lives_ok(
  $$SELECT pg_temp.to_status('00000000-0000-0000-0000-0000000022d4', 'withdrawn')$$,
  'A request in a submitted version can still be withdrawn');
SELECT pg_temp.cr('00000000-0000-0000-0000-0000000022e2', 'T22 B');
SELECT throws_ok(
  $$UPDATE mdm.change_request SET version_id = pg_temp.vid('T22 A1') WHERE change_request_id = '00000000-0000-0000-0000-0000000022e2'$$,
  'N2703', NULL, 'A draft cannot be moved into a submitted version (N2703)');

-- ---------------------------------------------------------------- R2: a pin after this transaction began stops an apply
SELECT pg_temp.cr('00000000-0000-0000-0000-0000000022e3', 'T22 B');
SELECT pg_temp.to_status('00000000-0000-0000-0000-0000000022e3', 'submitted');
SELECT pg_temp.to_status('00000000-0000-0000-0000-0000000022e3', 'approved');
SELECT throws_ok(
  $$UPDATE mdm.change_request SET status = 'applied', applied_at = now() WHERE change_request_id = '00000000-0000-0000-0000-0000000022e3'$$,
  '40001', 'A version was frozen while this request was being applied; the apply is retried',
  'A version pinned after this transaction began refuses applied with 40001, so the apply is retried (R2)');
SELECT throws_ok(
  $$SELECT mdm.apply_change_request('00000000-0000-0000-0000-0000000022e3', '00000000-0000-0000-0000-0000000022a2')$$,
  '40001', NULL, 'apply_change_request raises the 40001 to its caller (not a rule failure), so ApplyService retries it');
SELECT is((SELECT status::text FROM mdm.change_request WHERE change_request_id = '00000000-0000-0000-0000-0000000022e3'),
  'approved', 'The request stays approved for the retry');
-- Done with it: a failed apply leaves version B with nothing in flight for the tests below.
SELECT pg_temp.to_status('00000000-0000-0000-0000-0000000022e3', 'apply_failed');

-- ---------------------------------------------------------------- finalize: four eyes (N1029), then expire
SELECT throws_ok(
  $$SELECT mdm.transition_version(pg_temp.vid('T22 A1'), 'finalized', NULL, '00000000-0000-0000-0000-0000000022a1')$$,
  'N1029', 'You submitted version T22 A1; another version administrator must finalize it',
  'The submitter cannot finalize (N1029)');
SELECT lives_ok(
  $$SELECT mdm.transition_version(pg_temp.vid('T22 A1'), 'finalized', 'Checked', '00000000-0000-0000-0000-0000000022a2')$$,
  'A second version administrator finalizes');
SELECT is((SELECT status::text || '/' || (finalized_by = '00000000-0000-0000-0000-0000000022a2') || '/' || (finalized_at IS NOT NULL)
                  || '/' || (recorded_as_of = (SELECT pinned FROM pins WHERE version_name = 'T22 A1'))
           FROM mdm.version WHERE version_name = 'T22 A1'),
  'finalized/true/true/true', 'Finalize records the finalizer and keeps the pin');
SELECT throws_ok(
  $$SELECT mdm.transition_version(pg_temp.vid('T22 A1'), 'working', NULL, '00000000-0000-0000-0000-0000000022a1')$$,
  'N2701', NULL, 'A finalized version cannot be reopened (N2701)');
SELECT throws_ok(
  $$SELECT mdm.update_version(pg_temp.vid('T22 A1'), 'T22 A2', NULL, '00000000-0000-0000-0000-0000000022a1')$$,
  'N2702', NULL, 'A finalized version cannot be renamed (N2702)');
SELECT lives_ok(
  $$SELECT mdm.transition_version(pg_temp.vid('T22 A1'), 'expired', NULL, '00000000-0000-0000-0000-0000000022a1')$$,
  'A finalized version is expired');
SELECT is((SELECT status::text || '/' || (recorded_as_of = (SELECT pinned FROM pins WHERE version_name = 'T22 A1'))
                  || '/' || (finalized_by = '00000000-0000-0000-0000-0000000022a2')
           FROM mdm.version WHERE version_name = 'T22 A1'),
  'expired/true/true', 'Expire changes only the status: the pin and the finalizer stay');
SELECT throws_ok(
  $$SELECT mdm.transition_version(pg_temp.vid('T22 A1'), 'finalized', NULL, '00000000-0000-0000-0000-0000000022a2')$$,
  'N2701', NULL, 'An expired version stays expired (N2701)');
SELECT throws_ok(
  $$DELETE FROM mdm.version WHERE version_name = 'T22 A1'$$,
  'N2705', 'Version T22 A1 is never deleted; expire it instead', 'A version is never deleted (N2705)');
SELECT is((SELECT string_agg(from_status || '>' || to_status, ',' ORDER BY recorded_at)
           FROM mdm.version_transition WHERE version_id = pg_temp.vid('T22 A1')),
  'working>submitted,submitted>finalized,finalized>expired', 'Each status change is logged once, in order');

-- ---------------------------------------------------------------- reopen
SELECT pg_temp.cr('00000000-0000-0000-0000-0000000022f1', 'T22 C');                 -- a draft does not block
SELECT lives_ok(
  $$SELECT mdm.transition_version(pg_temp.vid('T22 C'), 'submitted', NULL, '00000000-0000-0000-0000-0000000022a1')$$,
  'Version C is submitted');
SELECT lives_ok(
  $$SELECT mdm.transition_version(pg_temp.vid('T22 C'), 'working', 'Late correction', '00000000-0000-0000-0000-0000000022a2')$$,
  'A submitted version is reopened');
SELECT is((SELECT status::text || '/' || (recorded_as_of IS NULL) || '/' || (submitted_by IS NULL) || '/' || (submitted_at IS NULL)
           FROM mdm.version WHERE version_name = 'T22 C'),
  'working/true/true/true', 'Reopen clears the pin and the submit details');
SELECT is((SELECT pinned_at IS NULL FROM mdm.version_transition WHERE version_id = pg_temp.vid('T22 C') AND to_status = 'working'),
  true, 'The reopen is logged with no pin');
SELECT lives_ok(
  $$SELECT pg_temp.to_status('00000000-0000-0000-0000-0000000022f1', 'submitted')$$,
  'After reopening, its requests can be submitted again');

-- ---------------------------------------------------------------- people only (N1030)
SELECT set_config('mdm.actor_id', '', true);
SELECT throws_ok(
  $$UPDATE mdm.version SET status = 'submitted', recorded_as_of = clock_timestamp(), submitted_at = clock_timestamp(),
                           submitted_by = '00000000-0000-0000-0000-0000000022a1' WHERE version_name = 'T22 B'$$,
  'N1030', NULL, 'A status change with no identified actor is refused (N1030)');
SELECT set_config('mdm.actor_id', '00000000-0000-0000-0000-0000000022a4', true);
SELECT throws_ok(
  $$UPDATE mdm.version SET status = 'submitted', recorded_as_of = clock_timestamp(), submitted_at = clock_timestamp(),
                           submitted_by = '00000000-0000-0000-0000-0000000022a4' WHERE version_name = 'T22 B'$$,
  'N1030', NULL, 'An AI agent cannot change a version''s status (N1030)');
SELECT set_config('mdm.actor_id', '00000000-0000-0000-0000-0000000022a1', true);
SELECT throws_ok(
  $$UPDATE mdm.version SET status = 'submitted', recorded_as_of = now() - interval '1 hour', submitted_at = clock_timestamp(),
                           submitted_by = '00000000-0000-0000-0000-0000000022a2' WHERE version_name = 'T22 B'$$,
  'N2702', NULL, 'A direct submit must record its own actor as the submitter (N2702)');

-- ---------------------------------------------------------------- the CHECK holds even with the guard off
ALTER TABLE mdm.version DISABLE TRIGGER version_guard;
SELECT throws_ok(
  $$UPDATE mdm.version SET status = 'submitted' WHERE version_name = 'T22 B'$$,
  '23514', NULL, 'A submitted version without a pin breaks the CHECK');
SELECT throws_ok(
  $$UPDATE mdm.version SET recorded_as_of = now() WHERE version_name = 'T22 B'$$,
  '23514', NULL, 'A pinned working version breaks the CHECK');
ALTER TABLE mdm.version ENABLE TRIGGER version_guard;

-- ---------------------------------------------------------------- the transition log is append-only
SELECT throws_ok($$UPDATE mdm.version_transition SET reason = 'tampered'$$, 'N2011', NULL, 'The transition log cannot be edited');
SELECT throws_ok($$DELETE FROM mdm.version_transition$$, 'N2011', NULL, 'The transition log cannot be deleted');

-- ---------------------------------------------------------------- privileges (ADR-014)
SELECT ok(NOT has_table_privilege('nexus_api', 'mdm.version', 'INSERT')
          AND NOT has_table_privilege('nexus_api', 'mdm.version', 'DELETE')
          AND NOT has_any_column_privilege('nexus_api', 'mdm.version', 'UPDATE'),
  'The API has no direct write on mdm.version');
SELECT ok(NOT has_table_privilege('nexus_api', 'mdm.version_transition', 'INSERT'), 'The API cannot write the transition log');
SELECT ok(has_function_privilege('nexus_api', 'mdm.create_version(text, date, uuid, text, uuid)', 'EXECUTE')
          AND has_function_privilege('nexus_api', 'mdm.update_version(uuid, text, text, uuid)', 'EXECUTE')
          AND has_function_privilege('nexus_api', 'mdm.transition_version(uuid, text, text, uuid)', 'EXECUTE'),
  'The API changes versions only through the functions');
SELECT ok(NOT has_function_privilege('nexus_readonly', 'mdm.transition_version(uuid, text, text, uuid)', 'EXECUTE'),
  'Reporting cannot move versions');
SELECT ok(has_column_privilege('nexus_api', 'mdm.change_request', 'version_id', 'UPDATE'),
  'The API may move a request to another version (R1)');
SELECT ok(has_column_privilege('nexus_api', 'mdm.user_preference', 'working_version_id', 'INSERT')
          AND has_column_privilege('nexus_api', 'mdm.user_preference', 'working_version_id', 'UPDATE'),
  'The API may save the chosen working version');

SET LOCAL ROLE nexus_api;
SELECT throws_ok(
  $$UPDATE mdm.version SET description = 'direct' WHERE version_name = 'T22 B'$$,
  '42501', NULL, 'The API role cannot update a version directly');
SELECT lives_ok(
  $$UPDATE mdm.change_request SET version_id = (SELECT version_id FROM mdm.version WHERE version_name = 'T22 C')
    WHERE change_request_id = '00000000-0000-0000-0000-0000000022e2'$$,
  'The API moves a draft to another working version');
SELECT throws_ok(
  $$UPDATE mdm.change_request SET version_id = (SELECT version_id FROM mdm.version WHERE version_name = 'T22 B')
    WHERE change_request_id = '00000000-0000-0000-0000-0000000022f1'$$,
  'N2102', NULL, 'The API cannot move a request that is no longer a draft (N2102)');
SELECT lives_ok(
  $$SELECT mdm.create_version('T22 D', current_date, NULL, NULL, '00000000-0000-0000-0000-0000000022a2')$$,
  'The API creates a version through the function, for an administrator');
RESET ROLE;

-- ---------------------------------------------------------------- NEXUS.VERSION_DATE (warning)
SELECT pg_temp.cr('00000000-0000-0000-0000-0000000022b1', 'T22 B', current_date + 1);
SELECT pg_temp.cr('00000000-0000-0000-0000-0000000022b2', 'T22 B', current_date);
SELECT is((SELECT string_agg(f.rule_code || ':' || f.severity || ':' || f.message, ' | ')
           FROM mdm.validate_change_request('00000000-0000-0000-0000-0000000022b1', current_date) f),
  format('NEXUS.VERSION_DATE:warning:This change takes effect on %s, after version T22 B''s date (%s), so it will not show in that version',
         to_char(current_date + 1, 'FMDD Mon YYYY'), to_char(current_date, 'FMDD Mon YYYY')),
  'A change dated after its version''s business date gets the NEXUS.VERSION_DATE warning');
SELECT is((SELECT count(*)::int FROM mdm.validate_change_request('00000000-0000-0000-0000-0000000022b2', current_date) f
           WHERE f.rule_code = 'NEXUS.VERSION_DATE'),
  0, 'A change dated on its version''s business date gets no warning');

SELECT * FROM finish();
ROLLBACK;
