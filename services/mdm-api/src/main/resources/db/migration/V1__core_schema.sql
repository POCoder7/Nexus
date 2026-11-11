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
