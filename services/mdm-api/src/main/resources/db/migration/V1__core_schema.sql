-- =============================================================================
-- AI-enabled MDM (Oracle DRM replacement) — 01: CORE SCHEMA
-- Target: PostgreSQL 15+
--
-- Bitemporal convention used by every fact table:
--   valid_period    daterange : when the fact is true in the business world
--   recorded_period tstzrange : when the system held that belief
--   The current belief is the row where upper_inf(recorded_period).
--   Rows are never deleted or edited in place. To correct one, close its
--   recorded_period and insert a replacement (enforced by trg_bitemporal_guard).
--   DRM versions become named (business date, recorded timestamp) slices.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS mdm;
SET search_path = mdm, public;

-- -----------------------------------------------------------------------------
-- Enumerations
-- -----------------------------------------------------------------------------
CREATE TYPE node_kind AS ENUM (
  'legal_entity', 'natural_person', 'trust', 'fund', 'partnership',
  'government_body', 'structural'          -- structural = grouping node (DRM limb with no real-world entity)
);
CREATE TYPE version_status     AS ENUM ('working', 'submitted', 'finalized', 'expired');
CREATE TYPE property_data_type AS ENUM ('string', 'memo', 'integer', 'decimal', 'boolean',
                                        'date', 'datetime', 'list', 'node_ref', 'multi_node_ref');
CREATE TYPE property_scope     AS ENUM ('global', 'local');           -- local = hierarchy-specific (DRM local property)
CREATE TYPE property_origin    AS ENUM ('stored', 'derived', 'system');
CREATE TYPE inheritance_mode   AS ENUM ('none', 'inherit_from_ancestor');
CREATE TYPE requester_kind     AS ENUM ('human', 'ai_agent', 'system_feed');
CREATE TYPE cr_status          AS ENUM ('draft', 'submitted', 'in_review', 'approved',
                                        'rejected', 'applied', 'withdrawn',
                                        'apply_failed');  -- approved but could not be applied (stale base, rule); terminal
CREATE TYPE risk_tier          AS ENUM ('low', 'medium', 'high', 'critical');
CREATE TYPE decision_basis     AS ENUM ('human_review', 'approved_policy');
CREATE TYPE change_action      AS ENUM (
  'add_node', 'update_node', 'inactivate_node',
  'insert_node', 'move_node', 'remove_node', 'reorder_node',
  'set_property', 'clear_property', 'add_identifier',
  'add_ownership_edge', 'update_ownership_edge', 'end_ownership_edge',
  'delete_node',      -- end a node in the version: all relationships and its attributes (HIE-02)
  'add_hierarchy'     -- create a hierarchy and its top node (HIE-01, ADR-026)
);
CREATE TYPE validation_level   AS ENUM ('node', 'hierarchy', 'version', 'ownership');
CREATE TYPE validation_severity AS ENUM ('error', 'warning', 'info');

-- -----------------------------------------------------------------------------
-- Reference data and actors
-- -----------------------------------------------------------------------------
CREATE TABLE jurisdiction (
  jurisdiction_code text PRIMARY KEY,           -- ISO 3166-1 alpha-2, or subdivision e.g. 'US-DE'
  name              text NOT NULL,
  is_high_risk      boolean NOT NULL DEFAULT false
);

CREATE TABLE app_user (
  user_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  login        text NOT NULL UNIQUE,
  display_name text NOT NULL,
  kind         requester_kind NOT NULL DEFAULT 'human',   -- AI agents are first-class, identifiable actors
  is_active    boolean NOT NULL DEFAULT true
);

-- -----------------------------------------------------------------------------
-- Versions  (DRM Version)
-- -----------------------------------------------------------------------------
CREATE TABLE version (
  version_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_name    text NOT NULL UNIQUE,         -- keep DRM version names during the parallel run
  status          version_status NOT NULL DEFAULT 'working',
  base_version_id uuid REFERENCES version,
  business_as_of  date NOT NULL,                -- valid-time slice this version represents
  recorded_as_of  timestamptz,                  -- frozen system-time slice; NULL while working (= now)
  description     text,
  finalized_at    timestamptz,
  finalized_by    uuid REFERENCES app_user,
  CHECK (status <> 'finalized' OR recorded_as_of IS NOT NULL)
);

-- -----------------------------------------------------------------------------
-- Governance  (DRG requests -> change requests, maker-checker)
-- -----------------------------------------------------------------------------
CREATE TABLE change_request (
  change_request_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id        uuid NOT NULL REFERENCES version,
  title             text NOT NULL,
  rationale         text,                       -- AI agents must explain in plain language
  status            cr_status NOT NULL DEFAULT 'draft',
  requester_id      uuid NOT NULL REFERENCES app_user,
  requester_kind    requester_kind NOT NULL,
  risk_tier         risk_tier NOT NULL DEFAULT 'medium',
  ai_model          text,
  ai_confidence     numeric(5,4) CHECK (ai_confidence BETWEEN 0 AND 1),
  created_at        timestamptz NOT NULL DEFAULT now(),
  submitted_at      timestamptz,
  decided_at        timestamptz,
  decided_by        uuid REFERENCES app_user,
  decision_note     text,
  decision_basis    decision_basis,           -- how the decision was authorised
  decision_policy_ref uuid,                   -- approved commit policy; opaque here, validated by the workflow layer
  applied_at        timestamptz,
  -- Business date the request takes effect (ADR-018). The API always sets it from the business calendar;
  -- the default only serves direct SQL such as database tests.
  effective_from    date NOT NULL DEFAULT current_date,
  row_version       int  NOT NULL DEFAULT 1,             -- ETag for optimistic concurrency (ADR-015); bumped by trigger
  governed_by_workflow boolean NOT NULL DEFAULT false,   -- set only by wf_bridge when a workflow instance starts (ADR-019)
  apply_error       text,                                -- why apply failed, when status = 'apply_failed'
  -- Where the request came from; fixes its item limit at apply (CR-04). Never changes.
  origin            text NOT NULL DEFAULT 'user' CHECK (origin IN ('user', 'sandbox', 'load', 'ai')),
  CHECK (requester_kind <> 'ai_agent' OR (ai_model IS NOT NULL AND ai_confidence IS NOT NULL)),
  CHECK (decision_basis IS DISTINCT FROM 'approved_policy' OR decision_policy_ref IS NOT NULL),
  CHECK (decision_policy_ref IS NULL OR decision_basis = 'approved_policy')
);

-- Maker-checker: no self-approval. Decisions are made by a human reviewer, or, for
-- low-risk requests only, by the system actor under a pre-approved commit policy
-- (straight-through commit). AI-originated requests always need a human.
CREATE FUNCTION trg_cr_maker_checker() RETURNS trigger
LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE v_kind requester_kind;
BEGIN
  IF NEW.status IN ('approved', 'rejected') THEN
    IF NEW.decided_by IS NULL THEN
      RAISE EXCEPTION 'Change request % needs a decided_by reviewer', NEW.change_request_id USING ERRCODE = 'N1006', HINT = 'maker_checker.decider_required';
    END IF;
    IF NEW.decided_by = NEW.requester_id THEN
      RAISE EXCEPTION 'Maker-checker violation: requester cannot decide their own change request' USING ERRCODE = 'N1001', HINT = 'maker_checker.self_decision';
    END IF;
    SELECT kind INTO v_kind FROM app_user WHERE user_id = NEW.decided_by;

    IF NEW.decision_basis = 'approved_policy' THEN
      IF NEW.status <> 'approved' THEN
        RAISE EXCEPTION 'Only approvals can be policy-based; rejections need a human' USING ERRCODE = 'N1007', HINT = 'policy.approvals_only';
      END IF;
      IF v_kind <> 'system_feed' THEN
        RAISE EXCEPTION 'Policy-based approvals must be recorded by the system actor' USING ERRCODE = 'N1004', HINT = 'policy.system_actor_required';
      END IF;
      IF NEW.requester_kind = 'ai_agent' THEN
        RAISE EXCEPTION 'AI-originated requests always need human approval' USING ERRCODE = 'N1003', HINT = 'ai_requires_human';
      END IF;
      IF NEW.risk_tier <> 'low' THEN
        RAISE EXCEPTION 'Only low-risk requests may be approved by policy (this one is %)', NEW.risk_tier USING ERRCODE = 'N1008', HINT = 'policy.low_risk_only';
      END IF;
    ELSIF v_kind <> 'human' THEN
      RAISE EXCEPTION 'Only human reviewers may approve or reject change requests' USING ERRCODE = 'N1002', HINT = 'human_only';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER cr_maker_checker BEFORE INSERT OR UPDATE ON change_request
  FOR EACH ROW EXECUTE FUNCTION trg_cr_maker_checker();

