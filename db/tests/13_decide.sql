-- pgTAP: decide_change_request and record_apply_failure (Phase 1 LLD §4.7, §6.4, increment 1-10): maker-checker,
-- human-only decisions, no forged policy basis (D-04). Synthetic data only.
BEGIN;
SELECT plan(14);

INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-000000000da1', 'd_steward',  'Steward',  'human'),
  ('00000000-0000-0000-0000-000000000da2', 'd_approver', 'Approver', 'human'),
  ('00000000-0000-0000-0000-000000000da3', 'd_agent',    'Agent',    'ai_agent');
INSERT INTO mdm.version (version_id, version_name, business_as_of)
VALUES ('00000000-0000-0000-0000-000000000db1', 'D_VERSION', current_date);
INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind)
SELECT ('00000000-0000-0000-0000-000000000dc' || n)::uuid, '00000000-0000-0000-0000-000000000db1', 'D ' || n,
       '00000000-0000-0000-0000-000000000da1', 'human'
FROM unnest(ARRAY['1', '2', '3', '4', '5']) AS n;
UPDATE mdm.change_request SET status = 'submitted'
WHERE change_request_id IN ('00000000-0000-0000-0000-000000000dc1', '00000000-0000-0000-0000-000000000dc2',
                            '00000000-0000-0000-0000-000000000dc3', '00000000-0000-0000-0000-000000000dc5');
UPDATE mdm.change_request SET governed_by_workflow = true WHERE change_request_id = '00000000-0000-0000-0000-000000000dc5';

SET LOCAL ROLE nexus_api;
SELECT throws_ok($$UPDATE mdm.change_request SET decision_basis = 'approved_policy'
                   WHERE change_request_id = '00000000-0000-0000-0000-000000000dc1'$$,
  '42501', NULL, 'The API cannot write decision columns itself (D-04)');
SELECT throws_ok($$SELECT mdm.decide_change_request('00000000-0000-0000-0000-000000000dc1', '00000000-0000-0000-0000-000000000da1', 'approve', NULL)$$,
  'N1001', NULL, 'The requester cannot decide their own request');
SELECT throws_ok($$SELECT mdm.decide_change_request('00000000-0000-0000-0000-000000000dc1', '00000000-0000-0000-0000-000000000da3', 'approve', NULL)$$,
  'N1002', NULL, 'An AI agent cannot decide');
SELECT throws_ok($$SELECT mdm.decide_change_request('00000000-0000-0000-0000-000000000dc1', '00000000-0000-0000-0000-000000000da2', 'maybe', NULL)$$,
  '22023', NULL, 'A decision is approve or reject');
SELECT throws_ok($$SELECT mdm.decide_change_request('00000000-0000-0000-0000-000000000dc4', '00000000-0000-0000-0000-000000000da2', 'approve', NULL)$$,
  'N2101', NULL, 'A draft cannot be decided');
SELECT throws_ok($$SELECT mdm.decide_change_request('00000000-0000-0000-0000-000000000dc5', '00000000-0000-0000-0000-000000000da2', 'approve', NULL)$$,
  'N2104', NULL, 'A request governed by a workflow is decided there');
SELECT lives_ok($$SELECT mdm.decide_change_request('00000000-0000-0000-0000-000000000dc1', '00000000-0000-0000-0000-000000000da2', 'approve', 'Looks right')$$,
  'A second human can approve');
SELECT lives_ok($$SELECT mdm.decide_change_request('00000000-0000-0000-0000-000000000dc2', '00000000-0000-0000-0000-000000000da2', 'reject', 'Wrong parent')$$,
  'A second human can reject');
SELECT throws_ok($$SELECT mdm.decide_change_request('00000000-0000-0000-0000-000000000dc1', '00000000-0000-0000-0000-000000000da2', 'reject', NULL)$$,
  'N2101', NULL, 'A decided request cannot be decided again');
SELECT lives_ok($$SELECT mdm.record_apply_failure('00000000-0000-0000-0000-000000000dc1', 'serialization failure after 3 tries')$$,
  'An approved request whose apply keeps failing can be recorded as failed');
SELECT throws_ok($$SELECT mdm.record_apply_failure('00000000-0000-0000-0000-000000000dc3', 'x')$$,
  'N2101', NULL, 'Only an approved request can be recorded as failed');
RESET ROLE;

SELECT is((SELECT status || '/' || decision_basis || '/' || decided_by || '/' || decision_note FROM mdm.change_request
           WHERE change_request_id = '00000000-0000-0000-0000-000000000dc2'),
  'rejected/human_review/00000000-0000-0000-0000-000000000da2/Wrong parent', 'The decision, its basis, decider and note are recorded');
SELECT ok((SELECT decided_at IS NOT NULL FROM mdm.change_request WHERE change_request_id = '00000000-0000-0000-0000-000000000dc2'),
  'The decision time is recorded');
SELECT is((SELECT status || '/' || apply_error FROM mdm.change_request WHERE change_request_id = '00000000-0000-0000-0000-000000000dc1'),
  'apply_failed/retry-later: serialization failure after 3 tries', 'A technical apply failure is recorded with its reason');

SELECT * FROM finish();
ROLLBACK;
