-- =============================================================================
-- Nexus — 08: ENTITLEMENTS, SETTINGS, IDEMPOTENCY (Phase 1: ADR-022, ADR-018/CR-01, ADR-015)
-- =============================================================================
SET search_path = mdm, public;

-- -----------------------------------------------------------------------------
-- System settings: one source of truth for values every component must agree on (CR-01).
-- Only the owner (migrations, administrators) can change them; a session cannot.
-- -----------------------------------------------------------------------------
CREATE TABLE mdm.system_setting (
  setting_key   text PRIMARY KEY,
  setting_value text NOT NULL,
  description   text NOT NULL
);
INSERT INTO mdm.system_setting VALUES
  ('business_time_zone', 'America/New_York',
   'ADR-018: the business day for as-of defaults, caps, SLAs and schedules (EST in winter, EDT in summer)');

-- -----------------------------------------------------------------------------
-- Roles and grants (ADR-022). Roles are data; what each role may do is fixed in code (Permission matrix).
-- -----------------------------------------------------------------------------
CREATE TABLE mdm.role (
  role_code   text PRIMARY KEY,
  description text NOT NULL
);
INSERT INTO mdm.role VALUES
  ('VIEWER',         'Read'),
  ('STEWARD',        'Read and propose changes'),
  ('APPROVER',       'Read and decide requests (never their own)'),
  ('WORKFLOW_ADMIN', 'Configure workflow models'),
  ('POLICY_ADMIN',   'Propose commit policies'),
  ('SYSTEM_ADMIN',   'Manage users and grants');

-- Grants are bitemporal, so who could do what on any past date can be reconstructed.
CREATE TABLE mdm.user_role (
  user_id         uuid NOT NULL REFERENCES mdm.app_user,
  role_code       text NOT NULL REFERENCES mdm.role,
  hierarchy_id    uuid REFERENCES mdm.hierarchy,       -- NULL = every hierarchy
  top_node_id     uuid REFERENCES mdm.node,            -- NULL = the whole hierarchy; otherwise this sub-tree
  granted_by      uuid NOT NULL REFERENCES mdm.app_user,
  valid_period    daterange NOT NULL,
  recorded_period tstzrange NOT NULL DEFAULT tstzrange(now(), NULL),
  CHECK (top_node_id IS NULL OR hierarchy_id IS NOT NULL),
  CHECK (granted_by <> user_id),                       -- nobody grants themselves a role
  EXCLUDE USING gist (
    user_id WITH =, role_code WITH =,
    (coalesce(hierarchy_id, '00000000-0000-0000-0000-000000000000'::uuid)) WITH =,
    (coalesce(top_node_id,  '00000000-0000-0000-0000-000000000000'::uuid)) WITH =,
    valid_period WITH &&
  ) WHERE (upper_inf(recorded_period))
);
CREATE INDEX ON mdm.user_role (user_id) WHERE upper_inf(recorded_period);

-- Roles are for people. AI agents and the system actor act only through their own guarded paths.
CREATE FUNCTION mdm.trg_user_role_human_only() RETURNS trigger
LANGUAGE plpgsql SET search_path = mdm, public AS $$
BEGIN
  IF (SELECT kind FROM mdm.app_user WHERE user_id = NEW.user_id) IS DISTINCT FROM 'human' THEN
    RAISE EXCEPTION 'Only human users can hold roles'
      USING ERRCODE = 'N1009', HINT = 'roles.human_only';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER user_role_human_only BEFORE INSERT ON mdm.user_role
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_user_role_human_only();
CREATE TRIGGER user_role_guard BEFORE UPDATE OR DELETE ON mdm.user_role
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_bitemporal_guard();
CREATE TRIGGER user_role_audit AFTER INSERT OR UPDATE OR DELETE ON mdm.user_role
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_audit_row();

-- -----------------------------------------------------------------------------
-- Idempotency keys (ADR-015): a replayed POST returns the stored response. Not governed data; pruned after
-- IDEMPOTENCY_KEY_TTL by a scheduled delete.
-- -----------------------------------------------------------------------------
CREATE TABLE mdm.idempotency_key (
  actor_id        uuid NOT NULL,
  idem_key        text NOT NULL CHECK (length(idem_key) BETWEEN 8 AND 128),
  request_hash    char(64) NOT NULL,
  response_status int NOT NULL,
  response_body   jsonb NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (actor_id, idem_key)
);
-- UPDATE: a key is reserved first (response_status 0 = in progress), then completed with the response.
GRANT INSERT, UPDATE, DELETE ON mdm.idempotency_key TO nexus_api;