-- The requester kind must be the truth about the requester (D-05): the AI rules in trg_cr_maker_checker and in
-- the commit-policy evaluation rely on it, so it cannot be self-declared.
CREATE FUNCTION trg_cr_requester_kind() RETURNS trigger
LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE v_kind requester_kind;
BEGIN
  SELECT kind INTO v_kind FROM app_user WHERE user_id = NEW.requester_id;
  IF v_kind IS DISTINCT FROM NEW.requester_kind THEN
    RAISE EXCEPTION 'requester_kind % does not match the requester''s user record (%)', NEW.requester_kind, v_kind
      USING ERRCODE = 'N1005', HINT = 'requester_kind_mismatch';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER cr_requester_kind BEFORE INSERT OR UPDATE OF requester_id, requester_kind ON change_request
  FOR EACH ROW EXECUTE FUNCTION trg_cr_requester_kind();

-- Allowed status transitions (D-07). Anything else is a programming or tampering error.
-- Trigger names sort after cr_maker_checker, so a maker-checker violation is reported first.
CREATE FUNCTION trg_cr_status_transition() RETURNS trigger
LANGUAGE plpgsql SET search_path = mdm, public AS $$
BEGIN
  IF NOT (
       (OLD.status = 'draft'                    AND NEW.status = 'submitted')
    OR (OLD.status IN ('draft', 'submitted')    AND NEW.status = 'in_review')     -- workflow start (bridge)
    OR (OLD.status IN ('submitted', 'in_review') AND NEW.status IN ('approved', 'rejected'))
    OR (OLD.status = 'approved'                 AND NEW.status IN ('applied', 'apply_failed'))
    OR (OLD.status IN ('draft', 'submitted', 'in_review') AND NEW.status = 'withdrawn')
  ) THEN
    RAISE EXCEPTION 'Change request % cannot move from % to %', NEW.change_request_id, OLD.status, NEW.status
      USING ERRCODE = 'N2101', HINT = 'change_request.status_transition';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER cr_status_transition BEFORE UPDATE OF status ON change_request
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION trg_cr_status_transition();

-- What was submitted is what gets decided and applied (D-07): content is frozen once the request leaves draft.
-- Status, decision, apply and version columns keep changing through the lifecycle.
CREATE FUNCTION trg_cr_frozen_content() RETURNS trigger
LANGUAGE plpgsql SET search_path = mdm, public AS $$
BEGIN
  IF OLD.status <> 'draft'
     AND (NEW.title, NEW.rationale, NEW.risk_tier, NEW.effective_from, NEW.version_id, NEW.requester_id,
          NEW.requester_kind, NEW.ai_model, NEW.ai_confidence, NEW.origin, NEW.created_at)
         IS DISTINCT FROM
         (OLD.title, OLD.rationale, OLD.risk_tier, OLD.effective_from, OLD.version_id, OLD.requester_id,
          OLD.requester_kind, OLD.ai_model, OLD.ai_confidence, OLD.origin, OLD.created_at) THEN
    RAISE EXCEPTION 'Change request % is % and its content can no longer change', OLD.change_request_id, OLD.status
      USING ERRCODE = 'N2102', HINT = 'change_request.not_draft';
  END IF;
  IF NEW.origin IS DISTINCT FROM OLD.origin THEN
    RAISE EXCEPTION 'The origin of a change request never changes'
      USING ERRCODE = 'N2102', HINT = 'change_request.origin_fixed';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER cr_frozen_content BEFORE UPDATE ON change_request
  FOR EACH ROW EXECUTE FUNCTION trg_cr_frozen_content();

-- Only drafts can be deleted: deleting a submitted or decided request would also delete its items (cascade)
-- and erase what was approved. Withdraw instead.
CREATE FUNCTION trg_cr_delete_draft_only() RETURNS trigger
LANGUAGE plpgsql SET search_path = mdm, public AS $$
BEGIN
  IF OLD.status <> 'draft' THEN
    RAISE EXCEPTION 'Change request % is % and cannot be deleted; withdraw it instead', OLD.change_request_id, OLD.status
      USING ERRCODE = 'N2102', HINT = 'change_request.not_draft';
  END IF;
  RETURN OLD;
END $$;
CREATE TRIGGER cr_delete_draft_only BEFORE DELETE ON change_request
  FOR EACH ROW EXECUTE FUNCTION trg_cr_delete_draft_only();

-- ETag source (ADR-015): every update of the request, including item changes (below), bumps the version.
CREATE FUNCTION trg_cr_row_version() RETURNS trigger
LANGUAGE plpgsql SET search_path = mdm, public AS $$
BEGIN
  NEW.row_version := OLD.row_version + 1;
  RETURN NEW;
END $$;
CREATE TRIGGER cr_row_version BEFORE UPDATE ON change_request
  FOR EACH ROW EXECUTE FUNCTION trg_cr_row_version();

-- -----------------------------------------------------------------------------
-- Nodes  (DRM Node; Core.Name / Core.Description / inactive flag)
-- -----------------------------------------------------------------------------
CREATE TABLE node (
  node_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),   -- immutable identity; names can change
  node_kind  node_kind NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES app_user
);

CREATE TABLE node_attr (
  node_id           uuid NOT NULL REFERENCES node,
  node_name         text NOT NULL,             -- DRM node name, the business key in exports
  description       text,
  is_active         boolean NOT NULL DEFAULT true,
  allows_children   boolean NOT NULL DEFAULT true,   -- DRM leaf/limb designation
  valid_period      daterange NOT NULL DEFAULT daterange(current_date, NULL),
  recorded_period   tstzrange NOT NULL DEFAULT tstzrange(now(), NULL),
  change_request_id uuid REFERENCES change_request,
  EXCLUDE USING gist (node_id WITH =, valid_period WITH &&)   WHERE (upper_inf(recorded_period)),
  EXCLUDE USING gist (node_name WITH =, valid_period WITH &&) WHERE (upper_inf(recorded_period))
);

CREATE TABLE identifier_scheme (
  scheme_code   text PRIMARY KEY,
  name          text NOT NULL,
  issuer        text,
  value_pattern text                            -- regex, enforced through validation rules
);

CREATE TABLE node_identifier (
  node_id           uuid NOT NULL REFERENCES node,
  scheme_code       text NOT NULL REFERENCES identifier_scheme,
  identifier_value  text NOT NULL,
  jurisdiction_code text REFERENCES jurisdiction,
  source            text NOT NULL,
  valid_period      daterange NOT NULL DEFAULT daterange(current_date, NULL),
  recorded_period   tstzrange NOT NULL DEFAULT tstzrange(now(), NULL),
  change_request_id uuid REFERENCES change_request,
  EXCLUDE USING gist (scheme_code WITH =, identifier_value WITH =, valid_period WITH &&)
    WHERE (upper_inf(recorded_period))
);
CREATE INDEX ON node_identifier (node_id);

-- Typed facts the UBO logic depends on (exemptions, jurisdiction risk).
CREATE TABLE legal_entity_profile (
  node_id            uuid NOT NULL REFERENCES node,
  jurisdiction_code  text REFERENCES jurisdiction,
  legal_form         text,
  entity_status      text CHECK (entity_status IN ('active', 'inactive', 'dissolved', 'merged', 'in_liquidation')),
  incorporation_date date,
  is_listed          boolean NOT NULL DEFAULT false,   -- listed entities are often UBO-exempt
  registered_address jsonb,
  valid_period       daterange NOT NULL DEFAULT daterange(current_date, NULL),
  recorded_period    tstzrange NOT NULL DEFAULT tstzrange(now(), NULL),
  change_request_id  uuid REFERENCES change_request,
  EXCLUDE USING gist (node_id WITH =, valid_period WITH &&) WHERE (upper_inf(recorded_period))
);

