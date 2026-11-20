-- Demo setup, after the data set is loaded (scripts/demo.sh). SYNTHETIC DATA ONLY.
-- 1. The two workflows every on-screen edit uses (ui/src/app/core/config.ts): ADD_LEAF for "Add child" and MAINTAIN for
--    every other change. Submit, Approve, Commit (owner's choice, 2026-11-20); approve and commit by the data set's
--    approver groups, by hierarchy through the groups' scopes (ORG_APPROVERS: ORGNEXUS and ORGNHYD; AM_APPROVERS:
--    ORGSPI); separation of duties on both, so approving and committing are two people.
-- 2. Shared nodes allowed in every hierarchy, as the owner asked for the demo (2026-11-20), until a governed action to
--    change a hierarchy's settings exists.
-- 3. The setup administrators are switched off: from here on only the data set's users can sign in.
-- Runs as the database owner, like the tests' seed. A demo convenience, not a governed change.
BEGIN;   -- all or nothing

-- 1. Workflows ------------------------------------------------------------------------------------------------------
INSERT INTO wf.workflow_task (task_code, label, allowed_actions) VALUES
  ('DEMO_ADD_LEAF', 'Describe the new node', '{add_node,set_property}'),
  ('DEMO_MAINTAIN', 'Describe the change',
   '{add_node,insert_node,move_node,remove_node,delete_node,update_node,add_hierarchy,set_property,clear_property}'),
  ('DEMO_APPROVE', 'Approve the request', '{}');
-- every stored attribute is editable; the required ones are required when a node is added
INSERT INTO wf.task_property (task_id, property_id, is_required, sort_seq)
SELECT t.task_id, p.property_id, t.task_code = 'DEMO_ADD_LEAF' AND p.is_required,
       row_number() OVER (PARTITION BY t.task_id ORDER BY p.is_required DESC, p.property_code)
FROM wf.workflow_task t CROSS JOIN mdm.property_definition p
WHERE t.task_code IN ('DEMO_ADD_LEAF', 'DEMO_MAINTAIN') AND p.origin = 'stored';

INSERT INTO wf.workflow_model (model_id, model_code, label, created_by) VALUES
  ('00000000-0000-0000-0000-0000000d5f01', 'ADD_LEAF', 'Add a node', '00000000-0000-0000-0000-0000000d5e01'),
  ('00000000-0000-0000-0000-0000000d5f02', 'MAINTAIN', 'Maintain nodes and properties', '00000000-0000-0000-0000-0000000d5e01');
INSERT INTO wf.workflow_stage (model_id, seq, stage_type, label, task_id, separation_of_duties)
SELECT m.model_id, s.seq, s.stage_type::wf.stage_type, s.label,
       CASE WHEN s.stage_type = 'approve' THEN (SELECT task_id FROM wf.workflow_task WHERE task_code = 'DEMO_APPROVE') END,
       s.stage_type <> 'submit'
FROM wf.workflow_model m
CROSS JOIN (VALUES (1, 'submit', 'Submit'), (2, 'approve', 'Approve'), (3, 'commit', 'Commit')) AS s(seq, stage_type, label)
WHERE m.model_id IN ('00000000-0000-0000-0000-0000000d5f01', '00000000-0000-0000-0000-0000000d5f02');
INSERT INTO wf.submit_task (model_id, task_id)
SELECT '00000000-0000-0000-0000-0000000d5f01'::uuid, task_id FROM wf.workflow_task WHERE task_code = 'DEMO_ADD_LEAF'
UNION ALL
SELECT '00000000-0000-0000-0000-0000000d5f02'::uuid, task_id FROM wf.workflow_task WHERE task_code = 'DEMO_MAINTAIN';
INSERT INTO wf.stage_group (stage_id, group_id)
SELECT s.stage_id, g.group_id
FROM wf.workflow_stage s JOIN mdm.user_group g ON g.group_code IN ('ORG_APPROVERS', 'AM_APPROVERS')
WHERE s.model_id IN ('00000000-0000-0000-0000-0000000d5f01', '00000000-0000-0000-0000-0000000d5f02') AND s.seq IN (2, 3);
-- activated by the second administrator (GOV-01)
UPDATE wf.workflow_model SET status = 'active', activated_by = '00000000-0000-0000-0000-0000000d5e02', activated_at = now()
WHERE model_id IN ('00000000-0000-0000-0000-0000000d5f01', '00000000-0000-0000-0000-0000000d5f02');

-- 2. Shared nodes ---------------------------------------------------------------------------------------------------
SELECT set_config('mdm.actor_id', '00000000-0000-0000-0000-0000000d5e01', false);
UPDATE mdm.hierarchy SET allow_shared_nodes = true WHERE NOT allow_shared_nodes;

-- 3. Setup administrators off ---------------------------------------------------------------------------------------
UPDATE mdm.app_user SET is_active = false WHERE login IN ('setup_admin1', 'setup_admin2');
COMMIT;
