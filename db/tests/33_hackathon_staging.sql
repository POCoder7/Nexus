-- pgTAP: staging and profiling the hackathon CSV data set (ADR-046; Phase 4 LLD §17.1; increment H-5). Synthetic rows.
-- Everything runs as nexus_api: the API reaches mdm_stage only through the loader's functions (CLAUDE.md rule 3).
BEGIN;
SELECT plan(14);

INSERT INTO mdm.app_user (user_id, login, display_name, kind)
VALUES ('00000000-0000-0000-0000-000000003301', 's_admin', 'Staging admin', 'human');

-- Stage one file of a load: header and rows as text arrays.
CREATE FUNCTION pg_temp.stage(p_load uuid, p_file text, p_header text, p_rows text[]) RETURNS int LANGUAGE sql AS $$
  SELECT mdm_stage.stage_file(p_load, p_file, repeat('0', 64), '00000000-0000-0000-0000-000000003301',
                              string_to_array(p_header, ','),
                              coalesce((SELECT jsonb_agg(to_jsonb(string_to_array(r, ',')) ORDER BY o)
                                        FROM unnest(p_rows) WITH ORDINALITY AS x(r, o)), '[]'))
$$;
CREATE FUNCTION pg_temp.kinds(p_load uuid, p_severity text) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(DISTINCT kind, ',' ORDER BY kind) FROM mdm_stage.profile_finding WHERE load_id = p_load AND severity = p_severity
$$;

SET LOCAL ROLE nexus_api;

-- Files and headers ------------------------------------------------------------------------------------------
SELECT throws_ok($$SELECT pg_temp.stage('00000000-0000-0000-0000-0000000033a1', 'accounts.csv', 'a,b', '{}')$$,
  'N2812', NULL, 'A file that is not part of the data set is refused');
SELECT throws_ok($$SELECT pg_temp.stage('00000000-0000-0000-0000-0000000033a1', 'nodes.csv', 'node_code,node_name', '{}')$$,
  'N2813', NULL, 'A file whose header differs from the fixed format is refused');
SELECT throws_ok($$INSERT INTO mdm_stage.hx_node (batch_id, line_no) VALUES (gen_random_uuid(), 2)$$,
  '42501', NULL, 'The API cannot write the staging tables itself');

-- A clean load --------------------------------------------------------------------------------------------------
SELECT is(pg_temp.stage('00000000-0000-0000-0000-0000000033a1', 'Hierarchies.csv', ' hierarchy_code , hierarchy_name,top_node_code,description',
  ARRAY['SH_ORG,Staging org,SHTOP,Primary']), 1, 'The header is matched ignoring case and spaces; rows are staged');
SELECT is(pg_temp.stage('00000000-0000-0000-0000-0000000033a1', 'nodes.csv', 'node_code,node_name,description,node_type,status',
  ARRAY['SHTOP,Staging top,,LIMB,active', '10110, FP Group ,Cost center,LEAF,active', '10120,FP Regional,,LEAF,inactive']), 3,
  'Nodes are staged');
SELECT pg_temp.stage('00000000-0000-0000-0000-0000000033a1', 'relationships.csv', 'hierarchy_code,parent_code,child_code,sort_order',
  ARRAY['SH_ORG,,SHTOP,1', 'SH_ORG,SHTOP,10110,1', 'SH_ORG,SHTOP,10120,2']);
SELECT pg_temp.stage('00000000-0000-0000-0000-0000000033a1', 'reference_lists.csv', 'list_code,value,label',
  ARRAY['CURRENCY,USD,US Dollar', 'YES_NO,Y,Yes', 'YES_NO,N,No']);
SELECT pg_temp.stage('00000000-0000-0000-0000-0000000033a1', 'attribute_definitions.csv',
  'attribute_code,label,category,data_type,scope,hierarchies,node_filter,required,reference_list,inherited,default_value,derivation,max_length,description',
  ARRAY['CCY,Currency,Finance,STRING,GLOBAL,SH_ORG,LEAF,Y,CURRENCY,N,,,3,Currency',
        'HC,Headcount flag,HR,BOOLEAN,GLOBAL,SH_ORG,ANY,N,YES_NO,N,,,1,Flag',
        'FULL,Full name,System,STRING,GLOBAL,SH_ORG,ANY,N,,N,,node_code + name,70,Derived']);
SELECT pg_temp.stage('00000000-0000-0000-0000-0000000033a1', 'attribute_values.csv', 'node_code,hierarchy_code,attribute_code,value',
  ARRAY['10110,,CCY,USD', '10110,,HC,Y']);
