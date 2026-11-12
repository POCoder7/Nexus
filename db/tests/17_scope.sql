-- pgTAP: node-access scope by ancestor walk (D-10) at the request's effective date (D-11), Phase 2 increment 2-4.
-- The previous implementation (a walk down the whole sub-tree on current_date) is kept here as a test-only function
-- and must give the same answer for every stage and instance of the fixture. Synthetic data only.
BEGIN;
SELECT plan(9);

-- The previous rule, verbatim except for its name (pg_temp)
CREATE FUNCTION pg_temp.old_items_in_scope(p_instance_stage_id uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
SELECT NOT EXISTS (SELECT 1 FROM wf.stage_access_scope sc JOIN wf.instance_stage ist ON ist.stage_id = sc.stage_id
                   WHERE ist.instance_stage_id = p_instance_stage_id)
    OR NOT EXISTS (
         SELECT 1 FROM wf.instance_stage ist
         JOIN wf.instance_item ii ON ii.instance_id = ist.instance_id
         JOIN mdm.change_item ci  ON ci.change_item_id = ii.change_item_id
         WHERE ist.instance_stage_id = p_instance_stage_id
           AND coalesce(ci.node_id, ci.target_parent_id) IS NOT NULL
           AND NOT EXISTS (
             SELECT 1 FROM wf.stage_access_scope sc
             CROSS JOIN LATERAL mdm.hierarchy_tree(sc.hierarchy_id, current_date, now(), sc.top_node_id) t
             WHERE sc.stage_id = ist.stage_id AND t.node_id IN (ci.node_id, ci.target_parent_id)))
$$;

-- Trees: H1  T ─ A ─ A1 ─ A1a      H2  T2 ─ A (A in both)
--             └─ B ─ B1                 └─ C
--             B1 is also shared under A; X is under B until 2031-01-01 and under A from then on.
INSERT INTO mdm.node (node_id, node_kind)
SELECT ('00000000-0000-0000-0000-0000000011' || n)::uuid, 'structural' FROM unnest(ARRAY['01','02','03','04','05','06','07','08','09','0a']) AS n;
--  01 T  02 A  03 A1  04 A1a  05 B  06 B1  07 T2  08 C  09 X  0a new (allocated, not placed)
INSERT INTO mdm.node_attr (node_id, node_name, valid_period)
SELECT ('00000000-0000-0000-0000-0000000011' || n)::uuid, 'SC ' || n, daterange('2020-01-01', NULL)
FROM unnest(ARRAY['01','02','03','04','05','06','07','08','09']) AS n;
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id, allow_shared_nodes) VALUES
  ('00000000-0000-0000-0000-000000001191', 'SC_H1', 'One', '00000000-0000-0000-0000-000000001101', true),
  ('00000000-0000-0000-0000-000000001192', 'SC_H2', 'Two', '00000000-0000-0000-0000-000000001107', false);
INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, is_primary, valid_period)
SELECT ('00000000-0000-0000-0000-00000000119' || h)::uuid, ('00000000-0000-0000-0000-0000000011' || p)::uuid,
       ('00000000-0000-0000-0000-0000000011' || c)::uuid, pri, daterange(lo::date, hi::date) FROM (VALUES
  ('1', '01', '02', true, '2020-01-01', NULL), ('1', '02', '03', true, '2020-01-01', NULL), ('1', '03', '04', true, '2020-01-01', NULL),
  ('1', '01', '05', true, '2020-01-01', NULL), ('1', '05', '06', true, '2020-01-01', NULL), ('1', '02', '06', false, '2020-01-01', NULL),
  ('1', '05', '09', true, '2020-01-01', '2031-01-01'), ('1', '02', '09', true, '2031-01-01', NULL),
  ('2', '07', '02', true, '2020-01-01', NULL), ('2', '07', '08', true, '2020-01-01', NULL)) AS v(h, p, c, pri, lo, hi);

