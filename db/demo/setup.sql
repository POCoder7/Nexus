-- Demo setup, before the data set is loaded (scripts/demo.sh). SYNTHETIC DATA ONLY.
-- The demo holds only the hackathon data set (ADR-046): its users, roles and groups come from data/users.csv and
-- data/groups.csv through the governed load. Loading needs two ADMINs who already exist, and nobody can grant
-- themselves access, so two setup administrators run the load and are switched off afterwards (db/demo/after-load.sql).
-- Runs as the database owner on a fresh, migrated demo database. The automated tests use ui/e2e/seed.sql instead.
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-0000000d5e01', 'setup_admin1', 'Setup administrator one', 'human'),
  ('00000000-0000-0000-0000-0000000d5e02', 'setup_admin2', 'Setup administrator two', 'human'),
  -- the workflow engine's system actor: it records commit-policy evaluations (mdm.workflow.system-actor-login); it holds
  -- no role and stays active
  ('00000000-0000-0000-0000-0000000d5eff', 'nexus_system', 'Nexus system', 'system_feed');
-- each grants the other (nobody grants themselves a role)
INSERT INTO mdm.user_role (user_id, role_code, hierarchy_id, granted_by, valid_period) VALUES
  ('00000000-0000-0000-0000-0000000d5e01', 'ADMIN', NULL, '00000000-0000-0000-0000-0000000d5e02', daterange(current_date - 1, NULL)),
  ('00000000-0000-0000-0000-0000000d5e02', 'ADMIN', NULL, '00000000-0000-0000-0000-0000000d5e01', daterange(current_date - 1, NULL));
