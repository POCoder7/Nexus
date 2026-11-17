-- pgTAP: governed access changes (ADR-042 D3; Phase 5 LLD §19.4, increment 5-4b). One ADMIN proposes, a different
-- ADMIN decides in core mode, apply writes groups, scopes, members and grants as nexus_apply. Synthetic data only.
BEGIN;
SELECT plan(34);

-- ---------------------------------------------------------------- fixtures
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-0000000028a1', 'a28_admin1',   'Admin one',   'human'),
  ('00000000-0000-0000-0000-0000000028a2', 'a28_admin2',   'Admin two',   'human'),
  ('00000000-0000-0000-0000-0000000028a3', 'a28_admin3',   'Admin three', 'human'),   -- also in POLICY_APPROVERS
  ('00000000-0000-0000-0000-0000000028a4', 'a28_user',     'User',        'human'),
  ('00000000-0000-0000-0000-0000000028a5', 'a28_approver', 'Approver',    'human'),   -- APPROVER everywhere, not ADMIN
  ('00000000-0000-0000-0000-0000000028a6', 'a28_owner',    'Bootstrap',   'human'),
  ('00000000-0000-0000-0000-0000000028a7', 'a28_svc',      'Feed',        'service');
INSERT INTO mdm.user_role (user_id, role_code, granted_by, valid_period)
SELECT u::uuid, 'ADMIN', '00000000-0000-0000-0000-0000000028a6', daterange(current_date - 10, NULL)
FROM unnest(ARRAY['00000000-0000-0000-0000-0000000028a1', '00000000-0000-0000-0000-0000000028a2',
                  '00000000-0000-0000-0000-0000000028a3']) AS u;
INSERT INTO mdm.user_role (user_id, role_code, granted_by, valid_period) VALUES
  ('00000000-0000-0000-0000-0000000028a5', 'APPROVER', '00000000-0000-0000-0000-0000000028a6', daterange(current_date - 10, NULL));
INSERT INTO mdm.user_group_member (group_id, user_id)
SELECT group_id, '00000000-0000-0000-0000-0000000028a3' FROM mdm.user_group WHERE group_code = 'POLICY_APPROVERS';

INSERT INTO mdm.node (node_id, node_kind) VALUES ('00000000-0000-0000-0000-0000000028c1', 'structural');
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id)
VALUES ('00000000-0000-0000-0000-0000000028d1', 'A28_H', 'Access hierarchy', '00000000-0000-0000-0000-0000000028c1');
INSERT INTO mdm.version (version_id, version_name, business_as_of)
VALUES ('00000000-0000-0000-0000-0000000028b1', 'A28_VERSION', current_date);

-- A draft request by a requester, effective on a date (default: the business day).
CREATE FUNCTION pg_temp.cr(p_n text, p_requester text, p_from date DEFAULT NULL) RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind, effective_from)
  VALUES (('00000000-0000-0000-0000-0000000028' || p_n)::uuid, '00000000-0000-0000-0000-0000000028b1', 'A28 ' || p_n,
          ('00000000-0000-0000-0000-0000000028' || p_requester)::uuid, 'human', coalesce(p_from, mdm.business_today()))
  RETURNING change_request_id
$$;
CREATE FUNCTION pg_temp.item(p_n text, p_seq int, p_action text, p_payload jsonb) RETURNS void LANGUAGE sql AS $$
  INSERT INTO mdm.change_item (change_request_id, seq, action, payload)
  VALUES (('00000000-0000-0000-0000-0000000028' || p_n)::uuid, p_seq, p_action::mdm.change_action, p_payload)