-- Model: Submit → Approve (A) → Approve (B) → Approve (A in H1 or C in H2) → Approve (no scope) → Commit
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES ('00000000-0000-0000-0000-0000000011a1', 'sc_steward', 'Steward', 'human');
INSERT INTO mdm.version (version_id, version_name, business_as_of) VALUES ('00000000-0000-0000-0000-0000000011b1', 'SC_V', current_date);
INSERT INTO wf.user_group (group_id, group_code, name) VALUES ('00000000-0000-0000-0000-0000000011c1', 'SC_G', 'Group');
INSERT INTO wf.workflow_task (task_id, task_code, label) VALUES ('00000000-0000-0000-0000-0000000011d1', 'SC_TASK', 'Task');
INSERT INTO wf.workflow_model (model_id, model_code, label) VALUES ('00000000-0000-0000-0000-0000000011e1', 'SC_MODEL', 'Model');
INSERT INTO wf.workflow_stage (stage_id, model_id, seq, stage_type, label, task_id)
SELECT ('00000000-0000-0000-0000-0000000011f' || s)::uuid, '00000000-0000-0000-0000-0000000011e1', s,
       CASE s WHEN 1 THEN 'submit' WHEN 6 THEN 'commit' ELSE 'approve' END::wf.stage_type, 'Stage ' || s,
       CASE WHEN s BETWEEN 2 AND 5 THEN '00000000-0000-0000-0000-0000000011d1'::uuid END
FROM generate_series(1, 6) s;
INSERT INTO wf.submit_task VALUES ('00000000-0000-0000-0000-0000000011e1', '00000000-0000-0000-0000-0000000011d1');
INSERT INTO wf.stage_group (stage_id, group_id)
SELECT ('00000000-0000-0000-0000-0000000011f' || s)::uuid, '00000000-0000-0000-0000-0000000011c1' FROM generate_series(2, 6) s;
INSERT INTO wf.stage_access_scope (stage_id, hierarchy_id, top_node_id) VALUES
  ('00000000-0000-0000-0000-0000000011f2', '00000000-0000-0000-0000-000000001191', '00000000-0000-0000-0000-000000001102'),
  ('00000000-0000-0000-0000-0000000011f3', '00000000-0000-0000-0000-000000001191', '00000000-0000-0000-0000-000000001105'),
  ('00000000-0000-0000-0000-0000000011f4', '00000000-0000-0000-0000-000000001191', '00000000-0000-0000-0000-000000001102'),
  ('00000000-0000-0000-0000-0000000011f4', '00000000-0000-0000-0000-000000001192', '00000000-0000-0000-0000-000000001108');
UPDATE wf.workflow_model SET status = 'active', activated_by = '00000000-0000-0000-0000-0000000011a1' WHERE model_id = '00000000-0000-0000-0000-0000000011e1';

-- One request per item set; effective today unless stated
CREATE FUNCTION pg_temp.req(p_title text, p_from date, p_items jsonb) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid; it jsonb; n int := 0;
BEGIN
  INSERT INTO mdm.change_request (version_id, title, requester_id, requester_kind, effective_from)
  VALUES ('00000000-0000-0000-0000-0000000011b1', p_title, '00000000-0000-0000-0000-0000000011a1', 'human', p_from)
  RETURNING change_request_id INTO v;
  FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    n := n + 1;
    INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, target_parent_id)
    VALUES (v, n, (it ->> 'a')::mdm.change_action, '00000000-0000-0000-0000-000000001191',
            ('00000000-0000-0000-0000-0000000011' || (it ->> 'n'))::uuid,
            CASE WHEN it ? 't' THEN ('00000000-0000-0000-0000-0000000011' || (it ->> 't'))::uuid END);
  END LOOP;
  PERFORM wf.start_instance(v, 'SC_MODEL', '00000000-0000-0000-0000-0000000011a1');
  RETURN v;