-- -----------------------------------------------------------------------------
-- Hierarchies  (DRM Hierarchy, Top Node, Hierarchy Group, Shared Nodes)
-- -----------------------------------------------------------------------------
CREATE TABLE hierarchy (
  hierarchy_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hierarchy_code     text NOT NULL UNIQUE,      -- keep DRM hierarchy names during the parallel run
  hierarchy_name     text NOT NULL,
  purpose            text CHECK (purpose IN ('legal_consolidation', 'management', 'regulatory', 'tax', 'other')),
  hierarchy_group    text,
  top_node_id        uuid NOT NULL REFERENCES node,
  allow_shared_nodes boolean NOT NULL DEFAULT false,
  sort_seq           int,
  is_active          boolean NOT NULL DEFAULT true
);

CREATE TABLE hierarchy_relationship (
  relationship_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hierarchy_id      uuid NOT NULL REFERENCES hierarchy,
  parent_node_id    uuid NOT NULL REFERENCES node,
  child_node_id     uuid NOT NULL REFERENCES node,
  is_primary        boolean NOT NULL DEFAULT true,   -- false = DRM shared-node instance
  sort_order        numeric NOT NULL DEFAULT 1000,   -- fractional, so reordering touches one row
  valid_period      daterange NOT NULL DEFAULT daterange(current_date, NULL),
  recorded_period   tstzrange NOT NULL DEFAULT tstzrange(now(), NULL),
  change_request_id uuid REFERENCES change_request,
  CHECK (parent_node_id <> child_node_id),
  -- a node has at most one primary parent per hierarchy at any point in time
  EXCLUDE USING gist (hierarchy_id WITH =, child_node_id WITH =, valid_period WITH &&)
    WHERE (is_primary AND upper_inf(recorded_period)),
  -- no duplicate parent/child pair at the same time
  EXCLUDE USING gist (hierarchy_id WITH =, parent_node_id WITH =, child_node_id WITH =, valid_period WITH &&)
    WHERE (upper_inf(recorded_period))
);
-- Children pages are keyset-paged by (sort_order, name, child id) (ADR-015); the index serves the parent lookup
-- in sort order (the name comes from node_attr, so it cannot be in this index).
CREATE INDEX ON hierarchy_relationship (hierarchy_id, parent_node_id, sort_order, child_node_id) WHERE upper_inf(recorded_period);
CREATE INDEX ON hierarchy_relationship (hierarchy_id, child_node_id)  WHERE upper_inf(recorded_period);

-- Rejects cycles, top-node re-parenting, and shared nodes where the hierarchy disallows them.
CREATE FUNCTION trg_hierarchy_integrity() RETURNS trigger
LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE
  v_top    uuid;
  v_shared boolean;
  v_cycle  boolean;
BEGIN
  IF NOT upper_inf(NEW.recorded_period) THEN
    RETURN NEW;                                  -- closing history rows is always allowed
  END IF;

  SELECT top_node_id, allow_shared_nodes INTO v_top, v_shared
  FROM hierarchy WHERE hierarchy_id = NEW.hierarchy_id;

  IF NEW.child_node_id = v_top THEN
    RAISE EXCEPTION 'The top node of a hierarchy cannot be given a parent' USING ERRCODE = 'N2002', HINT = 'hierarchy.top_node';
  END IF;
  IF NOT NEW.is_primary AND NOT v_shared THEN
    RAISE EXCEPTION 'Hierarchy % does not allow shared nodes', NEW.hierarchy_id USING ERRCODE = 'N2003', HINT = 'hierarchy.shared_not_allowed';
  END IF;

  WITH RECURSIVE anc(node_id) AS (
    SELECT NEW.parent_node_id
    UNION
    SELECT r.parent_node_id
    FROM hierarchy_relationship r
    JOIN anc ON r.child_node_id = anc.node_id
    WHERE r.hierarchy_id = NEW.hierarchy_id
      AND upper_inf(r.recorded_period)
      AND r.valid_period && NEW.valid_period
      AND r.relationship_id <> NEW.relationship_id
  )
  SELECT EXISTS (SELECT 1 FROM anc WHERE node_id = NEW.child_node_id) INTO v_cycle;

  IF v_cycle THEN
    RAISE EXCEPTION 'Cycle detected: node % is already an ancestor of % in hierarchy %',
      NEW.child_node_id, NEW.parent_node_id, NEW.hierarchy_id USING ERRCODE = 'N2001', HINT = 'hierarchy.cycle';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER hierarchy_integrity BEFORE INSERT OR UPDATE ON hierarchy_relationship
  FOR EACH ROW EXECUTE FUNCTION trg_hierarchy_integrity();

-- -----------------------------------------------------------------------------
-- Properties  (DRM Property Definitions, Categories, List values, Inheritance)
-- -----------------------------------------------------------------------------
CREATE TABLE property_category (
  category_code text PRIMARY KEY,
  name          text NOT NULL,
  sort_seq      int
);

CREATE TABLE property_definition (
  property_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_code     text NOT NULL UNIQUE,       -- e.g. 'Custom.Currency'; keep DRM names for 1:1 export
  label             text NOT NULL,
  category_code     text REFERENCES property_category,
  data_type         property_data_type NOT NULL,
  scope             property_scope NOT NULL,
  origin            property_origin NOT NULL DEFAULT 'stored',
  inheritance       inheritance_mode NOT NULL DEFAULT 'none',
  default_value     jsonb,
  derivation_engine text CHECK (derivation_engine IN ('sql', 'cel', 'python')),
  derivation_expr   text,                       -- DRM derived-property formula, rewritten as code
  drm_formula_orig  text,                       -- original DRM formula, kept for traceability
  max_length        int,
  is_required       boolean NOT NULL DEFAULT false,
  is_pii            boolean NOT NULL DEFAULT false,
  description       text,
  CHECK ((origin = 'derived') = (derivation_expr IS NOT NULL)),
  CHECK (derivation_expr IS NULL OR derivation_engine IS NOT NULL)
);

CREATE TABLE property_list_value (
  property_id uuid NOT NULL REFERENCES property_definition,
  list_value  text NOT NULL,
  label       text,
  sort_seq    int,
  is_active   boolean NOT NULL DEFAULT true,
  PRIMARY KEY (property_id, list_value)
);

CREATE TABLE property_value (
  property_value_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  node_id           uuid NOT NULL REFERENCES node,
  property_id       uuid NOT NULL REFERENCES property_definition,
  hierarchy_id      uuid REFERENCES hierarchy,  -- NULL for global, required for local
  value             jsonb NOT NULL,             -- JSON null = explicit blank override (blocks inheritance)
  source            text NOT NULL DEFAULT 'manual',
  valid_period      daterange NOT NULL DEFAULT daterange(current_date, NULL),
  recorded_period   tstzrange NOT NULL DEFAULT tstzrange(now(), NULL),
  change_request_id uuid REFERENCES change_request,
  EXCLUDE USING gist (
    node_id WITH =, property_id WITH =,
    (coalesce(hierarchy_id, '00000000-0000-0000-0000-000000000000'::uuid)) WITH =,
    valid_period WITH &&
  ) WHERE (upper_inf(recorded_period))
);
CREATE INDEX ON property_value (property_id, hierarchy_id) WHERE upper_inf(recorded_period);

-- Enforces scope and data-type rules that DRM enforced in its engine.
CREATE FUNCTION trg_property_value_check() RETURNS trigger
LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE
  d property_definition%ROWTYPE;
  t text := jsonb_typeof(NEW.value);
