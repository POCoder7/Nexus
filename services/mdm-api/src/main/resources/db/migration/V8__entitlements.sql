-- =============================================================================
-- Nexus — 08: ENTITLEMENTS, SETTINGS, IDEMPOTENCY (Phase 1: ADR-022, ADR-018/CR-01, ADR-015)
-- =============================================================================
SET search_path = mdm, public;

-- mdm.system_setting and the business-day functions live in V1 (moved there in Phase 2: the workflow layer's day
-- boundaries in V6 need them, Phase 2 LLD §4.1).

-- -----------------------------------------------------------------------------
-- Roles and grants (ADR-022). Roles are data; what each role may do is fixed in code (Permission matrix).
-- -----------------------------------------------------------------------------
-- The five roles (ADR-042 D1). holder_kind says who may hold the role: people, or service accounts (CONSUMER only).
CREATE TABLE mdm.role (
  role_code   text PRIMARY KEY,
  description text NOT NULL,
  holder_kind text NOT NULL DEFAULT 'human' CHECK (holder_kind IN ('human', 'service'))
);
INSERT INTO mdm.role VALUES
  ('VIEWER',   'Browse hierarchies, properties, versions and audit; no changes', 'human'),
  ('EDITOR',   'Viewer, plus draft changes, sandboxes and imports, and submit requests', 'human'),
  ('APPROVER', 'Viewer, plus decide submitted requests (never their own)', 'human'),
  ('ADMIN',    'Everything: users, groups, definitions, workflow and policy administration, versions, workflow override, publish', 'human'),
  ('CONSUMER', 'Read published output only (service accounts)', 'service');
ALTER TABLE mdm.user_group ADD FOREIGN KEY (role_code) REFERENCES mdm.role;   -- the group table is in V1