$$;
CREATE FUNCTION pg_temp.id(p_n text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('00000000-0000-0000-0000-0000000028' || p_n)::uuid
$$;

-- ---------------------------------------------------------------- P: create a group, scope it, fill it
SELECT pg_temp.cr('e1', 'a1');
SELECT pg_temp.item('e1', 1, 'create_group', '{"group": "A28_EDITORS", "name": "Editors", "role": "EDITOR"}');
SELECT pg_temp.item('e1', 2, 'add_group_scope', '{"group": "A28_EDITORS", "hierarchy": "A28_H", "categories": ["Finance"]}');
SELECT pg_temp.item('e1', 3, 'add_group_member', '{"group": "A28_EDITORS", "user": "a28_user"}');
SELECT ok(NOT EXISTS (SELECT 1 FROM mdm.user_group WHERE group_code = 'A28_EDITORS'), 'A proposed access change has no effect');
SELECT mdm.submit_change_request(pg_temp.id('e1'), pg_temp.id('a1'));
SELECT throws_ok($$SELECT mdm.decide_change_request(pg_temp.id('e1'), pg_temp.id('a1'), 'approve', NULL)$$,
  'N1001', NULL, 'The proposer cannot approve their own access change');
SELECT throws_ok($$SELECT mdm.decide_change_request(pg_temp.id('e1'), pg_temp.id('a5'), 'approve', NULL)$$,
  'N1033', NULL, 'An APPROVER for every hierarchy who is not an ADMIN cannot decide it');
SELECT lives_ok($$SELECT mdm.decide_change_request(pg_temp.id('e1'), pg_temp.id('a2'), 'approve', 'ok')$$,
  'A second ADMIN approves');
SELECT ok(mdm.apply_change_request(pg_temp.id('e1'), pg_temp.id('a2')) > 0, 'It applies');
SELECT is((SELECT status::text FROM mdm.change_request WHERE change_request_id = pg_temp.id('e1')), 'applied', '… and is applied');
SELECT set_eq(
  $$SELECT role_code, hierarchy_id, category_codes FROM mdm.effective_grants(pg_temp.id('a4'), mdm.business_today())$$,
  $$VALUES ('EDITOR', '00000000-0000-0000-0000-0000000028d1'::uuid, '{Finance}'::text[])$$,
  'The member now holds the group''s role on its scope, limited to its categories');
SELECT is((SELECT count(*)::int FROM mdm.user_group_member m JOIN mdm.user_group g USING (group_id)
           WHERE g.group_code = 'A28_EDITORS' AND m.change_request_id = pg_temp.id('e1')
             AND m.granted_by = pg_temp.id('a1')),
  1, 'The membership row names its request and the proposer who granted it');
SELECT ok((SELECT count(*) FROM mdm.audit_log WHERE change_request_id = pg_temp.id('e1')
           AND table_name IN ('user_group', 'user_group_scope', 'user_group_member')) >= 3,
  'Every row written is audited with its request');

-- ---------------------------------------------------------------- P: a direct grant, then its revocation
SELECT pg_temp.cr('e2', 'a2');
SELECT pg_temp.item('e2', 1, 'grant_role', '{"user": "a28_user", "role": "VIEWER"}');
SELECT mdm.submit_change_request(pg_temp.id('e2'), pg_temp.id('a2'));
SELECT mdm.decide_change_request(pg_temp.id('e2'), pg_temp.id('a1'), 'approve', NULL);
SELECT mdm.apply_change_request(pg_temp.id('e2'), pg_temp.id('a1'));
SELECT ok(EXISTS (SELECT 1 FROM mdm.effective_grants(pg_temp.id('a4'), mdm.business_today())
                  WHERE role_code = 'VIEWER' AND hierarchy_id IS NULL AND source_group_id IS NULL),
  'A direct grant applies');
SELECT pg_temp.cr('e3', 'a1');
SELECT pg_temp.item('e3', 1, 'revoke_role', '{"user": "a28_user", "role": "VIEWER"}');
SELECT pg_temp.item('e3', 2, 'remove_group_member', '{"group": "A28_EDITORS", "user": "a28_user"}');
SELECT mdm.submit_change_request(pg_temp.id('e3'), pg_temp.id('a1'));
SELECT mdm.decide_change_request(pg_temp.id('e3'), pg_temp.id('a2'), 'approve', NULL);
SELECT mdm.apply_change_request(pg_temp.id('e3'), pg_temp.id('a2'));
SELECT is((SELECT count(*)::int FROM mdm.effective_grants(pg_temp.id('a4'), mdm.business_today())), 0,
  'Revoking the grant and ending the membership leave the user nothing today');
SELECT is((SELECT count(*)::int FROM mdm.user_group_member m JOIN mdm.user_group g USING (group_id)
           WHERE g.group_code = 'A28_EDITORS' AND NOT upper_inf(m.recorded_period)),
  1, 'The ended membership is kept as a closed row, not deleted');

-- ---------------------------------------------------------------- N: proposing
SELECT pg_temp.cr('e4', 'a5');
SELECT throws_ok($$SELECT pg_temp.item('e4', 1, 'add_group_member', '{"group": "A28_EDITORS", "user": "a28_user"}')$$,
  'N1033', NULL, 'Only an ADMIN proposes access changes');
SELECT pg_temp.cr('e5', 'a1');
SELECT throws_ok($$SELECT pg_temp.item('e5', 1, 'add_group_member', '{"group": "A28_EDITORS", "user": "a28_admin1"}')$$,
  'N1034', NULL, 'Nobody proposes a membership for themselves');
SELECT throws_ok($$SELECT pg_temp.item('e5', 1, 'grant_role', '{"user": "a28_admin1", "role": "VIEWER"}')$$,
  'N1034', NULL, '… or a role');
SELECT throws_ok($$INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, payload)
                   VALUES (pg_temp.id('e5'), 1, 'grant_role', '00000000-0000-0000-0000-0000000028d1', '{"user": "a28_user", "role": "VIEWER"}')$$,
  'N2237', NULL, 'An access item names its scope in the payload, not the item''s hierarchy');
