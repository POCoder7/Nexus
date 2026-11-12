-- pgTAP: draft-side functions (Phase 1 LLD §4.7): node identity allocation and withdrawal, run with the owners'
-- rights (ADR-019) and callable by the API role.
BEGIN;
SELECT plan(8);

INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-0000000008a1', 'f_steward', 'Steward', 'human'),
  ('00000000-0000-0000-0000-0000000008a2', 'f_other',   'Other',   'human');
INSERT INTO mdm.version (version_id, version_name, business_as_of)
VALUES ('00000000-0000-0000-0000-0000000008b1', 'F_VERSION', current_date);
INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind) VALUES
  ('00000000-0000-0000-0000-0000000008f1', '00000000-0000-0000-0000-0000000008b1', 'F draft',     '00000000-0000-0000-0000-0000000008a1', 'human'),
  ('00000000-0000-0000-0000-0000000008f2', '00000000-0000-0000-0000-0000000008b1', 'F submitted', '00000000-0000-0000-0000-0000000008a1', 'human');
UPDATE mdm.change_request SET status = 'submitted' WHERE change_request_id = '00000000-0000-0000-0000-0000000008f2';

SET LOCAL ROLE nexus_api;

SELECT lives_ok(
  $$SELECT mdm.allocate_node('legal_entity', '00000000-0000-0000-0000-0000000008f1')$$,
  'The API can allocate a node identity for a draft request');

SELECT throws_ok(
  $$INSERT INTO mdm.node (node_kind) VALUES ('legal_entity')$$,
  '42501', NULL, 'The API cannot create node identities directly');

SELECT throws_ok(
  $$SELECT mdm.allocate_node('legal_entity', '00000000-0000-0000-0000-0000000008f2')$$,
  'N2102', NULL, 'Identities are allocated only for drafts');

SELECT throws_ok(
  $$SELECT mdm.withdraw_change_request('00000000-0000-0000-0000-0000000008f1', '00000000-0000-0000-0000-0000000008a2')$$,
  'N1025', NULL, 'Only the requester can withdraw a request');

SELECT lives_ok(
  $$SELECT mdm.withdraw_change_request('00000000-0000-0000-0000-0000000008f1', '00000000-0000-0000-0000-0000000008a1')$$,
  'The requester can withdraw a draft');

SELECT lives_ok(
  $$SELECT mdm.withdraw_change_request('00000000-0000-0000-0000-0000000008f2', '00000000-0000-0000-0000-0000000008a1')$$,
  'The requester can withdraw a submitted request');

RESET ROLE;

SELECT is((SELECT string_agg(status::text, ',' ORDER BY title) FROM mdm.change_request
           WHERE change_request_id IN ('00000000-0000-0000-0000-0000000008f1', '00000000-0000-0000-0000-0000000008f2')),
          'withdrawn,withdrawn', 'Both requests are withdrawn');

SELECT throws_ok(
  $$SELECT mdm.withdraw_change_request('00000000-0000-0000-0000-0000000008f1', '00000000-0000-0000-0000-0000000008a1')$$,
  'N2101', NULL, 'A withdrawn request cannot be withdrawn again');

SELECT * FROM finish();
ROLLBACK;
