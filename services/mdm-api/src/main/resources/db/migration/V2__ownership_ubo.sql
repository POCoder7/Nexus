-- =============================================================================
-- AI-enabled MDM — 02: OWNERSHIP GRAPH & BENEFICIAL OWNERSHIP
-- This layer is new; DRM has no equivalent. Ownership edges are deliberately
-- kept separate from hierarchies: hierarchies are curated trees for reporting,
-- while ownership is a weighted many-to-many graph built from evidence.
-- =============================================================================
SET search_path = mdm, public;

CREATE TYPE ownership_relation AS ENUM (
  'shareholding', 'voting_rights', 'control_agreement', 'board_appointment_right', 'veto_right',
  'general_partner', 'limited_partner',
  'trustee', 'settlor', 'protector', 'beneficiary',
  'director', 'senior_managing_official'
);
CREATE TYPE evidence_source AS ENUM (
  'gleif', 'company_registry', 'client_document', 'vendor_feed', 'manual', 'ai_extraction'
);

-- -----------------------------------------------------------------------------
-- Evidence: every AI-extracted or manually entered fact points to a source
-- -----------------------------------------------------------------------------
CREATE TABLE evidence_document (
  evidence_document_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  doc_type             text NOT NULL,       -- shareholder_register, annual_return, trust_deed, org_chart...
  title                text,
  storage_uri          text NOT NULL,
  sha256               char(64) NOT NULL UNIQUE,   -- tamper evidence and deduplication
  source               evidence_source NOT NULL,
  issuer               text,
  document_date        date,
  captured_at          timestamptz NOT NULL DEFAULT now(),
  captured_by          uuid REFERENCES app_user
);

ALTER TABLE change_item
  ADD CONSTRAINT change_item_evidence_fk
  FOREIGN KEY (evidence_document_id) REFERENCES evidence_document;

-- -----------------------------------------------------------------------------
-- Ownership & control edges
-- -----------------------------------------------------------------------------
CREATE TABLE ownership_edge (
  edge_id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_node_id        uuid NOT NULL REFERENCES node,
  owned_node_id        uuid NOT NULL REFERENCES node,
  relation             ownership_relation NOT NULL,
  share_class          text,                -- informational; percentages are of the entity's TOTAL interest
  economic_pct         numeric(9,6) CHECK (economic_pct BETWEEN 0 AND 100),
  voting_pct           numeric(9,6) CHECK (voting_pct  BETWEEN 0 AND 100),
  is_direct            boolean NOT NULL DEFAULT true,  -- false = reported indirect holding; excluded from path math
  nominee_for_node_id  uuid REFERENCES node,           -- owner holds as nominee for this node
  control_basis        text,                -- free text for control relations (e.g. "SHA cl. 7.2 appoints 3 of 5")
  evidence_document_id uuid REFERENCES evidence_document,
  evidence_locator     jsonb,               -- {"page": 4, "bbox": [...], "quote": "..."} from AI extraction
  source               evidence_source NOT NULL,
  confidence           numeric(5,4) NOT NULL DEFAULT 1 CHECK (confidence BETWEEN 0 AND 1),
  valid_period         daterange NOT NULL DEFAULT daterange(current_date, NULL),
  recorded_period      tstzrange NOT NULL DEFAULT tstzrange(now(), NULL),
  change_request_id    uuid REFERENCES change_request,
  CHECK (owner_node_id <> owned_node_id),
  CHECK (relation <> 'shareholding' OR economic_pct IS NOT NULL),
  CHECK (source <> 'ai_extraction' OR evidence_document_id IS NOT NULL),   -- no evidence, no AI fact
  EXCLUDE USING gist (
    owner_node_id WITH =, owned_node_id WITH =, relation WITH =,
    (coalesce(share_class, '')) WITH =, valid_period WITH &&
  ) WHERE (upper_inf(recorded_period))
);
CREATE INDEX ON ownership_edge (owned_node_id) WHERE upper_inf(recorded_period);
CREATE INDEX ON ownership_edge (owner_node_id) WHERE upper_inf(recorded_period);

CREATE TRIGGER ownership_edge_guard BEFORE UPDATE OR DELETE ON ownership_edge
  FOR EACH ROW EXECUTE FUNCTION trg_bitemporal_guard();
