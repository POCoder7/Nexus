-- =============================================================================
-- V14 — Governed access changes (ADR-042 D3; Phase 5 LLD §19.4, increment 5-4b).
-- Groups, their scopes, their members and direct role grants change only through change requests: an ADMIN proposes,
-- a different ADMIN decides in core mode, and apply writes the rows as nexus_apply. Nothing else writes them (the API
-- login has SELECT only; bootstrap rows are the database owner's, in the seed).
-- Replaces wf.membership_change (V9, Phase 2), which wrote mdm from wf and so broke the layer rule once groups moved.
-- =============================================================================
SET search_path = mdm, public;

-- The eight actions (V1 change_action). Every check below asks this one question.
CREATE FUNCTION mdm.is_access_action(p_action mdm.change_action)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_action IN ('create_group', 'update_group', 'add_group_scope', 'end_group_scope',
                      'add_group_member', 'remove_group_member', 'grant_role', 'revoke_role')
$$;

-- The user an item gives access to (a new membership or a direct grant), by login; NULL for the other actions.
CREATE FUNCTION mdm.access_subject(p_action mdm.change_action, p_payload jsonb)
RETURNS uuid LANGUAGE sql STABLE SET search_path = mdm, public AS $$
  SELECT u.user_id FROM mdm.app_user u
  WHERE p_action IN ('add_group_member', 'grant_role') AND u.login = p_payload ->> 'user'
$$;

-- -----------------------------------------------------------------------------
-- Proposing: who and in what form (checked as each item is written, so a draft never holds an item it could not keep)
-- -----------------------------------------------------------------------------
-- * the requester holds ADMIN for every hierarchy (N1033);
-- * access items carry no hierarchy, node or property, and are never mixed with other actions in one request, so the
--   request is decided in core mode by an ADMIN and never by a hierarchy's approvers or a workflow (N2237);
-- * not in a sandbox: a sandbox previews hierarchy data, not who may do what (N2237);
-- * nobody proposes access for themselves (N1034; the granted_by CHECKs are the backstop at apply).
CREATE FUNCTION mdm.trg_change_item_access() RETURNS trigger
LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE
  cr      mdm.change_request%ROWTYPE;
  v_mixed boolean;
BEGIN
  SELECT * INTO cr FROM mdm.change_request WHERE change_request_id = NEW.change_request_id;
  SELECT EXISTS (SELECT 1 FROM mdm.change_item ci
                 WHERE ci.change_request_id = NEW.change_request_id AND ci.change_item_id <> NEW.change_item_id
                   AND mdm.is_access_action(ci.action) <> mdm.is_access_action(NEW.action))
    INTO v_mixed;
  IF v_mixed THEN
    RAISE EXCEPTION 'Access changes and other changes cannot share a change request'
      USING ERRCODE = 'N2237', HINT = 'access.mixed_request';
  END IF;
  IF NOT mdm.is_access_action(NEW.action) THEN
    RETURN NEW;
  END IF;
  IF NOT mdm.holds_role(cr.requester_id, 'ADMIN', mdm.business_today()) THEN
    RAISE EXCEPTION 'Only an ADMIN can propose access changes'
      USING ERRCODE = 'N1033', HINT = 'access.not_admin';
  END IF;
  IF cr.origin = 'sandbox' THEN
    RAISE EXCEPTION 'Access changes cannot be made in a sandbox'
      USING ERRCODE = 'N2237', HINT = 'access.not_in_sandbox';
  END IF;
  IF NEW.hierarchy_id IS NOT NULL OR NEW.node_id IS NOT NULL OR NEW.target_parent_id IS NOT NULL OR NEW.property_id IS NOT NULL THEN
    RAISE EXCEPTION 'An access change names its group, user and scope in its payload, not in the item''s hierarchy or node'
      USING ERRCODE = 'N2237', HINT = 'access.item_shape';
  END IF;
  IF mdm.access_subject(NEW.action, NEW.payload) = cr.requester_id THEN
    RAISE EXCEPTION 'Nobody can propose a membership or a role for themselves'
      USING ERRCODE = 'N1034', HINT = 'access.self_grant';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER change_item_access BEFORE INSERT OR UPDATE ON mdm.change_item
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_change_item_access();

-- -----------------------------------------------------------------------------
-- Deciding (on the request row, so every path that decides is covered)
-- -----------------------------------------------------------------------------
-- * the decider holds ADMIN for every hierarchy (N1033); maker-checker (N1001) and human-only (N1002) are the V1
--   trigger's, as for any request;
-- * an approver is not given access by the request they approve (N1034);
-- * a change to POLICY_APPROVERS membership is approved by someone in it (N1020, the V9 rule kept);
-- * an access request is never governed by a workflow (N2237), so no stage, group or commit policy can decide it.
CREATE FUNCTION mdm.trg_cr_access_decision() RETURNS trigger
LANGUAGE plpgsql SET search_path = mdm, public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM mdm.change_item ci
                 WHERE ci.change_request_id = NEW.change_request_id AND mdm.is_access_action(ci.action)) THEN
    RETURN NEW;
  END IF;
  IF NEW.governed_by_workflow THEN
    RAISE EXCEPTION 'An access change is decided by an ADMIN, not through a workflow'
      USING ERRCODE = 'N2237', HINT = 'access.core_only';
  END IF;
  IF NEW.status IN ('approved', 'rejected') AND OLD.status IS DISTINCT FROM NEW.status THEN
    IF NOT mdm.holds_role(NEW.decided_by, 'ADMIN', mdm.business_today()) THEN
      RAISE EXCEPTION 'Only an ADMIN can decide access changes'
        USING ERRCODE = 'N1033', HINT = 'access.not_admin';
    END IF;
    IF NEW.status = 'approved' THEN
      IF EXISTS (SELECT 1 FROM mdm.change_item ci
                 WHERE ci.change_request_id = NEW.change_request_id
                   AND mdm.access_subject(ci.action, ci.payload) = NEW.decided_by) THEN
        RAISE EXCEPTION 'Nobody can approve a membership or a role for themselves'
          USING ERRCODE = 'N1034', HINT = 'access.self_grant';
      END IF;
      IF EXISTS (SELECT 1 FROM mdm.change_item ci
                 WHERE ci.change_request_id = NEW.change_request_id
                   AND ci.action IN ('add_group_member', 'remove_group_member')
                   AND ci.payload ->> 'group' = 'POLICY_APPROVERS')
         AND NOT mdm.is_member((SELECT group_id FROM mdm.user_group WHERE group_code = 'POLICY_APPROVERS'),
                               NEW.decided_by, mdm.business_today()) THEN
        RAISE EXCEPTION 'A change to POLICY_APPROVERS needs an approver who is in it'
          USING ERRCODE = 'N1020', HINT = 'policy.not_approver';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER cr_access_decision BEFORE UPDATE OF status, decided_by, governed_by_workflow ON mdm.change_request
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_cr_access_decision();

