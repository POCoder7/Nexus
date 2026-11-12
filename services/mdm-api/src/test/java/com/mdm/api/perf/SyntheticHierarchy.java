package com.mdm.api.perf;

import org.springframework.jdbc.core.simple.JdbcClient;

import java.util.UUID;

/**
 * Small synthetic data generator for the Phase 1 performance tests (LLD §10; the full generator is Phase 4).
 * Everything is generated in SQL with set-based inserts through the owner connection (test setup only), and every
 * name is an obvious placeholder ({@code PERF …}), so no realistic data is ever produced.
 *
 * <p>Shape of hierarchy {@code PERF_H} (about 100 600 nodes):
 * <ul>
 *   <li>top → "wide" parent with {@code siblings} leaf children (the children-page case);</li>
 *   <li>top → {@code regions} regions × {@code perRegion} leaves (bulk, so the hierarchy is realistically large);</li>
 *   <li>top → a chain {@code depth} deep (the node-detail case), with {@code properties} inherited properties whose
 *       values are stored on the top node only, so the deepest node resolves every one by inheritance.</li>
 * </ul>
 */
public final class SyntheticHierarchy {

    public static final String CODE = "PERF_H";

    public record Shape(int siblings, int regions, int perRegion, int depth, int properties) {
        public static Shape phase1() {
            return new Shape(50_000, 500, 100, 20, 200);
        }
    }

    public record Built(UUID hierarchyId, UUID top, UUID wideParent, UUID deepest, UUID firstRegion) {
    }

    private SyntheticHierarchy() {
    }

    public static Built build(JdbcClient owner, Shape s) {
        UUID existing = owner.sql("SELECT hierarchy_id FROM mdm.hierarchy WHERE hierarchy_code = :c").param("c", CODE)
                .query(UUID.class).optional().orElse(null);
        if (existing == null) {
            generate(owner, s);
        }
        return owner.sql("""
                SELECT h.hierarchy_id, h.top_node_id,
                       (SELECT node_id FROM mdm.node_attr WHERE node_name = 'PERF wide'),
                       (SELECT node_id FROM mdm.node_attr WHERE node_name = 'PERF chain ' || lpad(CAST(:depth AS text), 3, '0')),
                       (SELECT node_id FROM mdm.node_attr WHERE node_name = 'PERF region 0001')
                FROM mdm.hierarchy h WHERE h.hierarchy_code = :c
                """).param("c", CODE).param("depth", s.depth())
                .query((rs, i) -> new Built(rs.getObject(1, UUID.class), rs.getObject(2, UUID.class), rs.getObject(3, UUID.class),
                        rs.getObject(4, UUID.class), rs.getObject(5, UUID.class)))
                .single();
    }

    private static void generate(JdbcClient owner, Shape s) {
        // One DO block, because the owner connection autocommits each statement and the work table must live
        // across the inserts. The parameters are integers from the Shape record, inlined with %d.
        owner.sql("""
                DO $$
                DECLARE b int;
                BEGIN
                CREATE TEMP TABLE perf_nodes AS
                SELECT gen_random_uuid() AS node_id, name, kind::mdm.node_kind AS kind, kids, parent_name
                FROM (
                  SELECT 'PERF top' AS name, 'structural' AS kind, true AS kids, NULL::text AS parent_name
                  UNION ALL SELECT 'PERF wide', 'structural', true, 'PERF top'
                  UNION ALL SELECT 'PERF sibling ' || lpad(g::text, 6, '0'), 'legal_entity', false, 'PERF wide'
                            FROM generate_series(1, %d) g
                  UNION ALL SELECT 'PERF region ' || lpad(r::text, 4, '0'), 'structural', true, 'PERF top'
                            FROM generate_series(1, %d) r
                  UNION ALL SELECT 'PERF leaf ' || lpad(r::text, 4, '0') || '-' || lpad(l::text, 4, '0'), 'legal_entity', false,
                                   'PERF region ' || lpad(r::text, 4, '0')
                            FROM generate_series(1, %d) r, generate_series(1, %d) l
                  UNION ALL SELECT 'PERF chain ' || lpad(d::text, 3, '0'), 'structural', true,
                                   CASE WHEN d = 1 THEN 'PERF top' ELSE 'PERF chain ' || lpad((d - 1)::text, 3, '0') END
                            FROM generate_series(1, %d) d
                ) n;
                  INSERT INTO mdm.node (node_id, node_kind) SELECT node_id, kind FROM perf_nodes;
                  INSERT INTO mdm.node_attr (node_id, node_name, allows_children, valid_period)
                  SELECT node_id, name, kids, daterange('2020-01-01', NULL) FROM perf_nodes;
                  INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, top_node_id)
                  SELECT 'PERF_H', 'PERF synthetic', node_id FROM perf_nodes WHERE name = 'PERF top';
                  -- Placements go in batches with ANALYZE in between, all guards on: the cycle check plans its ancestor
                  -- walk from table statistics, and one 100 000-row statement into an empty table keeps the "empty"
                  -- plan for every row (measured: 29 s for 5 000 rows from empty, 1.2 s with current statistics).
                  CREATE TEMP TABLE perf_rel AS
                  SELECT h.hierarchy_id, p.node_id AS parent_id, c.node_id AS child_id,
                         row_number() OVER (PARTITION BY p.node_id ORDER BY c.name) * 1000 AS sort_order,
                         row_number() OVER (ORDER BY c.name) AS n
                  FROM perf_nodes c JOIN perf_nodes p ON p.name = c.parent_name, mdm.hierarchy h
                  WHERE h.hierarchy_code = 'PERF_H';
                  FOR b IN 0 .. (SELECT max(n) FROM perf_rel) / 5000 LOOP
                    INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, sort_order, valid_period)
                    SELECT hierarchy_id, parent_id, child_id, sort_order, daterange('2020-01-01', NULL)
                    FROM perf_rel WHERE n > b * 5000 AND n <= (b + 1) * 5000;
                    ANALYZE mdm.hierarchy_relationship;
                  END LOOP;
                  DROP TABLE perf_rel;
                  DROP TABLE perf_nodes;
                END $$
                """.formatted(s.siblings(), s.regions(), s.regions(), s.perRegion(), s.depth())).update();
        owner.sql("""
                INSERT INTO mdm.property_definition (property_code, label, data_type, scope, inheritance)
                SELECT 'PERF.P' || lpad(g::text, 3, '0'), 'PERF property ' || g, 'string', 'global', 'inherit_from_ancestor'
                FROM generate_series(1, :n) g
                """).param("n", s.properties()).update();
        owner.sql("""
                INSERT INTO mdm.property_value (node_id, property_id, value, valid_period)
                SELECT h.top_node_id, d.property_id, to_jsonb('PERF value ' || d.property_code), daterange('2020-01-01', NULL)
                FROM mdm.property_definition d, mdm.hierarchy h
                WHERE d.property_code LIKE 'PERF.P%' AND h.hierarchy_code = 'PERF_H'
                """).update();
        owner.sql("ANALYZE").update();
    }
}