-- Direct grants (for exceptions, ADR-042 C-2; groups are the usual way). Bitemporal, so who could do what on any past
-- date can be reconstructed.
CREATE TABLE mdm.user_role (
  user_id           uuid NOT NULL REFERENCES mdm.app_user,
  role_code         text NOT NULL REFERENCES mdm.role,
  hierarchy_id      uuid REFERENCES mdm.hierarchy,     -- NULL = every hierarchy
  top_node_id       uuid REFERENCES mdm.node,          -- NULL = the whole hierarchy; otherwise this sub-tree
  -- PRP-09 / SEC-03 (ADR-036): the property categories this grant covers for property edits; NULL = every category
  category_codes    text[] CHECK (category_codes IS NULL OR cardinality(category_codes) > 0),
  granted_by        uuid NOT NULL REFERENCES mdm.app_user,
  valid_period      daterange NOT NULL,
  recorded_period   tstzrange NOT NULL DEFAULT tstzrange(now(), NULL),
  change_request_id uuid REFERENCES mdm.change_request,  -- the request that wrote the row (5-4b); NULL for bootstrap rows
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

-- What a group's role covers (ADR-042 D2): every hierarchy, a hierarchy or a sub-tree, optionally limited to property
-- categories, with the same history rules as direct grants.
CREATE TABLE mdm.user_group_scope (
  group_id          uuid NOT NULL REFERENCES mdm.user_group,
  hierarchy_id      uuid REFERENCES mdm.hierarchy,     -- NULL = every hierarchy
  top_node_id       uuid REFERENCES mdm.node,          -- NULL = the whole hierarchy
  category_codes    text[] CHECK (category_codes IS NULL OR cardinality(category_codes) > 0),
  valid_period      daterange NOT NULL,
  recorded_period   tstzrange NOT NULL DEFAULT tstzrange(now(), NULL),
  change_request_id uuid REFERENCES mdm.change_request,
  CHECK (top_node_id IS NULL OR hierarchy_id IS NOT NULL),
  EXCLUDE USING gist (
    group_id WITH =,
    (coalesce(hierarchy_id, '00000000-0000-0000-0000-000000000000'::uuid)) WITH =,
    (coalesce(top_node_id,  '00000000-0000-0000-0000-000000000000'::uuid)) WITH =,
    valid_period WITH &&
  ) WHERE (upper_inf(recorded_period))
);
CREATE INDEX ON mdm.user_group_scope (group_id) WHERE upper_inf(recorded_period);

-- Who may hold a role (ADR-042 D5; N1009 kept from Phase 1): AI agents and the system actor hold none and act only
-- through their own guarded paths; people hold every role but CONSUMER; service accounts hold only CONSUMER (N1032).
-- Checked for a direct grant, for joining a group with a role, and for giving a group with members a role. A group
-- without a role grants nothing, so anyone may be listed in one (the workflow's own guards decide what members may do,
-- e.g. N1010 and N1002 refuse an AI agent's claim and decision). An unknown role is left to the foreign key to report.
CREATE FUNCTION mdm.role_holder_problem(p_user uuid, p_role text)
RETURNS text LANGUAGE sql STABLE SET search_path = mdm, public AS $$
  SELECT CASE
           WHEN u.kind IN ('ai_agent', 'system_feed') THEN 'N1009'
           WHEN r.holder_kind IS DISTINCT FROM u.kind::text THEN 'N1032'
         END
  FROM mdm.app_user u JOIN mdm.role r ON r.role_code = p_role
  WHERE u.user_id = p_user
$$;

CREATE FUNCTION mdm.trg_role_holder() RETURNS trigger
LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE
  v_role    text;
  v_problem text;
  v_user    uuid;
BEGIN
  IF TG_TABLE_NAME = 'user_group' THEN
    -- a group's role must suit every current member
    SELECT mdm.role_holder_problem(m.user_id, NEW.role_code), m.user_id INTO v_problem, v_user
    FROM mdm.user_group_member m
    WHERE m.group_id = NEW.group_id AND upper_inf(m.recorded_period) AND mdm.role_holder_problem(m.user_id, NEW.role_code) IS NOT NULL
    LIMIT 1;
  ELSE
    -- separate branches: a PL/pgSQL expression resolves every NEW field it names, and user_role has no group_id
    IF TG_TABLE_NAME = 'user_role' THEN
      v_role := NEW.role_code;
    ELSE
      SELECT g.role_code INTO v_role FROM mdm.user_group g WHERE g.group_id = NEW.group_id;
    END IF;
    v_user := NEW.user_id;
    v_problem := mdm.role_holder_problem(NEW.user_id, v_role);
  END IF;
  IF v_problem = 'N1009' THEN
    RAISE EXCEPTION 'Only people and service accounts can hold roles or join groups (user %)', v_user
      USING ERRCODE = 'N1009', HINT = 'roles.human_only';
  ELSIF v_problem = 'N1032' THEN
    RAISE EXCEPTION 'User % cannot hold this role: people hold every role but CONSUMER, service accounts only CONSUMER', v_user
      USING ERRCODE = 'N1032', HINT = 'roles.holder_kind';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER user_role_holder BEFORE INSERT ON mdm.user_role
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_role_holder();
CREATE TRIGGER user_group_member_holder BEFORE INSERT ON mdm.user_group_member
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_role_holder();
CREATE TRIGGER user_group_holder BEFORE INSERT OR UPDATE OF role_code ON mdm.user_group
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_role_holder();
CREATE TRIGGER user_role_guard BEFORE UPDATE OR DELETE ON mdm.user_role
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_bitemporal_guard();
CREATE TRIGGER user_role_audit AFTER INSERT OR UPDATE OR DELETE ON mdm.user_role
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_audit_row();
CREATE TRIGGER user_group_scope_guard BEFORE UPDATE OR DELETE ON mdm.user_group_scope
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_bitemporal_guard();
CREATE TRIGGER user_group_scope_audit AFTER INSERT OR UPDATE OR DELETE ON mdm.user_group_scope
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_audit_row();

-- A user's effective grants on a business date, as recorded at p_rec (ADR-042 D2): their direct grants, plus one grant
-- per (group with a role they belong to × that group's scope). The valid period is when both the membership and the
-- scope hold. Every entitlement check reads this, in SQL (holds_role) and in the API (EntitlementService).
CREATE FUNCTION mdm.effective_grants(p_user uuid, p_on date, p_rec timestamptz DEFAULT now())
RETURNS TABLE (role_code text, hierarchy_id uuid, top_node_id uuid, category_codes text[], valid_period daterange,
               source_group_id uuid)
LANGUAGE sql STABLE SET search_path = mdm, public AS $$
  SELECT ur.role_code, ur.hierarchy_id, ur.top_node_id, ur.category_codes, ur.valid_period, NULL::uuid
  FROM mdm.user_role ur
  WHERE ur.user_id = p_user AND ur.valid_period @> p_on AND ur.recorded_period @> p_rec
  UNION ALL
  SELECT g.role_code, s.hierarchy_id, s.top_node_id, s.category_codes, m.valid_period * s.valid_period, g.group_id
  FROM mdm.user_group_member m
  JOIN mdm.user_group g ON g.group_id = m.group_id AND g.is_active AND g.role_code IS NOT NULL
  JOIN mdm.user_group_scope s ON s.group_id = g.group_id AND s.valid_period @> p_on AND s.recorded_period @> p_rec
  WHERE m.user_id = p_user AND m.valid_period @> p_on AND m.recorded_period @> p_rec
$$;

-- True if an active user holds the role for every hierarchy on the date, directly or through a group. The database's
-- own checks of administration rights use it (workflow, policies, versions).
CREATE FUNCTION mdm.holds_role(p_user uuid, p_role text, p_on date)
RETURNS boolean LANGUAGE sql STABLE SET search_path = mdm, public AS $$
  SELECT EXISTS (SELECT 1 FROM mdm.effective_grants(p_user, p_on) g JOIN mdm.app_user u ON u.user_id = p_user
                 WHERE g.role_code = p_role AND g.hierarchy_id IS NULL AND u.is_active)
$$;

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
