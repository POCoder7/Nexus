-- pgTAP: UI support (Phase 3 LLD §4, increment 3-1): user preferences and in-tree search indexes.
-- Synthetic data only.
BEGIN;
SELECT plan(15);

INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-000000003a01', 'ui_pref_user', 'Preference user', 'human'),
  ('00000000-0000-0000-0000-000000003a02', 'ui_granter', 'Granter', 'human');

-- Preferences: defaults and checks -------------------------------------------------------------------------------
INSERT INTO mdm.user_preference (user_id) VALUES ('00000000-0000-0000-0000-000000003a01');
SELECT is((SELECT start_page FROM mdm.user_preference WHERE user_id = '00000000-0000-0000-0000-000000003a01'), 'home',
  'The start page defaults to Home (OD-27)');
SELECT is((SELECT density FROM mdm.user_preference WHERE user_id = '00000000-0000-0000-0000-000000003a01'), 'compact',
  'Density defaults to compact (UI_STANDARD §4)');
SELECT throws_ok($$UPDATE mdm.user_preference SET start_page = 'admin' WHERE user_id = '00000000-0000-0000-0000-000000003a01'$$,
  '23514', NULL, 'An unknown start page is refused');
SELECT throws_ok($$UPDATE mdm.user_preference SET density = 'tiny' WHERE user_id = '00000000-0000-0000-0000-000000003a01'$$,
  '23514', NULL, 'An unknown density is refused');
SELECT throws_ok($$INSERT INTO mdm.user_preference (user_id) VALUES ('00000000-0000-0000-0000-000000003a01')$$,
  '23505', NULL, 'One preference row per user');

-- Privileges: only the API writes, and it cannot delete ----------------------------------------------------------
SELECT ok(has_any_column_privilege('nexus_api', 'mdm.user_preference', 'INSERT'), 'The API may create a preference row');
SELECT ok(has_column_privilege('nexus_api', 'mdm.user_preference', 'start_page', 'UPDATE'), 'The API may update the start page');
SELECT ok(NOT has_column_privilege('nexus_api', 'mdm.user_preference', 'user_id', 'UPDATE'),
  'The API may update preference values but never move a row to another user');
SELECT ok(NOT has_table_privilege('nexus_api', 'mdm.user_preference', 'DELETE'), 'The API may not delete preference rows');
SELECT ok(NOT has_any_column_privilege('nexus_wf', 'mdm.user_preference', 'INSERT')
          AND NOT has_any_column_privilege('nexus_wf', 'mdm.user_preference', 'UPDATE'),
  'The workflow worker cannot write preferences (wf never writes mdm)');

-- Search ---------------------------------------------------------------------------------------------------------
SELECT has_extension('pg_trgm', 'pg_trgm is installed for in-tree search (OD-21)');
SELECT has_index('mdm', 'node_attr', 'node_attr_name_trgm', 'Trigram index on node names');
SELECT has_index('mdm', 'node_attr', 'node_attr_description_trgm', 'Trigram index on node descriptions');

-- Property edit rights by category (ADR-036) -----------------------------------------------------------------------
SELECT has_column('mdm', 'user_role', 'category_codes', 'Grants can be limited to property categories');
SELECT throws_ok($$INSERT INTO mdm.user_role (user_id, role_code, granted_by, valid_period, category_codes)
  VALUES ('00000000-0000-0000-0000-000000003a01', 'STEWARD', '00000000-0000-0000-0000-000000003a02', daterange(current_date, NULL), '{}')$$,
  '23514', NULL, 'An empty category list is refused (NULL means all categories)');

SELECT * FROM finish();
ROLLBACK;
