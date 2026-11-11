-- pgTAP: business-day functions (ADR-018) and the commit-policy activation guard (OD-08), Phase 2 increment 2-1.
-- Synthetic data only.
BEGIN;
SELECT plan(11);

-- Business day in America/New_York -------------------------------------------------------------------------------
SELECT is(mdm.business_time_zone(), 'America/New_York', 'The business time zone comes from the owner-only setting');
SELECT is(mdm.business_day_start('2027-01-12'), '2027-01-12 05:00:00+00'::timestamptz, 'A winter business day starts at 05:00 UTC (EST)');
SELECT is(mdm.business_day_start('2027-07-12'), '2027-07-12 04:00:00+00'::timestamptz, 'A summer business day starts at 04:00 UTC (EDT)');
SELECT is(mdm.business_date_of('2027-01-12 04:59:59+00'), '2027-01-11'::date, 'Just before 05:00 UTC in winter is still the previous business day');
SELECT is(mdm.business_date_of('2027-07-12 04:00:00+00'), '2027-07-12'::date, 'At 04:00 UTC in summer the business day has begun');
SELECT is(mdm.business_day_start('2027-03-15') - mdm.business_day_start('2027-03-14'), interval '23 hours',
  'The spring daylight-saving day is 23 hours long');
SELECT is(mdm.business_today(), (now() AT TIME ZONE 'America/New_York')::date, 'Business today follows the business time zone, not the session');

-- Activation guard (OD-08) -----------------------------------------------------------------------------------------
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-000000000ea1', 'b_maker',   'Maker',   'human'),
  ('00000000-0000-0000-0000-000000000ea2', 'b_checker', 'Checker', 'human');
INSERT INTO wf.user_group (group_id, group_code, name) VALUES ('00000000-0000-0000-0000-000000000ee1', 'B_OWNERS', 'Owners');
INSERT INTO wf.user_group_member (group_id, user_id)
SELECT group_id, '00000000-0000-0000-0000-000000000ea2' FROM wf.user_group WHERE group_code = 'POLICY_APPROVERS';
INSERT INTO wf.commit_policy (policy_id, policy_code, description, rationale, mode, allowed_actions, owner_group_id, proposed_by)
VALUES ('00000000-0000-0000-0000-000000000eb1', 'B_ACTIVE', 'Active', 'Test', 'active', '{add_node}',
        '00000000-0000-0000-0000-000000000ee1', '00000000-0000-0000-0000-000000000ea1'),
       ('00000000-0000-0000-0000-000000000eb2', 'B_SHADOW', 'Shadow', 'Test', 'shadow', '{add_node}',
        '00000000-0000-0000-0000-000000000ee1', '00000000-0000-0000-0000-000000000ea1');
SELECT wf.submit_commit_policy('00000000-0000-0000-0000-000000000eb1', '00000000-0000-0000-0000-000000000ea1');
SELECT wf.submit_commit_policy('00000000-0000-0000-0000-000000000eb2', '00000000-0000-0000-0000-000000000ea1');

SELECT is(mdm.setting_enabled('policy_activation_allowed'), false, 'Activation is not allowed by default');
SELECT throws_ok(
  $$SELECT wf.approve_commit_policy('00000000-0000-0000-0000-000000000eb1', '00000000-0000-0000-0000-000000000ea2', 'go')$$,
  'N2225', NULL, 'An active policy cannot be approved before Audit-Risk sign-off');
SELECT lives_ok(
  $$SELECT wf.approve_commit_policy('00000000-0000-0000-0000-000000000eb2', '00000000-0000-0000-0000-000000000ea2', 'ok')$$,
  'A shadow policy can be approved');
SELECT is((SELECT review_due FROM wf.commit_policy WHERE policy_id = '00000000-0000-0000-0000-000000000eb2'),
  (mdm.business_today() + interval '12 months')::date, 'Re-certification is due twelve months after the business day of approval');

SELECT * FROM finish();
ROLLBACK;