-- -----------------------------------------------------------------------------
-- Applying (handlers follow apply_fact: rows are closed and re-stated, never edited; D is the request's effective date)
-- -----------------------------------------------------------------------------
-- Payload keys (camelCase, codes rather than ids, so a request can create a group and fill it in order):
--   create_group        {group, name, description?, role?}
--   update_group        {group, name?, description?, active?, role?}      role only while the group is empty
--   add_group_scope     {group, hierarchy?, topNodeId?, categories?, validTo?}    no hierarchy = every hierarchy
--   end_group_scope     {group, hierarchy?, topNodeId?}
--   add_group_member    {group, user, validTo?}
--   remove_group_member {group, user}
--   grant_role          {user, role, hierarchy?, topNodeId?, categories?, validTo?}
--   revoke_role         {user, role, hierarchy?, topNodeId?}

CREATE FUNCTION mdm.apply_access_invalid(p_item mdm.change_item, p_message text)
RETURNS void LANGUAGE plpgsql SET search_path = mdm, public AS $$
BEGIN
  RAISE EXCEPTION 'Item %: %', p_item.seq, p_message USING ERRCODE = 'N2105', HINT = 'apply.item_invalid';
END $$;

-- Who may do what is never back-dated (the V9 rule, N2233): the history of entitlements stays what it was.
CREATE FUNCTION mdm.apply_access_not_past(p_item mdm.change_item)
RETURNS void LANGUAGE plpgsql SET search_path = mdm, public AS $$
BEGIN
  IF current_setting('mdm.apply_date')::date < mdm.business_today() THEN
    RAISE EXCEPTION 'Item %: an access change cannot take effect before today (%)', p_item.seq, mdm.business_today()
      USING ERRCODE = 'N2233', HINT = 'access.backdated';
  END IF;
END $$;

CREATE FUNCTION mdm.apply_access_group(p_item mdm.change_item)
RETURNS uuid LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE v uuid;
BEGIN
  SELECT group_id INTO v FROM mdm.user_group WHERE group_code = p_item.payload ->> 'group';
  IF v IS NULL THEN
    PERFORM mdm.apply_access_invalid(p_item, format('unknown group %s', coalesce(p_item.payload ->> 'group', '(none)')));
  END IF;
  RETURN v;
END $$;

CREATE FUNCTION mdm.apply_access_user(p_item mdm.change_item)
RETURNS uuid LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE v uuid;
BEGIN
  SELECT user_id INTO v FROM mdm.app_user WHERE login = p_item.payload ->> 'user';
  IF v IS NULL THEN
    PERFORM mdm.apply_access_invalid(p_item, format('unknown user %s', coalesce(p_item.payload ->> 'user', '(none)')));
  END IF;
  RETURN v;
END $$;

-- The scope key of a group scope or a direct grant: hierarchy (NULL = every hierarchy) and sub-tree top.
CREATE FUNCTION mdm.apply_access_scope(p_item mdm.change_item)
RETURNS jsonb LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE v_h uuid; v_top uuid := (p_item.payload ->> 'topNodeId')::uuid;
BEGIN
  IF p_item.payload ->> 'hierarchy' IS NOT NULL THEN
    SELECT hierarchy_id INTO v_h FROM mdm.hierarchy WHERE hierarchy_code = p_item.payload ->> 'hierarchy';
    IF v_h IS NULL THEN
      PERFORM mdm.apply_access_invalid(p_item, format('unknown hierarchy %s', p_item.payload ->> 'hierarchy'));
    END IF;
  ELSIF v_top IS NOT NULL THEN
    PERFORM mdm.apply_access_invalid(p_item, 'a sub-tree scope needs its hierarchy');
  END IF;
  RETURN jsonb_build_object('hierarchy_id', v_h, 'top_node_id', v_top);
END $$;

CREATE FUNCTION mdm.apply_access_current(p_table text, p_key jsonb)
RETURNS boolean LANGUAGE plpgsql STABLE SET search_path = mdm, public AS $$
DECLARE v_where text; v boolean;
BEGIN
  SELECT string_agg(CASE WHEN p_key ->> col IS NULL THEN format('t.%I IS NULL', col)
                         ELSE format('t.%1$I = k.%1$I', col) END, ' AND ')
    INTO v_where FROM jsonb_object_keys(p_key) AS col;
  EXECUTE format($q$SELECT EXISTS (SELECT 1 FROM mdm.%1$I t, jsonb_populate_record(NULL::mdm.%1$I, $1) k
                    WHERE %2$s AND t.valid_period @> $2 AND upper_inf(t.recorded_period))$q$, p_table, v_where)
    INTO v USING p_key, current_setting('mdm.apply_date')::date;
  RETURN v;
END $$;

CREATE FUNCTION mdm.apply_access_requester()
RETURNS uuid LANGUAGE sql STABLE SET search_path = mdm, public AS $$
  SELECT requester_id FROM mdm.change_request WHERE change_request_id = current_setting('mdm.change_request_id')::uuid
$$;

CREATE FUNCTION mdm.apply_create_group(p_item mdm.change_item)
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
BEGIN
  IF coalesce(p_item.payload ->> 'group', '') = '' OR coalesce(p_item.payload ->> 'name', '') = '' THEN
    PERFORM mdm.apply_access_invalid(p_item, 'a new group needs a code and a name');
  END IF;
  IF EXISTS (SELECT 1 FROM mdm.user_group WHERE group_code = p_item.payload ->> 'group') THEN
    PERFORM mdm.apply_access_invalid(p_item, format('group %s already exists', p_item.payload ->> 'group'));
  END IF;
  INSERT INTO mdm.user_group (group_code, name, description, role_code)
  VALUES (p_item.payload ->> 'group', p_item.payload ->> 'name', p_item.payload ->> 'description', p_item.payload ->> 'role');
  RETURN 1;
END $$;

-- A group's role is what its scopes grant to its members, so it changes only while the group has neither.
CREATE FUNCTION mdm.apply_update_group(p_item mdm.change_item)
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE g mdm.user_group%ROWTYPE;
BEGIN
  SELECT * INTO g FROM mdm.user_group WHERE group_id = mdm.apply_access_group(p_item) FOR UPDATE;
  IF p_item.payload ? 'role' AND (p_item.payload ->> 'role') IS DISTINCT FROM g.role_code
     AND (EXISTS (SELECT 1 FROM mdm.user_group_scope s WHERE s.group_id = g.group_id AND upper_inf(s.recorded_period)
                  AND (upper_inf(s.valid_period) OR upper(s.valid_period) > mdm.business_today()))
          OR EXISTS (SELECT 1 FROM mdm.user_group_member m WHERE m.group_id = g.group_id AND upper_inf(m.recorded_period)
                     AND (upper_inf(m.valid_period) OR upper(m.valid_period) > mdm.business_today()))) THEN
    PERFORM mdm.apply_access_invalid(p_item, format('group %s has scopes or members; end them before changing its role', g.group_code));
  END IF;
  UPDATE mdm.user_group
  SET name        = CASE WHEN p_item.payload ? 'name' THEN p_item.payload ->> 'name' ELSE name END,
      description = CASE WHEN p_item.payload ? 'description' THEN p_item.payload ->> 'description' ELSE description END,
      is_active   = CASE WHEN p_item.payload ? 'active' THEN (p_item.payload ->> 'active')::boolean ELSE is_active END,
      role_code   = CASE WHEN p_item.payload ? 'role' THEN p_item.payload ->> 'role' ELSE role_code END
  WHERE group_id = g.group_id;
  RETURN 1;
END $$;

CREATE FUNCTION mdm.apply_add_group_scope(p_item mdm.change_item)
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE v_key jsonb;
BEGIN
  PERFORM mdm.apply_access_not_past(p_item);
  v_key := jsonb_build_object('group_id', mdm.apply_access_group(p_item)) || mdm.apply_access_scope(p_item);
  IF mdm.apply_access_current('user_group_scope', v_key) THEN
    PERFORM mdm.apply_access_invalid(p_item, 'the group already has this scope');
  END IF;
  RETURN mdm.apply_fact('user_group_scope', NULL, v_key,
           jsonb_build_object('category_codes', p_item.payload -> 'categories'),
           (p_item.payload ->> 'validTo')::date, false);
END $$;

CREATE FUNCTION mdm.apply_end_group_scope(p_item mdm.change_item)
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE v_key jsonb;
BEGIN
  PERFORM mdm.apply_access_not_past(p_item);
  v_key := jsonb_build_object('group_id', mdm.apply_access_group(p_item)) || mdm.apply_access_scope(p_item);
  IF NOT mdm.apply_access_current('user_group_scope', v_key) THEN
    RAISE EXCEPTION 'Item %: the group has no such scope on %', p_item.seq, current_setting('mdm.apply_date')
      USING ERRCODE = 'N2231', HINT = 'access.nothing_to_end';
  END IF;
  RETURN mdm.apply_fact('user_group_scope', NULL, v_key, NULL, NULL, true);
END $$;

CREATE FUNCTION mdm.apply_add_group_member(p_item mdm.change_item)
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE v_key jsonb;
BEGIN
  PERFORM mdm.apply_access_not_past(p_item);
  v_key := jsonb_build_object('group_id', mdm.apply_access_group(p_item), 'user_id', mdm.apply_access_user(p_item));
  IF mdm.apply_access_current('user_group_member', v_key) THEN
    RAISE EXCEPTION 'Item %: % is already in %', p_item.seq, p_item.payload ->> 'user', p_item.payload ->> 'group'
      USING ERRCODE = 'N2232', HINT = 'access.already_member';
  END IF;
  RETURN mdm.apply_fact('user_group_member', NULL, v_key,
           jsonb_build_object('granted_by', mdm.apply_access_requester()), (p_item.payload ->> 'validTo')::date, false);
END $$;

CREATE FUNCTION mdm.apply_remove_group_member(p_item mdm.change_item)
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE v_key jsonb;
BEGIN
  PERFORM mdm.apply_access_not_past(p_item);
  v_key := jsonb_build_object('group_id', mdm.apply_access_group(p_item), 'user_id', mdm.apply_access_user(p_item));
  IF NOT mdm.apply_access_current('user_group_member', v_key) THEN
    RAISE EXCEPTION 'Item %: % is not in % on %', p_item.seq, p_item.payload ->> 'user', p_item.payload ->> 'group',
      current_setting('mdm.apply_date') USING ERRCODE = 'N2231', HINT = 'access.nothing_to_end';
  END IF;
  RETURN mdm.apply_fact('user_group_member', NULL, v_key, NULL, NULL, true);
END $$;

CREATE FUNCTION mdm.apply_grant_role(p_item mdm.change_item)
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE v_key jsonb;
BEGIN
  PERFORM mdm.apply_access_not_past(p_item);
  v_key := jsonb_build_object('user_id', mdm.apply_access_user(p_item), 'role_code', p_item.payload ->> 'role')
           || mdm.apply_access_scope(p_item);
  IF NOT EXISTS (SELECT 1 FROM mdm.role WHERE role_code = p_item.payload ->> 'role') THEN
    PERFORM mdm.apply_access_invalid(p_item, format('unknown role %s', coalesce(p_item.payload ->> 'role', '(none)')));
  END IF;
  IF mdm.apply_access_current('user_role', v_key) THEN
    RAISE EXCEPTION 'Item %: % already holds this grant', p_item.seq, p_item.payload ->> 'user'
      USING ERRCODE = 'N2232', HINT = 'access.already_granted';
  END IF;
  RETURN mdm.apply_fact('user_role', NULL, v_key,
           jsonb_build_object('category_codes', p_item.payload -> 'categories', 'granted_by', mdm.apply_access_requester()),
           (p_item.payload ->> 'validTo')::date, false);
END $$;

CREATE FUNCTION mdm.apply_revoke_role(p_item mdm.change_item)
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE v_key jsonb;
BEGIN
  PERFORM mdm.apply_access_not_past(p_item);
  v_key := jsonb_build_object('user_id', mdm.apply_access_user(p_item), 'role_code', p_item.payload ->> 'role')
           || mdm.apply_access_scope(p_item);
  IF NOT mdm.apply_access_current('user_role', v_key) THEN
    RAISE EXCEPTION 'Item %: % holds no such grant on %', p_item.seq, p_item.payload ->> 'user', current_setting('mdm.apply_date')
      USING ERRCODE = 'N2231', HINT = 'access.nothing_to_end';
  END IF;
  RETURN mdm.apply_fact('user_role', NULL, v_key, NULL, NULL, true);
END $$;

-- The V1 dispatch plus the eight access handlers (CREATE OR REPLACE keeps its owner and privileges).
CREATE OR REPLACE FUNCTION mdm.apply_item(p_item mdm.change_item)
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
BEGIN
  RETURN CASE p_item.action
    WHEN 'add_node'            THEN apply_add_node(p_item)
    WHEN 'insert_node'         THEN apply_insert_node(p_item)
    WHEN 'move_node'           THEN apply_move_node(p_item)
    WHEN 'remove_node'         THEN apply_remove_node(p_item)
    WHEN 'delete_node'         THEN apply_delete_node(p_item)
    WHEN 'update_node'         THEN apply_update_node(p_item)
    WHEN 'add_hierarchy'       THEN apply_add_hierarchy(p_item)
    WHEN 'set_property'        THEN apply_set_property(p_item)
    WHEN 'clear_property'      THEN apply_clear_property(p_item)
    WHEN 'create_group'        THEN apply_create_group(p_item)
    WHEN 'update_group'        THEN apply_update_group(p_item)
    WHEN 'add_group_scope'     THEN apply_add_group_scope(p_item)
    WHEN 'end_group_scope'     THEN apply_end_group_scope(p_item)
    WHEN 'add_group_member'    THEN apply_add_group_member(p_item)
    WHEN 'remove_group_member' THEN apply_remove_group_member(p_item)
    WHEN 'grant_role'          THEN apply_grant_role(p_item)
    WHEN 'revoke_role'         THEN apply_revoke_role(p_item)
    ELSE apply_not_available(p_item)
  END;
END $$;

-- -----------------------------------------------------------------------------
-- Privileges: apply (nexus_apply) is the only writer of these tables. The API login keeps SELECT (V7 defaults).
-- -----------------------------------------------------------------------------
GRANT INSERT, UPDATE (recorded_period) ON mdm.user_group_scope, mdm.user_group_member, mdm.user_role TO nexus_apply;
GRANT INSERT (group_code, name, description, role_code), UPDATE (name, description, is_active, role_code)
  ON mdm.user_group TO nexus_apply;

-- The new helpers, like V7's: run inside apply_change_request with nexus_apply's rights; nobody else may call them.
DO $$
DECLARE f regprocedure;
BEGIN
  FOR f IN SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'mdm' AND p.proname LIKE 'apply\_%' AND p.proname <> 'apply_change_request' LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO nexus_apply', f);
  END LOOP;
END $$;