END $$;
SELECT pg_temp.req('SC a1a',   current_date, '[{"a":"update_node","n":"04"}]');
SELECT pg_temp.req('SC b1',    current_date, '[{"a":"update_node","n":"06"}]');                    -- under B, shared under A
SELECT pg_temp.req('SC new',   current_date, '[{"a":"add_node","n":"0a","t":"03"}]');              -- new node: its parent decides
SELECT pg_temp.req('SC c',     current_date, '[{"a":"update_node","n":"08"}]');                    -- only in H2
SELECT pg_temp.req('SC top',   current_date, '[{"a":"update_node","n":"01"}]');                    -- above every scope
SELECT pg_temp.req('SC mixed', current_date, '[{"a":"update_node","n":"04"},{"a":"update_node","n":"05"}]');
SELECT pg_temp.req('SC x now', current_date, '[{"a":"update_node","n":"09"}]');                    -- X today: under B

CREATE TEMP TABLE cmp AS
SELECT cr.title, ws.seq, wf.items_in_scope(ist.instance_stage_id) AS new_rule, pg_temp.old_items_in_scope(ist.instance_stage_id) AS old_rule
FROM wf.instance_stage ist
JOIN wf.workflow_stage ws ON ws.stage_id = ist.stage_id
JOIN wf.workflow_instance i ON i.instance_id = ist.instance_id
JOIN mdm.change_request cr ON cr.change_request_id = i.change_request_id
WHERE cr.title LIKE 'SC %' AND ws.seq BETWEEN 2 AND 5;

SELECT is((SELECT count(*)::int FROM cmp), 28, 'Every scoped and unscoped stage of every request is compared');
SELECT is((SELECT count(*)::int FROM cmp WHERE new_rule IS DISTINCT FROM old_rule), 0,
  'The ancestor walk gives the same answer as the old whole-tree walk on every case');
SELECT ok((SELECT bool_or(new_rule) AND bool_or(NOT new_rule) FROM cmp), 'The fixture has cases in and out of scope');
SELECT is((SELECT string_agg(seq::text || '=' || new_rule, ' ' ORDER BY seq) FROM cmp WHERE title = 'SC b1'),
  '2=true 3=true 4=true 5=true', 'A shared placement under the scope counts');
SELECT is((SELECT string_agg(seq::text || '=' || new_rule, ' ' ORDER BY seq) FROM cmp WHERE title = 'SC new'),
  '2=true 3=false 4=true 5=true', 'A new node is in scope through its target parent');
SELECT is((SELECT string_agg(seq::text || '=' || new_rule, ' ' ORDER BY seq) FROM cmp WHERE title = 'SC c'),
  '2=false 3=false 4=true 5=true', 'A scope in another hierarchy counts for nodes in that hierarchy');
SELECT is((SELECT string_agg(seq::text || '=' || new_rule, ' ' ORDER BY seq) FROM cmp WHERE title = 'SC mixed'),
  '2=false 3=false 4=false 5=true', 'Every item must be in scope, not just one');

-- D-11: the effective date decides, not the day of the check
SELECT pg_temp.req('SC x 2031', '2031-06-01', '[{"a":"update_node","n":"09"}]');
SELECT is((SELECT string_agg(ws.seq::text || '=' || wf.items_in_scope(ist.instance_stage_id), ' ' ORDER BY ws.seq)
           FROM wf.instance_stage ist JOIN wf.workflow_stage ws ON ws.stage_id = ist.stage_id
           JOIN wf.workflow_instance i ON i.instance_id = ist.instance_id
           JOIN mdm.change_request cr ON cr.change_request_id = i.change_request_id
           WHERE cr.title = 'SC x 2031' AND ws.seq IN (2, 3)),
  '2=true 3=false', 'A node moved under A from 2031 is in A''s scope for a request effective in 2031');
SELECT is((SELECT string_agg(seq::text || '=' || new_rule, ' ' ORDER BY seq) FROM cmp WHERE title = 'SC x now' AND seq IN (2, 3)),
  '2=false 3=true', '… and in B''s scope for a request effective today');

SELECT * FROM finish();
ROLLBACK;