SELECT pg_temp.item('e5', 1, 'grant_role', '{"user": "a28_user", "role": "VIEWER"}');
SELECT throws_ok($$INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, payload)
                   VALUES (pg_temp.id('e5'), 2, 'update_node', '00000000-0000-0000-0000-0000000028d1',
                           '00000000-0000-0000-0000-0000000028c1', '{"name": "x"}')$$,
  'N2237', NULL, 'Access changes and hierarchy changes do not share a request');
SELECT throws_ok($$UPDATE mdm.change_request SET governed_by_workflow = true WHERE change_request_id = pg_temp.id('e5')$$,
  'N2237', NULL, 'An access request is never governed by a workflow');

-- ---------------------------------------------------------------- N: deciding
SELECT pg_temp.cr('e6', 'a1');
SELECT pg_temp.item('e6', 1, 'add_group_member', '{"group": "A28_EDITORS", "user": "a28_admin2"}');
SELECT mdm.submit_change_request(pg_temp.id('e6'), pg_temp.id('a1'));
SELECT throws_ok($$SELECT mdm.decide_change_request(pg_temp.id('e6'), pg_temp.id('a2'), 'approve', NULL)$$,
  'N1034', NULL, 'An ADMIN cannot approve a membership for themselves');
SELECT lives_ok($$SELECT mdm.decide_change_request(pg_temp.id('e6'), pg_temp.id('a3'), 'approve', NULL)$$,
  'A third ADMIN can');

SELECT pg_temp.cr('e7', 'a1');
SELECT pg_temp.item('e7', 1, 'add_group_member', '{"group": "POLICY_APPROVERS", "user": "a28_user"}');
SELECT mdm.submit_change_request(pg_temp.id('e7'), pg_temp.id('a1'));
SELECT throws_ok($$SELECT mdm.decide_change_request(pg_temp.id('e7'), pg_temp.id('a2'), 'approve', NULL)$$,
  'N1020', NULL, 'A change to POLICY_APPROVERS needs an approver who is in it');
SELECT lives_ok($$SELECT mdm.decide_change_request(pg_temp.id('e7'), pg_temp.id('a3'), 'approve', NULL)$$,
  'A member of POLICY_APPROVERS who is an ADMIN approves it');
SELECT mdm.submit_change_request(pg_temp.id('e5'), pg_temp.id('a1'));
SELECT lives_ok($$SELECT mdm.decide_change_request(pg_temp.id('e5'), pg_temp.id('a2'), 'reject', 'not needed')$$,
  'Rejecting needs an ADMIN too, and works');

-- ---------------------------------------------------------------- N: applying
SELECT pg_temp.cr('e8', 'a1', mdm.business_today() - 1);
SELECT pg_temp.item('e8', 1, 'grant_role', '{"user": "a28_user", "role": "VIEWER"}');
SELECT mdm.submit_change_request(pg_temp.id('e8'), pg_temp.id('a1'));
SELECT mdm.decide_change_request(pg_temp.id('e8'), pg_temp.id('a2'), 'approve', NULL);
SELECT is(mdm.apply_change_request(pg_temp.id('e8'), pg_temp.id('a2')), -1, 'A back-dated access change does not apply');
SELECT matches((SELECT apply_error FROM mdm.change_request WHERE change_request_id = pg_temp.id('e8')), '^N2233',
  '… and says why');

