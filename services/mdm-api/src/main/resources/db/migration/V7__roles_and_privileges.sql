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