SELECT is(mdm_stage.profile('00000000-0000-0000-0000-0000000033a1'), 0, 'A consistent load has no errors');
SELECT is(pg_temp.kinds('00000000-0000-0000-0000-0000000033a1', 'info'), 'skipped', '… and says what it will leave out (a derived attribute)');
SELECT is((SELECT btrim(node_name) FROM mdm_stage.hx_node n JOIN mdm_stage.intake_batch b USING (batch_id)
           WHERE b.load_id = '00000000-0000-0000-0000-0000000033a1' AND n.node_code = '10110'), 'FP Group',
  'Fields are trimmed as they are staged');

SELECT pg_temp.stage('00000000-0000-0000-0000-0000000033a1', 'nodes.csv', 'node_code,node_name,description,node_type,status',
  ARRAY['SHTOP,Staging top,,LIMB,active', '10110,FP Group,Cost center,LEAF,active']);
SELECT is((SELECT count(*)::int FROM mdm_stage.hx_node n JOIN mdm_stage.intake_batch b USING (batch_id)
           WHERE b.load_id = '00000000-0000-0000-0000-0000000033a1'), 2, 'Staging a file again replaces the earlier copy');

-- A load with problems ------------------------------------------------------------------------------------------
SELECT pg_temp.stage('00000000-0000-0000-0000-0000000033a2', 'hierarchies.csv', 'hierarchy_code,hierarchy_name,top_node_code,description',
  ARRAY['SH_BAD,Bad org,BTOP,']);
SELECT pg_temp.stage('00000000-0000-0000-0000-0000000033a2', 'nodes.csv', 'node_code,node_name,description,node_type,status',
  ARRAY['BTOP,Bad top,,LIMB,active', '20110,Leaf,,LEAF,active', '20110,Again,,LEAF,active', '20120,Odd,,TWIG,active', '20130,Short,LEAF']);
SELECT pg_temp.stage('00000000-0000-0000-0000-0000000033a2', 'relationships.csv', 'hierarchy_code,parent_code,child_code,sort_order',
  ARRAY['SH_BAD,,20110,1', 'SH_BAD,20110,20120,1', 'SH_BAD,BTOP,99999,1']);
SELECT pg_temp.stage('00000000-0000-0000-0000-0000000033a2', 'reference_lists.csv', 'list_code,value,label', ARRAY['CURRENCY,USD,US Dollar']);
SELECT pg_temp.stage('00000000-0000-0000-0000-0000000033a2', 'attribute_definitions.csv',
  'attribute_code,label,category,data_type,scope,hierarchies,node_filter,required,reference_list,inherited,default_value,derivation,max_length,description',
  ARRAY['CCY,Currency,Finance,STRING,GLOBAL,,LEAF,Y,CURRENCY,N,,,3,Currency']);
SELECT pg_temp.stage('00000000-0000-0000-0000-0000000033a2', 'attribute_values.csv', 'node_code,hierarchy_code,attribute_code,value',
  ARRAY['20110,SH_BAD,CCY,USD', 'BTOP,,CCY,XYZ']);
SELECT cmp_ok(mdm_stage.profile('00000000-0000-0000-0000-0000000033a2'), '>', 0, 'A load with problems has errors');
SELECT is(pg_temp.kinds('00000000-0000-0000-0000-0000000033a2', 'error'),
  'duplicate,list_value,parent_is_leaf,reference,row_width,scope,top_node,value',
  'Each problem is reported: duplicate code, value outside its list, leaf parent, unknown node, short row, scope, top node, bad node type');
SELECT is((SELECT line_no FROM mdm_stage.profile_finding WHERE load_id = '00000000-0000-0000-0000-0000000033a2' AND kind = 'row_width'), 6,
  'Findings carry the file''s line number (the header is line 1)');

SELECT pg_temp.stage('00000000-0000-0000-0000-0000000033a3', 'nodes.csv', 'node_code,node_name,description,node_type,status',
  ARRAY['X1,X,,LIMB,active']);
SELECT is((SELECT count(*)::int FROM (SELECT mdm_stage.profile('00000000-0000-0000-0000-0000000033a3')) p), 1, 'Profiling a partial load …');
SELECT is((SELECT string_agg(file_name, ',' ORDER BY file_name) FROM mdm_stage.profile_finding
           WHERE load_id = '00000000-0000-0000-0000-0000000033a3' AND kind = 'missing_file'),
  'hierarchies.csv,relationships.csv', '… reports the required files that are missing');

RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