SELECT pg_temp.cr('e9', 'a1');
SELECT pg_temp.item('e9', 1, 'update_group', '{"group": "A28_EDITORS", "role": "APPROVER"}');
SELECT pg_temp.item('e9', 2, 'add_group_member', '{"group": "NO_SUCH_GROUP", "user": "a28_user"}');
SELECT mdm.submit_change_request(pg_temp.id('e9'), pg_temp.id('a1'));
SELECT mdm.decide_change_request(pg_temp.id('e9'), pg_temp.id('a2'), 'approve', NULL);
SELECT is(mdm.apply_change_request(pg_temp.id('e9'), pg_temp.id('a2')), -1, 'An invalid access request does not apply');
SELECT matches((SELECT apply_error FROM mdm.change_request WHERE change_request_id = pg_temp.id('e9')), '^N2105 \(item 1\).*has scopes or members',
  'A group''s role cannot change while it has members (and nothing of the request is applied)');

SELECT pg_temp.cr('ea', 'a1');
SELECT pg_temp.item('ea', 1, 'add_group_member', '{"group": "A28_EDITORS", "user": "a28_admin2"}');
SELECT mdm.submit_change_request(pg_temp.id('ea'), pg_temp.id('a1'));
SELECT mdm.decide_change_request(pg_temp.id('ea'), pg_temp.id('a3'), 'approve', NULL);
SELECT mdm.apply_change_request(pg_temp.id('e6'), pg_temp.id('a3'));
SELECT is(mdm.apply_change_request(pg_temp.id('ea'), pg_temp.id('a3')), -1, 'Adding someone already in the group does not apply');
SELECT matches((SELECT apply_error FROM mdm.change_request WHERE change_request_id = pg_temp.id('ea')), '^N2232', '… (N2232)');

SELECT pg_temp.cr('eb', 'a1');
SELECT pg_temp.item('eb', 1, 'add_group_member', '{"group": "A28_EDITORS", "user": "a28_svc"}');
SELECT mdm.submit_change_request(pg_temp.id('eb'), pg_temp.id('a1'));
SELECT mdm.decide_change_request(pg_temp.id('eb'), pg_temp.id('a2'), 'approve', NULL);
SELECT throws_ok($$SELECT mdm.apply_change_request(pg_temp.id('eb'), pg_temp.id('a2'))$$,
  'N1032', NULL, 'Holder kinds still hold at apply: a service account cannot join an EDITOR group');

-- ---------------------------------------------------------------- hard limits and direct writes
SELECT throws_ok($$INSERT INTO wf.commit_policy (policy_code, description, rationale, allowed_actions, owner_group_id, proposed_by)
                   SELECT 'A28_P', 'x', 'x', '{add_group_member}', group_id, '00000000-0000-0000-0000-0000000028a1'
                   FROM mdm.user_group WHERE group_code = 'POLICY_APPROVERS'$$,
  '23514', NULL, 'No commit policy can let an access change through without a second ADMIN');
SET LOCAL ROLE nexus_api;
SELECT throws_ok($$INSERT INTO mdm.user_group_member (group_id, user_id)
                   SELECT group_id, '00000000-0000-0000-0000-0000000028a4' FROM mdm.user_group WHERE group_code = 'A28_EDITORS'$$,
  '42501', NULL, 'The API login cannot write memberships');
SELECT throws_ok($$SELECT mdm.apply_add_group_member(ci) FROM mdm.change_item ci WHERE change_request_id = pg_temp.id('ea')$$,
  '42501', NULL, 'Nor call the apply handlers');
RESET ROLE;
SELECT ok(has_table_privilege('nexus_apply', 'mdm.user_group_member', 'INSERT')
          AND NOT has_table_privilege('nexus_apply', 'mdm.user_group_member', 'DELETE'),
  'Apply may add membership rows and close them, never delete them');

SELECT * FROM finish();
ROLLBACK;