CREATE TRIGGER ownership_edge_audit AFTER INSERT OR UPDATE OR DELETE ON ownership_edge
  FOR EACH ROW EXECUTE FUNCTION trg_audit_row();

-- -----------------------------------------------------------------------------
-- UBO thresholds by jurisdiction / regime (data, not code — they change)
-- -----------------------------------------------------------------------------
CREATE TABLE ubo_threshold (
  jurisdiction_code text NOT NULL REFERENCES jurisdiction,
  regime            text NOT NULL,          -- e.g. 'PMLA', 'FinCEN CDD', 'EU AMLD'
  entity_category   text NOT NULL DEFAULT 'company',   -- company, partnership, trust...
  threshold_pct     numeric(6,3) NOT NULL,
  valid_period      daterange NOT NULL,
  reference         text NOT NULL,          -- citation to the rule; must be confirmed by Compliance
  PRIMARY KEY (jurisdiction_code, regime, entity_category, valid_period)
);
-- No seed values on purpose: Compliance should load and sign off thresholds.

-- -----------------------------------------------------------------------------
-- Effective ownership: deterministic path math (never done by the LLM)
--   * multiplies percentages along each path and returns every path separately
--   * nominee holdings are looked through to the beneficial holder
--   * paths that loop back (cross-holdings) are returned flagged with is_cycle
--     and excluded from totals; exact cross-holding treatment, solving
--     (I - A)^-1 on the ownership matrix, belongs in the ownership service
-- -----------------------------------------------------------------------------
CREATE FUNCTION effective_ownership(
  p_target_node_id uuid,
  p_as_of          date        DEFAULT current_date,
  p_recorded_as_of timestamptz DEFAULT now(),
  p_max_depth      int         DEFAULT 25
)
RETURNS TABLE (ultimate_owner_id uuid, path uuid[], depth int, path_pct numeric, is_cycle boolean)
LANGUAGE sql STABLE SET search_path = mdm, public AS $$
WITH RECURSIVE
e AS (
  SELECT coalesce(oe.nominee_for_node_id, oe.owner_node_id) AS holder_id,
         oe.owned_node_id,
         sum(oe.economic_pct) AS pct            -- aggregate across share classes
  FROM ownership_edge oe
  WHERE oe.relation = 'shareholding'
    AND oe.is_direct
    AND oe.valid_period    @> p_as_of
    AND oe.recorded_period @> p_recorded_as_of
  GROUP BY 1, 2
),
w AS (
  SELECT e.holder_id, ARRAY[p_target_node_id, e.holder_id] AS path, 1 AS depth,
         e.pct / 100 AS frac, (e.holder_id = p_target_node_id) AS is_cycle
  FROM e
  WHERE e.owned_node_id = p_target_node_id
  UNION ALL
  SELECT e.holder_id, w.path || e.holder_id, w.depth + 1,
         w.frac * e.pct / 100, e.holder_id = ANY (w.path)
  FROM w
  JOIN e ON e.owned_node_id = w.holder_id
  WHERE NOT w.is_cycle AND w.depth < p_max_depth
)
SELECT w.holder_id, w.path, w.depth, round(w.frac * 100, 6), w.is_cycle
FROM w
$$;

-- Ownership prong: natural persons, total effective % across all paths, with paths as evidence.
CREATE FUNCTION ubo_ownership_prong(
  p_target_node_id uuid,
  p_threshold_pct  numeric,
  p_as_of          date        DEFAULT current_date,
  p_recorded_as_of timestamptz DEFAULT now()
)
RETURNS TABLE (person_node_id uuid, total_effective_pct numeric, path_count bigint,
               paths jsonb, meets_threshold boolean, has_cycle_paths boolean)
LANGUAGE sql STABLE SET search_path = mdm, public AS $$
SELECT eo.ultimate_owner_id,
       coalesce(sum(eo.path_pct) FILTER (WHERE NOT eo.is_cycle), 0),
       count(*) FILTER (WHERE NOT eo.is_cycle),
       jsonb_agg(jsonb_build_object('path', eo.path, 'pct', eo.path_pct, 'cycle', eo.is_cycle)
                 ORDER BY eo.path_pct DESC),
       coalesce(sum(eo.path_pct) FILTER (WHERE NOT eo.is_cycle), 0) >= p_threshold_pct,
       bool_or(eo.is_cycle)