BEGIN
  SELECT * INTO d FROM property_definition WHERE property_id = NEW.property_id;

  IF d.origin = 'derived' THEN
    RAISE EXCEPTION 'Property % is derived and cannot be stored', d.property_code USING ERRCODE = 'N2021', HINT = 'property.derived';
  END IF;
  IF d.scope = 'global' AND NEW.hierarchy_id IS NOT NULL THEN
    RAISE EXCEPTION 'Property % is global; hierarchy_id must be NULL', d.property_code USING ERRCODE = 'N2020', HINT = 'property.scope';
  END IF;
  IF d.scope = 'local' AND NEW.hierarchy_id IS NULL THEN
    RAISE EXCEPTION 'Property % is local; hierarchy_id is required', d.property_code USING ERRCODE = 'N2020', HINT = 'property.scope';
  END IF;
  IF t = 'null' THEN
    RETURN NEW;
  END IF;

  CASE d.data_type
    WHEN 'string', 'memo' THEN
      IF t <> 'string' THEN RAISE EXCEPTION '% expects a string', d.property_code USING ERRCODE = 'N2022', HINT = 'property.type'; END IF;
      IF d.max_length IS NOT NULL AND length(NEW.value #>> '{}') > d.max_length THEN
        RAISE EXCEPTION '% exceeds max length %', d.property_code, d.max_length USING ERRCODE = 'N2022', HINT = 'property.type';
      END IF;
    WHEN 'integer' THEN
      IF t <> 'number' OR (NEW.value::text)::numeric <> trunc((NEW.value::text)::numeric) THEN
        RAISE EXCEPTION '% expects an integer', d.property_code USING ERRCODE = 'N2022', HINT = 'property.type';
      END IF;
    WHEN 'decimal' THEN
      IF t <> 'number' THEN RAISE EXCEPTION '% expects a number', d.property_code USING ERRCODE = 'N2022', HINT = 'property.type'; END IF;
    WHEN 'boolean' THEN
      IF t <> 'boolean' THEN RAISE EXCEPTION '% expects a boolean', d.property_code USING ERRCODE = 'N2022', HINT = 'property.type'; END IF;
    WHEN 'date' THEN
      PERFORM (NEW.value #>> '{}')::date;          -- raises on invalid input
    WHEN 'datetime' THEN
      PERFORM (NEW.value #>> '{}')::timestamptz;
    WHEN 'list' THEN
      IF NOT EXISTS (SELECT 1 FROM property_list_value
                     WHERE property_id = d.property_id
                       AND list_value = NEW.value #>> '{}' AND is_active) THEN
        RAISE EXCEPTION '% value "%" is not in its list', d.property_code, NEW.value #>> '{}' USING ERRCODE = 'N2023', HINT = 'property.list_value';
      END IF;
    WHEN 'node_ref' THEN
      IF NOT EXISTS (SELECT 1 FROM node WHERE node_id = (NEW.value #>> '{}')::uuid) THEN
        RAISE EXCEPTION '% references an unknown node', d.property_code USING ERRCODE = 'N2024', HINT = 'property.node_ref';
      END IF;
    WHEN 'multi_node_ref' THEN
      IF t <> 'array' OR EXISTS (
           SELECT 1 FROM jsonb_array_elements_text(NEW.value) x
           WHERE NOT EXISTS (SELECT 1 FROM node WHERE node_id = x::uuid)) THEN
        RAISE EXCEPTION '% expects an array of existing node ids', d.property_code USING ERRCODE = 'N2024', HINT = 'property.node_ref';
      END IF;
  END CASE;
  RETURN NEW;
END $$;

CREATE TRIGGER property_value_check BEFORE INSERT OR UPDATE ON property_value
  FOR EACH ROW EXECUTE FUNCTION trg_property_value_check();

-- -----------------------------------------------------------------------------
-- Change items (the individual actions inside a change request)
-- -----------------------------------------------------------------------------
CREATE TABLE change_item (
  change_item_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  change_request_id    uuid NOT NULL REFERENCES change_request ON DELETE CASCADE,
  seq                  int NOT NULL,
  action               change_action NOT NULL,
  hierarchy_id         uuid REFERENCES hierarchy,
  node_id              uuid REFERENCES node,
  target_parent_id     uuid REFERENCES node,
  property_id          uuid REFERENCES property_definition,
  payload              jsonb NOT NULL DEFAULT '{}',
  evidence_document_id uuid,                     -- FK added in 02_ownership.sql
  created_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (change_request_id, seq)
);

-- Items can be added, changed or removed only while their request is a draft (D-07), so an approval always
-- refers to exactly the items that are applied. Each change bumps the request's row_version (ETag).
-- SECURITY DEFINER (owned by the migration owner): callers need no UPDATE right on change_request for the bump.
CREATE FUNCTION trg_change_item_draft_only() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = mdm, public AS $$
DECLARE
  v_cr     uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.change_request_id ELSE NEW.change_request_id END;
  v_status cr_status;
BEGIN
  SELECT status INTO v_status FROM mdm.change_request WHERE change_request_id = v_cr;
  IF v_status IS DISTINCT FROM 'draft' AND v_status IS NOT NULL THEN
    RAISE EXCEPTION 'Change request % is % and its items can no longer change', v_cr, v_status
      USING ERRCODE = 'N2102', HINT = 'change_request.not_draft';
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.change_request_id <> OLD.change_request_id THEN
    RAISE EXCEPTION 'An item cannot move to another change request'
      USING ERRCODE = 'N2102', HINT = 'change_item.request_fixed';
  END IF;
  UPDATE mdm.change_request SET row_version = row_version WHERE change_request_id = v_cr;   -- bump via trg_cr_row_version
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER change_item_draft_only BEFORE INSERT OR UPDATE OR DELETE ON change_item
  FOR EACH ROW EXECUTE FUNCTION trg_change_item_draft_only();

-- -----------------------------------------------------------------------------
-- Validations  (DRM Validations, rewritten as versioned, testable rules)
-- -----------------------------------------------------------------------------
CREATE TABLE validation_rule (
  rule_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_code           text NOT NULL UNIQUE,
  description         text NOT NULL,
  level               validation_level NOT NULL,
  severity            validation_severity NOT NULL DEFAULT 'error',
  engine              text NOT NULL CHECK (engine IN ('sql', 'cel', 'python')),
  -- For 'sql': a query taking $1 = as_of date and $2 = recorded_as_of timestamptz,
  -- returning (node_id uuid, hierarchy_id uuid, message text) for each violation.
  expression          text NOT NULL,
  hierarchy_id        uuid REFERENCES hierarchy,   -- NULL = applies everywhere
  drm_validation_orig text,                        -- original DRM validation, kept for traceability
  rule_version        int NOT NULL DEFAULT 1,
  is_active           boolean NOT NULL DEFAULT true
);

CREATE TABLE validation_result (
  result_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  rule_id           uuid NOT NULL REFERENCES validation_rule,
  change_request_id uuid REFERENCES change_request,
  node_id           uuid REFERENCES node,
  hierarchy_id      uuid REFERENCES hierarchy,
  severity          validation_severity NOT NULL,
  message           text NOT NULL,
  evaluated_at      timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Audit  (DRM Transaction Log) — append-only
-- -----------------------------------------------------------------------------
CREATE TABLE audit_log (
  audit_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  occurred_at       timestamptz NOT NULL DEFAULT clock_timestamp(),
  actor_id          uuid,                      -- from SET LOCAL mdm.actor_id
  change_request_id uuid,                      -- from SET LOCAL mdm.change_request_id
  table_name        text NOT NULL,
  action            text NOT NULL,
  old_row           jsonb,
  new_row           jsonb
);

CREATE FUNCTION trg_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME USING ERRCODE = 'N2011', HINT = 'append_only';
END $$;
CREATE TRIGGER audit_log_append_only BEFORE UPDATE OR DELETE ON audit_log
  FOR EACH ROW EXECUTE FUNCTION trg_append_only();

-- SECURITY DEFINER: audit rows are written with the owner's rights, so no application role needs (or has)
-- INSERT on audit_log, and none can write audit rows of its own making (ADR-014).
CREATE FUNCTION trg_audit_row() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = mdm, public AS $$
BEGIN
  INSERT INTO audit_log (actor_id, change_request_id, table_name, action, old_row, new_row)
  VALUES (nullif(current_setting('mdm.actor_id', true), '')::uuid,
          nullif(current_setting('mdm.change_request_id', true), '')::uuid,
          TG_TABLE_NAME, TG_OP,
          CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
          CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END);
  RETURN COALESCE(NEW, OLD);
END $$;

-- Bitemporal guard: no deletes; the only permitted update is closing recorded_period.
CREATE FUNCTION trg_bitemporal_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION '% is bitemporal: close recorded_period instead of deleting', TG_TABLE_NAME USING ERRCODE = 'N2010', HINT = 'bitemporal.immutable';
  END IF;
  IF (to_jsonb(OLD) - 'recorded_period') IS DISTINCT FROM (to_jsonb(NEW) - 'recorded_period') THEN
    RAISE EXCEPTION '% is bitemporal: only recorded_period may be closed; insert a new row instead',
      TG_TABLE_NAME USING ERRCODE = 'N2010', HINT = 'bitemporal.immutable';
  END IF;
  RETURN NEW;
END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['node_attr', 'node_identifier', 'legal_entity_profile',
                           'hierarchy_relationship', 'property_value'] LOOP
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON mdm.%I
                    FOR EACH ROW EXECUTE FUNCTION mdm.trg_bitemporal_guard()', t || '_guard', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['node', 'node_attr', 'node_identifier', 'legal_entity_profile',
                           'hierarchy', 'hierarchy_relationship', 'property_definition',
                           'property_value', 'change_request', 'change_item', 'version'] LOOP
    EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON mdm.%I
                    FOR EACH ROW EXECUTE FUNCTION mdm.trg_audit_row()', t || '_audit', t);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- As-of helper used by exports and the UI
-- -----------------------------------------------------------------------------
CREATE FUNCTION node_attr_asof(p_node_id uuid, p_as_of date, p_recorded_as_of timestamptz DEFAULT now())
RETURNS node_attr LANGUAGE sql STABLE SET search_path = mdm, public AS $$
  SELECT a.* FROM node_attr a
  WHERE a.node_id = p_node_id
    AND a.valid_period @> p_as_of
    AND a.recorded_period @> p_recorded_as_of
  LIMIT 1
$$;

-- -----------------------------------------------------------------------------
-- Seed reference data
-- -----------------------------------------------------------------------------
INSERT INTO identifier_scheme (scheme_code, name, issuer, value_pattern) VALUES
  ('LEI',    'Legal Entity Identifier',             'GLEIF',                 '^[A-Z0-9]{18}[0-9]{2}$'),
  ('IN_CIN', 'Corporate Identification Number',     'MCA (India)',           '^[A-Z][0-9]{5}[A-Z]{2}[0-9]{4}[A-Z]{3}[0-9]{6}$'),
  ('UK_CRN', 'Company Registration Number',         'Companies House (UK)',  NULL),
  ('DUNS',   'D-U-N-S Number',                      'Dun & Bradstreet',      '^[0-9]{9}$'),
  ('INTERNAL', 'Internal / legacy DRM identifier',  'Internal',              NULL);

INSERT INTO property_category (category_code, name, sort_seq) VALUES
  ('Core',      'Core / system',           1),
  ('Legal',     'Legal entity attributes', 2),
  ('Finance',   'Finance & consolidation', 3),
  ('Regulatory','Regulatory reporting',    4),
  ('Custom',    'Migrated DRM custom',     9);

-- -----------------------------------------------------------------------------
-- Draft-side operations (Phase 1 LLD §4.7). SECURITY DEFINER: owned by nexus_apply / nexus_decider (V7), so the
-- API role needs no write access to mdm.node or to the status column. Each checks its own preconditions.
-- -----------------------------------------------------------------------------

-- A new node's identity is allocated when the add_node item is drafted, so later items and the workflow can refer
-- to it (Phase 1 LLD A-5). The identity alone belongs to no slice until the request is applied.
CREATE FUNCTION allocate_node(p_kind node_kind, p_change_request_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = mdm, public AS $$
DECLARE
  v_status    cr_status;
  v_requester uuid;
  v_node      uuid;
BEGIN
  SELECT status, requester_id INTO v_status, v_requester
  FROM mdm.change_request WHERE change_request_id = p_change_request_id FOR UPDATE;
  IF v_status IS DISTINCT FROM 'draft' THEN
    RAISE EXCEPTION 'Change request % is % and cannot get new items', p_change_request_id, coalesce(v_status::text, 'missing')
      USING ERRCODE = 'N2102', HINT = 'change_request.not_draft';
  END IF;
  INSERT INTO mdm.node (node_kind, created_by) VALUES (p_kind, v_requester) RETURNING node_id INTO v_node;
  RETURN v_node;
END $$;

-- Only the requester withdraws; requests governed by a workflow are withdrawn through it (Phase 2).
CREATE FUNCTION withdraw_change_request(p_change_request_id uuid, p_actor uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = mdm, public AS $$
DECLARE r mdm.change_request%ROWTYPE;
BEGIN
  SELECT * INTO r FROM mdm.change_request WHERE change_request_id = p_change_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Change request % not found', p_change_request_id USING ERRCODE = 'N2102', HINT = 'change_request.not_found';
  END IF;
  IF r.requester_id IS DISTINCT FROM p_actor THEN
    RAISE EXCEPTION 'Only the requester can withdraw change request %', p_change_request_id
      USING ERRCODE = 'N1025', HINT = 'change_request.not_requester';
  END IF;
  IF r.governed_by_workflow THEN
    RAISE EXCEPTION 'Change request % is governed by a workflow; withdraw it there', p_change_request_id
      USING ERRCODE = 'N2104', HINT = 'change_request.governed';
  END IF;
  IF r.status NOT IN ('draft', 'submitted', 'in_review') THEN
    RAISE EXCEPTION 'Change request % cannot move from % to withdrawn', p_change_request_id, r.status
      USING ERRCODE = 'N2101', HINT = 'change_request.status_transition';
  END IF;
  UPDATE mdm.change_request SET status = 'withdrawn' WHERE change_request_id = p_change_request_id;
END $$;

-- -----------------------------------------------------------------------------
-- Apply (Phase 1 LLD §4.3, §4.5, §7.1–§7.3). The only path by which facts change: owned by nexus_apply (V7),
-- runs once per approved request, and writes every fact row with the request's id and the actor's id (D-29).
-- -----------------------------------------------------------------------------

-- Outbox of applied requests (ADR-016); consumers arrive in Phase 2/8. Append-only.
CREATE TABLE change_event (
  event_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  change_request_id uuid NOT NULL REFERENCES change_request,
  event_type        text NOT NULL CHECK (event_type IN ('change_request_applied')),
  payload           jsonb NOT NULL,              -- {items:[{seq, action, node_id, hierarchy_id, property_id}], effective_from}
  created_at        timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TRIGGER change_event_append_only BEFORE UPDATE OR DELETE ON change_event
  FOR EACH ROW EXECUTE FUNCTION trg_append_only();

-- Which items a governing workflow committed (ADR-019). mdm defines it; only wf_bridge writes it (Phase 2);
-- mdm never references wf. Append-only.
CREATE TABLE change_item_clearance (
  change_item_id uuid PRIMARY KEY REFERENCES change_item,
  cleared_at     timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER change_item_clearance_append_only BEFORE UPDATE OR DELETE ON change_item_clearance
  FOR EACH ROW EXECUTE FUNCTION trg_append_only();

-- Inserts one row from JSON, using only the columns present (so the others keep their defaults) and never the
-- surrogate key.
CREATE FUNCTION apply_insert(p_table text, p_id_col text, p_row jsonb)
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE v_cols text;
BEGIN
  SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum) INTO v_cols
  FROM pg_attribute a
  WHERE a.attrelid = ('mdm.' || quote_ident(p_table))::regclass AND a.attnum > 0 AND NOT a.attisdropped
    AND a.attname::text IS DISTINCT FROM p_id_col AND p_row ? a.attname::text;
  EXECUTE format('INSERT INTO mdm.%1$I (%2$s) SELECT %2$s FROM jsonb_populate_record(NULL::mdm.%1$I, $1)', p_table, v_cols)
    USING p_row;
  RETURN 1;
END $$;

-- Generic "set fact from D" / "end fact at D" on a bitemporal fact table (LLD §7.1). Never changes a fact in place:
-- the current row containing D is closed in recorded time and re-stated as copies for the parts that stay true
-- (before D; and, with an explicit valid_to, after it); then the new row is inserted for [D, upper).
--   p_key     columns that identify the fact (JSON; a null value matches NULL)
--   p_id_col  surrogate key column, left to its default on inserted rows (NULL when the table has none)
--   p_values  columns of the new row (ignored when p_end)
-- D, the recorded instant and the request id come from the settings made by apply_change_request.
-- Returns the number of rows written (closed + inserted).
CREATE FUNCTION apply_fact(p_table text, p_id_col text, p_key jsonb, p_values jsonb, p_valid_to date, p_end boolean)
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE
  v_d     date        := current_setting('mdm.apply_date')::date;
  v_t     timestamptz := now();                                   -- one recorded instant for the whole request
  v_cr    uuid        := current_setting('mdm.change_request_id')::uuid;
  v_where text;
  r       jsonb;
  v_ctid  tid;
  v_valid daterange;
  v_upper date;
  v_rows  int := 0;
  v_stamp jsonb;
BEGIN
  IF p_valid_to IS NOT NULL AND p_valid_to <= v_d THEN
    RAISE EXCEPTION 'validTo % must be after the effective date %', p_valid_to, v_d
      USING ERRCODE = 'N2105', HINT = 'apply.item_invalid';
  END IF;
  SELECT string_agg(CASE WHEN p_key ->> col IS NULL THEN format('t.%I IS NULL', col)
                         ELSE format('t.%1$I = k.%1$I', col) END, ' AND ')
    INTO v_where FROM jsonb_object_keys(p_key) AS col;
  v_stamp := jsonb_build_object('recorded_period', tstzrange(v_t, NULL)::text, 'change_request_id', v_cr);

  EXECUTE format($q$SELECT to_jsonb(t), t.ctid FROM mdm.%1$I t, jsonb_populate_record(NULL::mdm.%1$I, $1) k
                    WHERE %2$s AND t.valid_period @> $2 AND upper_inf(t.recorded_period) FOR UPDATE OF t$q$, p_table, v_where)
    INTO r, v_ctid USING p_key, v_d;

  IF r IS NOT NULL THEN
    v_valid := (r ->> 'valid_period')::daterange;
    EXECUTE format('UPDATE mdm.%I SET recorded_period = tstzrange(lower(recorded_period), $1) WHERE ctid = $2', p_table)
      USING v_t, v_ctid;
    v_rows := v_rows + 1;
    IF lower_inf(v_valid) OR lower(v_valid) < v_d THEN           -- history before D stays as it was
      v_rows := v_rows + apply_insert(p_table, p_id_col, r || v_stamp
                  || jsonb_build_object('valid_period', daterange(lower(v_valid), v_d)::text));
    END IF;
    IF NOT p_end AND p_valid_to IS NOT NULL AND (upper_inf(v_valid) OR upper(v_valid) > p_valid_to) THEN
      v_rows := v_rows + apply_insert(p_table, p_id_col, r || v_stamp
                  || jsonb_build_object('valid_period', daterange(p_valid_to, upper(v_valid))::text));
    END IF;
    v_upper := coalesce(p_valid_to, upper(v_valid));            -- A-2: later scheduled rows are kept
  ELSIF NOT p_end THEN
    EXECUTE format($q$SELECT min(lower(t.valid_period)) FROM mdm.%1$I t, jsonb_populate_record(NULL::mdm.%1$I, $1) k
                      WHERE %2$s AND lower(t.valid_period) > $2 AND upper_inf(t.recorded_period)$q$, p_table, v_where)
      INTO v_upper USING p_key, v_d;
    v_upper := coalesce(p_valid_to, v_upper);
  END IF;

  IF NOT p_end THEN
    v_rows := v_rows + apply_insert(p_table, p_id_col, coalesce(r, '{}'::jsonb) || p_key || coalesce(p_values, '{}'::jsonb)
                || v_stamp || jsonb_build_object('valid_period', daterange(v_d, v_upper)::text));
  END IF;
  RETURN v_rows;
END $$;

-- Placement of a node in a hierarchy on a date: {primary: parent id or null, parents: [ids, sorted]}.
CREATE FUNCTION apply_placement(p_hierarchy uuid, p_node uuid, p_d date)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = mdm, public AS $$
  SELECT jsonb_build_object(
    'primary', (SELECT r.parent_node_id FROM mdm.hierarchy_relationship r
                WHERE r.hierarchy_id = p_hierarchy AND r.child_node_id = p_node AND r.is_primary
                  AND r.valid_period @> p_d AND upper_inf(r.recorded_period)),
    'parents', coalesce((SELECT jsonb_agg(r.parent_node_id::text ORDER BY r.parent_node_id::text COLLATE "C")
                         FROM mdm.hierarchy_relationship r
                         WHERE r.hierarchy_id = p_hierarchy AND r.child_node_id = p_node
                           AND r.valid_period @> p_d AND upper_inf(r.recorded_period)), '[]'::jsonb))
$$;

-- Stale base (LLD §7.3): the fact must still be what the item assumed when it was drafted. The HINT carries the
-- machine code (ADR-020); expected and actual go in DETAIL.
CREATE FUNCTION apply_expect(p_item change_item, p_field text, p_actual jsonb)
RETURNS void LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE v_expected jsonb := p_item.payload -> 'expected' -> p_field;
BEGIN
  IF v_expected IS NOT NULL AND v_expected IS DISTINCT FROM coalesce(p_actual, 'null'::jsonb) THEN
    RAISE EXCEPTION 'Item % changed since it was drafted: % was expected to be %, but is %',
      p_item.seq, p_field, v_expected, coalesce(p_actual, 'null'::jsonb)
      USING ERRCODE = 'N3001', HINT = 'apply.stale_base',
            DETAIL = jsonb_build_object('seq', p_item.seq, 'field', p_field, 'expected', v_expected, 'actual', p_actual)::text;
  END IF;
END $$;

-- The target parent must be placed in the hierarchy on D and allow children.
CREATE FUNCTION apply_require_parent(p_hierarchy uuid, p_parent uuid, p_d date)
RETURNS void LANGUAGE plpgsql SET search_path = mdm, public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM mdm.hierarchy WHERE hierarchy_id = p_hierarchy AND top_node_id = p_parent)
     AND NOT EXISTS (SELECT 1 FROM mdm.hierarchy_relationship r
                     WHERE r.hierarchy_id = p_hierarchy AND r.child_node_id = p_parent
                       AND r.valid_period @> p_d AND upper_inf(r.recorded_period)) THEN
    RAISE EXCEPTION 'Parent % is not in hierarchy % on %', p_parent, p_hierarchy, p_d
      USING ERRCODE = 'N2105', HINT = 'apply.item_invalid';
  END IF;
  IF NOT coalesce((SELECT a.allows_children FROM mdm.node_attr a WHERE a.node_id = p_parent
                   AND a.valid_period @> p_d AND upper_inf(a.recorded_period)), false) THEN
    RAISE EXCEPTION 'Parent % is a leaf on % and cannot have children', p_parent, p_d
      USING ERRCODE = 'N2004', HINT = 'hierarchy.parent_is_leaf';
  END IF;
END $$;

-- Sort order of a new child: the item's, or after the last current sibling.
CREATE FUNCTION apply_sort_order(p_item change_item, p_d date)
RETURNS numeric LANGUAGE sql STABLE SET search_path = mdm, public AS $$
  SELECT coalesce((p_item.payload ->> 'sortOrder')::numeric,
                  (SELECT max(r.sort_order) + 1000 FROM mdm.hierarchy_relationship r
                   WHERE r.hierarchy_id = p_item.hierarchy_id AND r.parent_node_id = p_item.target_parent_id
                     AND r.valid_period @> p_d AND upper_inf(r.recorded_period)),
                  1000)
$$;

-- Places the item's node under its target parent from D (until p_upper, or the next scheduled placement).
CREATE FUNCTION apply_place(p_item change_item, p_primary boolean, p_upper date)
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE v_d date := current_setting('mdm.apply_date')::date;
BEGIN
  PERFORM apply_require_parent(p_item.hierarchy_id, p_item.target_parent_id, v_d);
  RETURN apply_fact('hierarchy_relationship', 'relationship_id',
           jsonb_build_object('hierarchy_id', p_item.hierarchy_id, 'parent_node_id', p_item.target_parent_id,
                              'child_node_id', p_item.node_id),
           jsonb_build_object('is_primary', p_primary, 'sort_order', apply_sort_order(p_item, v_d)),
           p_upper, false);
END $$;

-- add_node (LLD §7.2): attributes from D, then the primary placement.
CREATE FUNCTION apply_add_node(p_item change_item)
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE v_rows int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM mdm.node WHERE node_id = p_item.node_id)
     OR EXISTS (SELECT 1 FROM mdm.node_attr WHERE node_id = p_item.node_id) THEN
    RAISE EXCEPTION 'Item %: node % must be a new identity without attributes', p_item.seq, p_item.node_id
      USING ERRCODE = 'N2105', HINT = 'apply.item_invalid';
  END IF;
  v_rows := apply_fact('node_attr', NULL, jsonb_build_object('node_id', p_item.node_id),
              jsonb_build_object('node_name', p_item.payload ->> 'name',
                                 'description', p_item.payload ->> 'description',
                                 'is_active', true,
                                 'allows_children', NOT coalesce((p_item.payload ->> 'isLeaf')::boolean, false)),
              NULL, false);
  RETURN v_rows + apply_place(p_item, true, NULL);
END $$;

-- insert_node: primary if the node has no primary placement in the hierarchy on D, otherwise shared
-- (trg_hierarchy_integrity refuses shared placements where the hierarchy does not allow them).
CREATE FUNCTION apply_insert_node(p_item change_item)
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE
  v_d     date  := current_setting('mdm.apply_date')::date;
  v_place jsonb := apply_placement(p_item.hierarchy_id, p_item.node_id, v_d);
BEGIN
  IF NOT EXISTS (SELECT 1 FROM mdm.node_attr a WHERE a.node_id = p_item.node_id
                 AND a.valid_period @> v_d AND upper_inf(a.recorded_period)) THEN
    RAISE EXCEPTION 'Item %: node % does not exist on %', p_item.seq, p_item.node_id, v_d
      USING ERRCODE = 'N2105', HINT = 'apply.item_invalid';
  END IF;
  PERFORM apply_expect(p_item, 'parentIds', v_place -> 'parents');
  RETURN apply_place(p_item, v_place ->> 'primary' IS NULL, NULL);
END $$;

-- move_node: end the primary placement at D and place the node under the target until the old placement's end;
-- descendants follow (adjacency list). The integrity trigger refuses cycles.
CREATE FUNCTION apply_move_node(p_item change_item)
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE
  v_d     date  := current_setting('mdm.apply_date')::date;
  v_place jsonb := apply_placement(p_item.hierarchy_id, p_item.node_id, v_d);
  v_rel   uuid;
  v_valid daterange;
  v_rows  int;
BEGIN
  PERFORM apply_expect(p_item, 'parentId', v_place -> 'primary');
  PERFORM apply_expect(p_item, 'parentIds', v_place -> 'parents');
  SELECT r.relationship_id, r.valid_period INTO v_rel, v_valid FROM mdm.hierarchy_relationship r
  WHERE r.hierarchy_id = p_item.hierarchy_id AND r.child_node_id = p_item.node_id AND r.is_primary
    AND r.valid_period @> v_d AND upper_inf(r.recorded_period);
  IF v_rel IS NULL THEN
    RAISE EXCEPTION 'Item %: node % has no primary placement in hierarchy % on %', p_item.seq, p_item.node_id,
      p_item.hierarchy_id, v_d USING ERRCODE = 'N2105', HINT = 'apply.item_invalid';
  END IF;
  v_rows := apply_fact('hierarchy_relationship', 'relationship_id', jsonb_build_object('relationship_id', v_rel),
                       NULL, NULL, true);
  RETURN v_rows + apply_place(p_item, true, upper(v_valid));
END $$;

-- Ends, at D, every current relationship row selected by the caller (by id), through apply_fact.
CREATE FUNCTION apply_end_relationships(p_ids uuid[])
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE v_id uuid; v_rows int := 0;
BEGIN
  FOREACH v_id IN ARRAY coalesce(p_ids, '{}') LOOP
    v_rows := v_rows + apply_fact('hierarchy_relationship', 'relationship_id', jsonb_build_object('relationship_id', v_id),
                                  NULL, NULL, true);
  END LOOP;
  RETURN v_rows;
END $$;

-- remove_node (LLD §7.2): take the node out of one hierarchy from D. With children it needs cascade, which removes
-- the node's primary sub-tree too: every placement of the sub-tree's members in this hierarchy ends, including
-- shared links hanging below them. The node itself stays and keeps its places in other hierarchies.
CREATE FUNCTION apply_remove_node(p_item change_item)
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE
  v_d     date  := current_setting('mdm.apply_date')::date;
  v_place jsonb := apply_placement(p_item.hierarchy_id, p_item.node_id, v_d);
  v_ids   uuid[];
BEGIN
  PERFORM apply_expect(p_item, 'parentIds', v_place -> 'parents');
  IF jsonb_array_length(v_place -> 'parents') = 0 THEN
    RAISE EXCEPTION 'Item %: node % is not placed in hierarchy % on %', p_item.seq, p_item.node_id, p_item.hierarchy_id, v_d
      USING ERRCODE = 'N2105', HINT = 'apply.item_invalid';
  END IF;
  IF NOT coalesce((p_item.payload ->> 'cascade')::boolean, false)
     AND EXISTS (SELECT 1 FROM mdm.hierarchy_relationship r
                 WHERE r.hierarchy_id = p_item.hierarchy_id AND r.parent_node_id = p_item.node_id
                   AND r.valid_period @> v_d AND upper_inf(r.recorded_period)) THEN
    RAISE EXCEPTION 'Item %: node % has children in hierarchy %; remove them first or use cascade',
      p_item.seq, p_item.node_id, p_item.hierarchy_id USING ERRCODE = 'N2005', HINT = 'hierarchy.remove_with_children';
  END IF;
  WITH RECURSIVE sub(node_id) AS (
    SELECT p_item.node_id
    UNION
    SELECT r.child_node_id FROM mdm.hierarchy_relationship r JOIN sub ON r.parent_node_id = sub.node_id
    WHERE r.hierarchy_id = p_item.hierarchy_id AND r.is_primary AND r.valid_period @> v_d AND upper_inf(r.recorded_period)
  )
  SELECT array_agg(r.relationship_id ORDER BY r.relationship_id) INTO v_ids
  FROM mdm.hierarchy_relationship r
  WHERE r.hierarchy_id = p_item.hierarchy_id AND r.valid_period @> v_d AND upper_inf(r.recorded_period)
    AND (r.child_node_id IN (SELECT node_id FROM sub) OR r.parent_node_id IN (SELECT node_id FROM sub));
  RETURN apply_end_relationships(v_ids);
END $$;

-- delete_node (LLD §7.2): the node ends at D everywhere: its attributes, its stored values and its placements in
-- every hierarchy. Refused while anything still depends on it from D on: being a top node (N2002), having children
-- (N2005), being referenced by a node_ref value (N2006), or having changes already scheduled after D (N2105).
CREATE FUNCTION apply_delete_node(p_item change_item)
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE
  v_d    date := current_setting('mdm.apply_date')::date;
  v_from daterange := daterange(current_setting('mdm.apply_date')::date, NULL);
  v_attr mdm.node_attr%ROWTYPE;
  v_ids  uuid[];
  v_pv   record;
  v_rows int := 0;
BEGIN
  SELECT * INTO v_attr FROM mdm.node_attr a
  WHERE a.node_id = p_item.node_id AND a.valid_period @> v_d AND upper_inf(a.recorded_period);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Item %: node % does not exist on %', p_item.seq, p_item.node_id, v_d
      USING ERRCODE = 'N2105', HINT = 'apply.item_invalid';
  END IF;
  PERFORM apply_expect(p_item, 'name', to_jsonb(v_attr.node_name));
  PERFORM apply_expect(p_item, 'description', to_jsonb(v_attr.description));
  IF EXISTS (SELECT 1 FROM mdm.hierarchy WHERE top_node_id = p_item.node_id) THEN
    RAISE EXCEPTION 'Item %: node % is the top node of a hierarchy and cannot be deleted', p_item.seq, p_item.node_id
      USING ERRCODE = 'N2002', HINT = 'hierarchy.top_node';
  END IF;
  IF EXISTS (SELECT 1 FROM mdm.hierarchy_relationship r
             WHERE r.parent_node_id = p_item.node_id AND r.valid_period && v_from AND upper_inf(r.recorded_period)) THEN
    RAISE EXCEPTION 'Item %: node % has children on or after %; move or remove them first', p_item.seq, p_item.node_id, v_d
      USING ERRCODE = 'N2005', HINT = 'hierarchy.remove_with_children';
  END IF;
  IF EXISTS (SELECT 1 FROM mdm.property_value pv JOIN mdm.property_definition pd ON pd.property_id = pv.property_id
             WHERE pd.data_type IN ('node_ref', 'multi_node_ref') AND pv.node_id <> p_item.node_id
               AND pv.valid_period && v_from AND upper_inf(pv.recorded_period)
               AND (pv.value = to_jsonb(p_item.node_id::text)
                    OR (jsonb_typeof(pv.value) = 'array' AND pv.value ? p_item.node_id::text))) THEN
    RAISE EXCEPTION 'Item %: node % is still referenced by a property value on or after %', p_item.seq, p_item.node_id, v_d
      USING ERRCODE = 'N2006', HINT = 'node.referenced';
  END IF;
  IF EXISTS (SELECT 1 FROM mdm.node_attr a WHERE a.node_id = p_item.node_id AND lower(a.valid_period) > v_d AND upper_inf(a.recorded_period))
     OR EXISTS (SELECT 1 FROM mdm.hierarchy_relationship r WHERE r.child_node_id = p_item.node_id AND lower(r.valid_period) > v_d AND upper_inf(r.recorded_period))
     OR EXISTS (SELECT 1 FROM mdm.property_value pv WHERE pv.node_id = p_item.node_id AND lower(pv.valid_period) > v_d AND upper_inf(pv.recorded_period)) THEN
    RAISE EXCEPTION 'Item %: node % has changes scheduled after %', p_item.seq, p_item.node_id, v_d
      USING ERRCODE = 'N2105', HINT = 'apply.item_invalid';
  END IF;

  SELECT array_agg(r.relationship_id ORDER BY r.relationship_id) INTO v_ids FROM mdm.hierarchy_relationship r
  WHERE r.child_node_id = p_item.node_id AND r.valid_period @> v_d AND upper_inf(r.recorded_period);
  v_rows := apply_end_relationships(v_ids);
  FOR v_pv IN SELECT pv.property_value_id FROM mdm.property_value pv
              WHERE pv.node_id = p_item.node_id AND pv.valid_period @> v_d AND upper_inf(pv.recorded_period)
              ORDER BY pv.property_value_id LOOP
    v_rows := v_rows + apply_fact('property_value', 'property_value_id',
                                  jsonb_build_object('property_value_id', v_pv.property_value_id), NULL, NULL, true);
  END LOOP;
  RETURN v_rows + apply_fact('node_attr', NULL, jsonb_build_object('node_id', p_item.node_id), NULL, NULL, true);
END $$;

-- update_node: name and/or description from D (set-from-D on node_attr; other attributes carry over).
CREATE FUNCTION apply_update_node(p_item change_item)
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE
  v_d      date := current_setting('mdm.apply_date')::date;
  v_attr   mdm.node_attr%ROWTYPE;
  v_values jsonb := '{}';
BEGIN
  SELECT * INTO v_attr FROM mdm.node_attr a
  WHERE a.node_id = p_item.node_id AND a.valid_period @> v_d AND upper_inf(a.recorded_period);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Item %: node % does not exist on %', p_item.seq, p_item.node_id, v_d
      USING ERRCODE = 'N2105', HINT = 'apply.item_invalid';
  END IF;
  PERFORM apply_expect(p_item, 'name', to_jsonb(v_attr.node_name));
  PERFORM apply_expect(p_item, 'description', to_jsonb(v_attr.description));
  IF p_item.payload ? 'name' THEN
    v_values := v_values || jsonb_build_object('node_name', p_item.payload -> 'name');
  END IF;
  IF p_item.payload ? 'description' THEN
    v_values := v_values || jsonb_build_object('description', p_item.payload -> 'description');
  END IF;
  RETURN apply_fact('node_attr', NULL, jsonb_build_object('node_id', p_item.node_id), v_values, NULL, false);
END $$;

-- add_hierarchy: the new top node's attributes from D, then the hierarchy row (not bitemporal; it has no
-- placements before its top node exists). A duplicate code fails the apply (23505).
CREATE FUNCTION apply_add_hierarchy(p_item change_item)
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE
  v_top  jsonb := p_item.payload -> 'topNode';
  v_rows int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM mdm.node WHERE node_id = p_item.node_id)
     OR EXISTS (SELECT 1 FROM mdm.node_attr WHERE node_id = p_item.node_id) THEN
    RAISE EXCEPTION 'Item %: top node % must be a new identity without attributes', p_item.seq, p_item.node_id
      USING ERRCODE = 'N2105', HINT = 'apply.item_invalid';
  END IF;
  v_rows := apply_fact('node_attr', NULL, jsonb_build_object('node_id', p_item.node_id),
              jsonb_build_object('node_name', v_top ->> 'name', 'description', v_top ->> 'description',
                                 'is_active', true, 'allows_children', true),
              NULL, false);
  INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, purpose, hierarchy_group, top_node_id, allow_shared_nodes, sort_seq)
  VALUES (p_item.payload ->> 'code', p_item.payload ->> 'name', p_item.payload ->> 'purpose', p_item.payload ->> 'group',
          p_item.node_id, coalesce((p_item.payload ->> 'allowSharedNodes')::boolean, false),
          (p_item.payload ->> 'sortSeq')::int);
  RETURN v_rows + 1;
END $$;

-- Actions whose handlers arrive in later increments (1-8c) fail the apply rather than being skipped.
CREATE FUNCTION apply_not_available(p_item change_item)
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
BEGIN
  RAISE EXCEPTION 'Item %: action % cannot be applied yet', p_item.seq, p_item.action
    USING ERRCODE = 'N2105', HINT = 'apply.action_not_available';
END $$;

-- Applies an approved request as one unit (LLD §7.1). Rule failures (N2…, stale base, overlaps, duplicates)
-- undo every item and leave the request apply_failed with the reason; anything else is raised to the caller.
CREATE FUNCTION apply_change_request(p_change_request_id uuid, p_actor uuid)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = mdm, public AS $$
DECLARE
  cr       mdm.change_request%ROWTYPE;
  it       mdm.change_item%ROWTYPE;
  v_rows   int := 0;
  v_seq    int;
  v_state  text;
  v_msg    text;
  v_detail text;
BEGIN
  SELECT * INTO cr FROM mdm.change_request WHERE change_request_id = p_change_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Change request % not found', p_change_request_id USING ERRCODE = 'N2102', HINT = 'change_request.not_found';
  END IF;
  IF cr.status = 'applied' THEN
    RETURN 0;                                                    -- idempotent: a repeated apply does nothing
  END IF;
  IF cr.status <> 'approved' THEN
    RAISE EXCEPTION 'Change request % is % and cannot be applied', p_change_request_id, cr.status
      USING ERRCODE = 'N2101', HINT = 'change_request.status_transition';
  END IF;
  PERFORM set_config('mdm.actor_id', p_actor::text, true);
  PERFORM set_config('mdm.change_request_id', p_change_request_id::text, true);
  PERFORM set_config('mdm.apply_date', cr.effective_from::text, true);

  BEGIN                                                          -- subtransaction: all items or none
    FOR it IN
      SELECT ci.* FROM mdm.change_item ci
      WHERE ci.change_request_id = p_change_request_id
        AND (NOT cr.governed_by_workflow
             OR EXISTS (SELECT 1 FROM mdm.change_item_clearance c WHERE c.change_item_id = ci.change_item_id))
      ORDER BY ci.seq
    LOOP
      v_seq := it.seq;
      v_rows := v_rows + CASE it.action
        WHEN 'add_node'    THEN mdm.apply_add_node(it)
        WHEN 'insert_node' THEN mdm.apply_insert_node(it)
        WHEN 'move_node'   THEN mdm.apply_move_node(it)
        WHEN 'remove_node' THEN mdm.apply_remove_node(it)
        WHEN 'delete_node' THEN mdm.apply_delete_node(it)
        WHEN 'update_node' THEN mdm.apply_update_node(it)
        WHEN 'add_hierarchy' THEN mdm.apply_add_hierarchy(it)
        ELSE mdm.apply_not_available(it)
      END;
    END LOOP;
    v_seq := NULL;

    INSERT INTO mdm.change_event (change_request_id, event_type, payload)
    SELECT p_change_request_id, 'change_request_applied',
           jsonb_build_object('effective_from', cr.effective_from,
             'items', coalesce(jsonb_agg(jsonb_build_object('seq', ci.seq, 'action', ci.action, 'node_id', ci.node_id,
                                'hierarchy_id', ci.hierarchy_id, 'property_id', ci.property_id) ORDER BY ci.seq), '[]'::jsonb))
    FROM mdm.change_item ci
    WHERE ci.change_request_id = p_change_request_id
      AND (NOT cr.governed_by_workflow
           OR EXISTS (SELECT 1 FROM mdm.change_item_clearance c WHERE c.change_item_id = ci.change_item_id));

    UPDATE mdm.change_request SET status = 'applied', applied_at = now(), apply_error = NULL
    WHERE change_request_id = p_change_request_id;
    RETURN v_rows;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
    IF v_state LIKE 'N2%' OR v_state IN ('N3001', '23P01', '23505') THEN
      UPDATE mdm.change_request
      SET status = 'apply_failed',
          apply_error = v_state || ' (item ' || coalesce(v_seq::text, '-') || '): ' || v_msg
                        || coalesce(' ' || nullif(v_detail, ''), '')
      WHERE change_request_id = p_change_request_id;
      RETURN -1;
    END IF;
    RAISE;
  END;
END $$;