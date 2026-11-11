-- =============================================================================
-- Nexus — 07: LEAST-PRIVILEGE ROLES (ADR-014, amended by ADR-019; closes D-04)
--
-- Group roles only (NOLOGIN). Logins are created per environment by the platform and granted one of these
-- roles; their secrets never appear in migrations. Roles are cluster-wide in PostgreSQL, so creation is
-- idempotent: repeated test databases on the same server reuse them.
--
--   nexus_api       the API: reads everything it serves; writes only drafts (requests, items); everything
--                   else goes through SECURITY DEFINER functions owned by the roles below
--   nexus_wf        the workflow worker: reads mdm, writes wf (never mdm: CLAUDE.md rule 3)
--   nexus_bridge    owns wf_bridge functions: the only writer of decision columns on mdm.change_request
--   nexus_apply     owns the apply and validation functions (Phase 1 increments 1-8, 1-9): the only writer of facts
--   nexus_decider   owns the submit / withdraw / decide functions (increments 1-7, 1-10)
--   nexus_readonly  reporting: read-only
-- =============================================================================

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['nexus_api', 'nexus_wf', 'nexus_bridge', 'nexus_apply', 'nexus_decider', 'nexus_readonly'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN', r);
    END IF;
  END LOOP;
END $$;

-- New schemas give PUBLIC nothing; say so explicitly so nobody relies on it.
REVOKE ALL ON SCHEMA mdm, wf, wf_bridge, mdm_stage FROM PUBLIC;

GRANT USAGE ON SCHEMA mdm, wf, wf_bridge TO nexus_api, nexus_wf, nexus_bridge, nexus_apply, nexus_decider, nexus_readonly;

-- -----------------------------------------------------------------------------
-- Reads
-- -----------------------------------------------------------------------------
GRANT SELECT ON ALL TABLES IN SCHEMA mdm, wf, wf_bridge
  TO nexus_api, nexus_wf, nexus_bridge, nexus_apply, nexus_decider, nexus_readonly;
-- Tables added by later migrations (run by the same owner) are readable too.
ALTER DEFAULT PRIVILEGES IN SCHEMA mdm, wf, wf_bridge
  GRANT SELECT ON TABLES TO nexus_api, nexus_wf, nexus_bridge, nexus_apply, nexus_decider, nexus_readonly;

-- -----------------------------------------------------------------------------
-- nexus_api: drafts only
-- -----------------------------------------------------------------------------
GRANT INSERT ON mdm.change_request TO nexus_api;
GRANT UPDATE (title, rationale, risk_tier, effective_from) ON mdm.change_request TO nexus_api;  -- draft-only by trigger
GRANT INSERT, DELETE ON mdm.change_item TO nexus_api;                                          -- draft-only by trigger

-- -----------------------------------------------------------------------------
-- nexus_wf: workflow tables; never mdm
-- -----------------------------------------------------------------------------
GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA wf TO nexus_wf;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA wf TO nexus_wf;
ALTER DEFAULT PRIVILEGES IN SCHEMA wf GRANT INSERT, UPDATE, DELETE ON TABLES TO nexus_wf;
ALTER DEFAULT PRIVILEGES IN SCHEMA wf GRANT USAGE ON SEQUENCES TO nexus_wf;

-- -----------------------------------------------------------------------------
-- nexus_bridge: the single writer across layers (ADR-003, ADR-019)
-- -----------------------------------------------------------------------------
GRANT UPDATE (status, submitted_at, decided_by, decided_at, decision_basis, decision_policy_ref, governed_by_workflow)
  ON mdm.change_request TO nexus_bridge;

ALTER FUNCTION wf_bridge.sync_change_request(uuid) OWNER TO nexus_bridge;
-- Callable only through the workflow role (its trigger on wf.workflow_instance), not by anyone with a connection.
REVOKE EXECUTE ON FUNCTION wf_bridge.sync_change_request(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION wf_bridge.sync_change_request(uuid) TO nexus_wf;

-- -----------------------------------------------------------------------------
-- Draft-side functions (Phase 1 increment 1-7): owners hold the narrow rights; only the API may call them
-- -----------------------------------------------------------------------------
GRANT INSERT ON mdm.node TO nexus_apply;
-- Apply records its outcome (Phase 1 LLD §4.1); this also lets nexus_apply's functions lock the request row
-- (SELECT … FOR UPDATE needs UPDATE on at least one column).
GRANT UPDATE (status, applied_at, apply_error) ON mdm.change_request TO nexus_apply;
ALTER FUNCTION mdm.allocate_node(mdm.node_kind, uuid) OWNER TO nexus_apply;
REVOKE EXECUTE ON FUNCTION mdm.allocate_node(mdm.node_kind, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mdm.allocate_node(mdm.node_kind, uuid) TO nexus_api;

GRANT UPDATE (status, submitted_at, decided_by, decided_at, decision_note, decision_basis) ON mdm.change_request TO nexus_decider;
ALTER FUNCTION mdm.withdraw_change_request(uuid, uuid) OWNER TO nexus_decider;
REVOKE EXECUTE ON FUNCTION mdm.withdraw_change_request(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mdm.withdraw_change_request(uuid, uuid) TO nexus_api;

-- -----------------------------------------------------------------------------
-- Apply (Phase 1 increment 1-8): nexus_apply is the only writer of facts. It may insert fact rows and close their
-- recorded_period (the bitemporal guard allows nothing else), and append change events.
-- -----------------------------------------------------------------------------
GRANT INSERT, UPDATE (recorded_period) ON mdm.node_attr, mdm.hierarchy_relationship, mdm.property_value TO nexus_apply;
GRANT INSERT ON mdm.change_event TO nexus_apply;
GRANT INSERT ON mdm.hierarchy TO nexus_apply;                   -- add_hierarchy (1-8b); hierarchies are never updated by apply
GRANT INSERT ON mdm.change_item_clearance TO nexus_bridge;      -- written in Phase 2 when a workflow commits items

-- Internal helpers: run inside apply_change_request with nexus_apply's rights; nobody else may call them.
DO $$
DECLARE f regprocedure;
BEGIN
  FOR f IN SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'mdm' AND p.proname LIKE 'apply\_%' AND p.proname <> 'apply_change_request' LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO nexus_apply', f);
  END LOOP;
END $$;

ALTER FUNCTION mdm.apply_change_request(uuid, uuid) OWNER TO nexus_apply;
REVOKE EXECUTE ON FUNCTION mdm.apply_change_request(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mdm.apply_change_request(uuid, uuid) TO nexus_api;   -- ApplyService, after a decision (1-10)

-- Validation (1-9): a trial apply, so it is owned by the fact writer; its trial is always rolled back, which also
-- discards anything a rule expression might write. Only its findings persist.
GRANT INSERT ON mdm.validation_result TO nexus_apply;
ALTER FUNCTION mdm.validate_change_request(uuid, date) OWNER TO nexus_apply;
REVOKE EXECUTE ON FUNCTION mdm.validate_change_request(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mdm.validate_change_request(uuid, date) TO nexus_api;

ALTER FUNCTION mdm.submit_change_request(uuid, uuid) OWNER TO nexus_decider;
REVOKE EXECUTE ON FUNCTION mdm.submit_change_request(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mdm.submit_change_request(uuid, uuid) TO nexus_api;

-- Decision (1-10): the only path by which the API records a decision; its basis is always human_review (D-04).
ALTER FUNCTION mdm.decide_change_request(uuid, uuid, text, text) OWNER TO nexus_decider;
REVOKE EXECUTE ON FUNCTION mdm.decide_change_request(uuid, uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mdm.decide_change_request(uuid, uuid, text, text) TO nexus_api;

ALTER FUNCTION mdm.record_apply_failure(uuid, text) OWNER TO nexus_apply;
REVOKE EXECUTE ON FUNCTION mdm.record_apply_failure(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mdm.record_apply_failure(uuid, text) TO nexus_api;
