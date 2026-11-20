-- =============================================================================
-- V16 — Hackathon CSV load (ADR-046; Phase 4 LLD §17). Built in increments H-2 to H-6; H-1's columns were edits to
-- V1, V10, V12 and V13 (rule 6, OD-44).
-- =============================================================================
SET search_path = mdm, public;

-- -----------------------------------------------------------------------------
-- H-2 Property applicability (ADR-046 D2, LLD §17.3): the hierarchies a property applies to, and the kind of node.
-- No rows in property_hierarchy for a property = it applies to every hierarchy (C-1: a join table, so the hierarchies
-- are real foreign keys). Configuration, not facts: audited, not bitemporal, like property_definition.
-- -----------------------------------------------------------------------------
CREATE TABLE mdm.property_hierarchy (
  property_id  uuid NOT NULL REFERENCES mdm.property_definition,
  hierarchy_id uuid NOT NULL REFERENCES mdm.hierarchy,
  PRIMARY KEY (property_id, hierarchy_id)
);
CREATE INDEX ON mdm.property_hierarchy (hierarchy_id);
CREATE TRIGGER property_hierarchy_audit AFTER INSERT OR UPDATE OR DELETE ON mdm.property_hierarchy
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_audit_row();

ALTER TABLE mdm.property_definition
  ADD COLUMN node_filter text NOT NULL DEFAULT 'any' CHECK (node_filter IN ('any', 'leaf', 'limb'));
COMMENT ON COLUMN mdm.property_definition.node_filter IS
  'Which nodes may hold the property: any, leaf (allows_children false) or limb (allows_children true). ADR-046 D2.';

-- Does the property apply to the node on the date? p_hierarchy is the hierarchy in question: a local value's own
-- hierarchy, or the hierarchy a node is being viewed in; NULL = any hierarchy the node is placed in. Reads the current
-- belief (upper_inf recorded_period). One definition of "applies", used by the guard below and by the property grid.
CREATE FUNCTION mdm.property_applies(p_property uuid, p_node uuid, p_hierarchy uuid, p_on date)
RETURNS boolean LANGUAGE sql STABLE SET search_path = mdm, public AS $$
  SELECT
    -- the node kind: a node with no attributes on the date is left to the other guards
    (d.node_filter = 'any'
     OR NOT EXISTS (SELECT 1 FROM mdm.node_attr a WHERE a.node_id = p_node AND a.valid_period @> p_on
                    AND upper_inf(a.recorded_period))
     OR EXISTS (SELECT 1 FROM mdm.node_attr a WHERE a.node_id = p_node AND a.valid_period @> p_on
                AND upper_inf(a.recorded_period) AND a.allows_children = (d.node_filter = 'limb')))
    AND
    -- the hierarchies: none listed, or the hierarchy in question is listed, or (no hierarchy in question) the node is
    -- the top of, or placed in, a listed hierarchy on the date
    (NOT EXISTS (SELECT 1 FROM mdm.property_hierarchy ph WHERE ph.property_id = d.property_id)
     OR (p_hierarchy IS NOT NULL
         AND EXISTS (SELECT 1 FROM mdm.property_hierarchy ph WHERE ph.property_id = d.property_id AND ph.hierarchy_id = p_hierarchy))
     OR (p_hierarchy IS NULL
         AND EXISTS (SELECT 1 FROM mdm.property_hierarchy ph JOIN mdm.hierarchy h ON h.hierarchy_id = ph.hierarchy_id
                     WHERE ph.property_id = d.property_id
                       AND (h.top_node_id = p_node
                            OR EXISTS (SELECT 1 FROM mdm.hierarchy_relationship r
                                       WHERE r.hierarchy_id = h.hierarchy_id AND r.child_node_id = p_node
                                         AND r.valid_period @> p_on AND upper_inf(r.recorded_period))))))
  FROM mdm.property_definition d
  WHERE d.property_id = p_property
$$;

-- Guard (C-2): a value may not be stored where its property does not apply (N2025), checked on the value's first day.
-- Rows that apply_fact re-states (history before D, or after a validTo) existed already and are not checked again, so
-- tightening a definition never blocks later changes to other periods: a re-stated row is recognised as one that a row
-- closed at the same instant held, with the same value, over a period covering it (apply_fact closes and re-inserts with
-- one recorded instant). Existing values are untouched; a node that later stops qualifying (a move, a leaf becoming a
-- limb) is reported by validation, not refused here.
CREATE FUNCTION mdm.trg_property_value_applies() RETURNS trigger
LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE
  v_d date := CASE WHEN lower_inf(NEW.valid_period) THEN current_date ELSE lower(NEW.valid_period) END;
  v_code text;
BEGIN
  IF NOT upper_inf(NEW.recorded_period) OR jsonb_typeof(NEW.value) = 'null' THEN
    RETURN NEW;                                                 -- history, or an explicit blank (always allowed)
  END IF;
  IF EXISTS (SELECT 1 FROM mdm.property_value p
             WHERE p.node_id = NEW.node_id AND p.property_id = NEW.property_id
               AND p.hierarchy_id IS NOT DISTINCT FROM NEW.hierarchy_id
               AND upper(p.recorded_period) = lower(NEW.recorded_period)
               AND p.value = NEW.value AND p.valid_period @> NEW.valid_period) THEN
    RETURN NEW;                                                 -- a re-stated period of a value that existed
  END IF;
  IF NOT mdm.property_applies(NEW.property_id, NEW.node_id, NEW.hierarchy_id, v_d) THEN
    SELECT property_code INTO v_code FROM mdm.property_definition WHERE property_id = NEW.property_id;
    RAISE EXCEPTION 'Property % does not apply to node % on % (its hierarchies or node kind)', v_code, NEW.node_id, v_d
      USING ERRCODE = 'N2025', HINT = 'property.not_applicable';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER property_value_applies BEFORE INSERT ON mdm.property_value
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_property_value_applies();

-- -----------------------------------------------------------------------------
-- H-3 Ledgers (ADR-046 D4, LLD §17.4): reference data for finance attributes (LEDGER_ID) and rule VR17 (the ledger's
-- currency). Configuration like property_definition: not bitemporal, audited, readable by every role. Written by the
-- API for an ADMIN (PUT /admin/ledgers/{id}) and, from H-6, by the loader under an approved load run. Never deleted:
-- a ledger in use is retired with is_active = false, so values that name it keep their meaning.
-- -----------------------------------------------------------------------------
CREATE TABLE mdm.ledger (
  ledger_id       text PRIMARY KEY CHECK (ledger_id ~ '^\S{1,20}$'),
  ledger_name     text NOT NULL CHECK (length(btrim(ledger_name)) > 0),
  currency_code   char(3) NOT NULL CHECK (currency_code ~ '^[A-Z]{3}$'),
  finance_country text NOT NULL CHECK (length(btrim(finance_country)) > 0),
  is_active       boolean NOT NULL DEFAULT true
);
CREATE TRIGGER ledger_audit AFTER INSERT OR UPDATE OR DELETE ON mdm.ledger
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_audit_row();
GRANT INSERT, UPDATE ON mdm.ledger TO nexus_api;               -- no DELETE: retire instead
