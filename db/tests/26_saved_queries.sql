-- pgTAP: saved queries, data layer (Phase 5 increment 5-13a; QRY-01; Phase 5 LLD §17.5.3). A saved query is its owner's
-- object: the API may create, change and delete it, but never change its owner or forge its ETag; every change is
-- audited. Synthetic data only.
BEGIN;
SELECT plan(10);

INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-0000000026a1', 'sq_owner', 'Query owner', 'human'),
  ('00000000-0000-0000-0000-0000000026a2', 'sq_other', 'Someone else', 'human');

SET LOCAL ROLE nexus_api;
SELECT lives_ok($$INSERT INTO mdm.saved_query (saved_query_id, owner_id, name, definition)
                  VALUES ('00000000-0000-0000-0000-0000000026f1', '00000000-0000-0000-0000-0000000026a1', 'My leaves',
                          '{"hierarchyCode": "X", "include": "leaves"}')$$,
  'The API saves a query');
SELECT throws_ok($$INSERT INTO mdm.saved_query (owner_id, name, definition)
                   VALUES ('00000000-0000-0000-0000-0000000026a1', 'My leaves', '{}')$$,
  '23505', NULL, 'An owner''s query names are unique');
SELECT lives_ok($$UPDATE mdm.saved_query SET name = 'My leaf nodes', visibility = 'shared'
                  WHERE saved_query_id = '00000000-0000-0000-0000-0000000026f1'$$,
  'The API changes a query''s name and visibility');
RESET ROLE;
SELECT is((SELECT row_version FROM mdm.saved_query WHERE saved_query_id = '00000000-0000-0000-0000-0000000026f1'), 2,
  'Each change moves the ETag');
SELECT ok(NOT has_column_privilege('nexus_api', 'mdm.saved_query', 'owner_id', 'UPDATE')
          AND NOT has_column_privilege('nexus_api', 'mdm.saved_query', 'row_version', 'UPDATE'),
  'The API cannot change a query''s owner or set its ETag');
SELECT throws_ok($$UPDATE mdm.saved_query SET owner_id = '00000000-0000-0000-0000-0000000026a2'
                   WHERE saved_query_id = '00000000-0000-0000-0000-0000000026f1'$$,
  'N2807', NULL, 'and not even the database owner can hand a query to someone else');
SELECT throws_ok($$INSERT INTO mdm.saved_query (owner_id, name, definition, visibility)
                   VALUES ('00000000-0000-0000-0000-0000000026a1', 'Odd', '{}', 'public')$$,
  '23514', NULL, 'Visibility is private or shared');
SET LOCAL ROLE nexus_api;
SELECT lives_ok($$DELETE FROM mdm.saved_query WHERE saved_query_id = '00000000-0000-0000-0000-0000000026f1'$$,
  'The API deletes a query');
RESET ROLE;
SELECT is((SELECT string_agg(action, ',' ORDER BY audit_id) FROM mdm.audit_log
           WHERE table_name = 'saved_query' AND coalesce(new_row, old_row) ->> 'saved_query_id' = '00000000-0000-0000-0000-0000000026f1'),
  'INSERT,UPDATE,DELETE', 'Every change to a saved query is audited');
SELECT is((SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'mdm' AND p.proname IN ('trg_saved_query_update', 'resolve_properties_batch', 'filter_compile',
                                                     'filter_holds', 'filter_condition_holds', 'filter_node_attrs')
             AND p.prosrc ~* '\mwf(_bridge)?\.'),
  0, 'No query function refers to wf or wf_bridge (CLAUDE.md rule 3)');

SELECT * FROM finish();
ROLLBACK;