FROM effective_ownership(p_target_node_id, p_as_of, p_recorded_as_of) eo
JOIN node n ON n.node_id = eo.ultimate_owner_id AND n.node_kind = 'natural_person'
GROUP BY eo.ultimate_owner_id
$$;

-- Control prong: people controlling the target other than through shareholding.
CREATE FUNCTION ubo_control_prong(
  p_target_node_id uuid,
  p_as_of          date        DEFAULT current_date,
  p_recorded_as_of timestamptz DEFAULT now()
)
RETURNS TABLE (person_node_id uuid, relation ownership_relation, voting_pct numeric,
               control_basis text, evidence_document_id uuid, confidence numeric)
LANGUAGE sql STABLE SET search_path = mdm, public AS $$
SELECT oe.owner_node_id, oe.relation, oe.voting_pct, oe.control_basis,
       oe.evidence_document_id, oe.confidence
FROM ownership_edge oe
JOIN node n ON n.node_id = oe.owner_node_id AND n.node_kind = 'natural_person'
WHERE oe.owned_node_id = p_target_node_id
  AND oe.relation IN ('voting_rights', 'control_agreement', 'board_appointment_right', 'veto_right',
                      'general_partner', 'trustee', 'settlor', 'protector', 'beneficiary',
                      'senior_managing_official')
  AND oe.valid_period    @> p_as_of
  AND oe.recorded_period @> p_recorded_as_of
$$;

-- -----------------------------------------------------------------------------
-- Starter validation rules (sql engine: $1 = as_of, $2 = recorded_as_of)
-- -----------------------------------------------------------------------------
INSERT INTO validation_rule (rule_code, description, level, severity, engine, expression) VALUES
('OWN_SUM_LE_100',
 'Direct economic ownership of an entity cannot exceed 100%',
 'ownership', 'error', 'sql',
 $q$SELECT oe.owned_node_id, NULL::uuid,
           format('Direct economic ownership totals %s%%', sum(oe.economic_pct))
    FROM mdm.ownership_edge oe
    WHERE oe.relation = 'shareholding' AND oe.is_direct
      AND oe.valid_period @> $1 AND oe.recorded_period @> $2
    GROUP BY oe.owned_node_id
    HAVING sum(oe.economic_pct) > 100$q$),

('OWN_AI_LOW_CONFIDENCE',
 'AI-extracted ownership edges below 0.90 confidence need steward review',
 'ownership', 'warning', 'sql',
 $q$SELECT oe.owned_node_id, NULL::uuid,
           format('AI-extracted edge %s has confidence %s', oe.edge_id, oe.confidence)
    FROM mdm.ownership_edge oe
    WHERE oe.source = 'ai_extraction' AND oe.confidence < 0.90
      AND oe.valid_period @> $1 AND oe.recorded_period @> $2$q$),

('LEI_FORMAT',
 'LEI identifiers must match the ISO 17442 format',
 'node', 'error', 'sql',
 $q$SELECT ni.node_id, NULL::uuid, format('Invalid LEI %s', ni.identifier_value)
    FROM mdm.node_identifier ni
    WHERE ni.scheme_code = 'LEI' AND ni.identifier_value !~ '^[A-Z0-9]{18}[0-9]{2}$'
      AND ni.valid_period @> $1 AND ni.recorded_period @> $2$q$),

('SHARED_NEEDS_PRIMARY',
 'A shared node instance requires a primary instance in the same hierarchy',
 'hierarchy', 'error', 'sql',
 $q$SELECT s.child_node_id, s.hierarchy_id, 'Shared node has no primary instance'
    FROM mdm.hierarchy_relationship s
    WHERE NOT s.is_primary AND s.valid_period @> $1 AND s.recorded_period @> $2
      AND NOT EXISTS (
        SELECT 1 FROM mdm.hierarchy_relationship p
        WHERE p.hierarchy_id = s.hierarchy_id AND p.child_node_id = s.child_node_id
          AND p.is_primary AND p.valid_period @> $1 AND p.recorded_period @> $2)$q$);
