-- =============================================================================
-- V12 — Sandboxes (NEW-08; ADR-028; Phase 5 LLD §4, §7.1, P-28 Overlay by trial apply).
--
-- A sandbox is a draft change request of kind 'sandbox' (V1). Its overlay is stored here: for each fact table, the
-- rows that applying its items would close ('-') and insert ('+'). mdm.refresh_sandbox_delta (5-1b) rebuilds the
-- overlay from the items by a trial apply that is always rolled back.
--
-- The overlay is derived, not governed data: it is never read as a fact, it is rebuilt rather than edited, and it
-- goes when its sandbox is deleted. Nothing here references wf (CLAUDE.md rule 3).
--
-- Each row carries its valid period. Apply never edits a fact in place: it closes the current row and re-states the
-- parts that stay true, so one item can close one row and insert two for the same key (a move is a closed placement,
-- the old placement up to the effective date and the new one from it). Reads at an as-of date need the period to
-- choose between them, and the key needs it to tell them apart (built in 5-1a; the LLD §4 sketch had no period).
-- =============================================================================

SET search_path = mdm, public;

-- Placements (hierarchy_relationship). No foreign keys to facts: a sandbox may describe rows for a hierarchy that
-- only its own add_hierarchy item would create, and such rows exist only inside the rolled-back trial.
CREATE TABLE mdm.sandbox_delta_relationship (
  sandbox_id     uuid NOT NULL REFERENCES mdm.change_request ON DELETE CASCADE,
  hierarchy_id   uuid NOT NULL,
  parent_node_id uuid NOT NULL,
  child_node_id  uuid NOT NULL,
  is_primary     boolean NOT NULL,
  sort_order     numeric NOT NULL,
  valid_period   daterange NOT NULL,
  op             char(1) NOT NULL CHECK (op IN ('+', '-')),
  PRIMARY KEY (sandbox_id, hierarchy_id, parent_node_id, child_node_id, valid_period, op)
);
-- The primary key serves the overlay children page (sandbox, hierarchy, parent: LLD §7.2), so the separate index the
-- LLD lists is its prefix. This one serves node detail: where a node is placed in the sandbox.
CREATE INDEX ON mdm.sandbox_delta_relationship (sandbox_id, hierarchy_id, child_node_id);

-- Node attributes (node_attr).
CREATE TABLE mdm.sandbox_delta_node_attr (
  sandbox_id      uuid NOT NULL REFERENCES mdm.change_request ON DELETE CASCADE,
  node_id         uuid NOT NULL,
  node_name       text NOT NULL,
  description     text,
  is_active       boolean NOT NULL,
  allows_children boolean NOT NULL,
  valid_period    daterange NOT NULL,
  op              char(1) NOT NULL CHECK (op IN ('+', '-')),
  PRIMARY KEY (sandbox_id, node_id, valid_period, op)
);

-- Stored property values (property_value). hierarchy_key is the value's hierarchy, or the zero uuid for a global
-- value: the same key property_value's exclusion constraint uses, so it can be part of the primary key.
CREATE TABLE mdm.sandbox_delta_value (
  sandbox_id    uuid NOT NULL REFERENCES mdm.change_request ON DELETE CASCADE,
  node_id       uuid NOT NULL,
  property_id   uuid NOT NULL,
  hierarchy_key uuid NOT NULL,
  value         jsonb NOT NULL,
  valid_period  daterange NOT NULL,
  op            char(1) NOT NULL CHECK (op IN ('+', '-')),
  PRIMARY KEY (sandbox_id, node_id, property_id, hierarchy_key, valid_period, op)
);

-- -----------------------------------------------------------------------------
-- Privileges (ADR-014). Every role reads the overlay (V7 default privileges). Only nexus_apply writes it: it owns
-- the trial apply that computes it (5-1b), and it only ever deletes a sandbox's rows and inserts them again.
-- -----------------------------------------------------------------------------
GRANT INSERT, DELETE ON mdm.sandbox_delta_relationship, mdm.sandbox_delta_node_attr, mdm.sandbox_delta_value TO nexus_apply;

-- =============================================================================
-- 5-1b: the overlay by trial apply (LLD §6.2, §7.1–§7.3; P-28).
--
-- One implementation of the change semantics serves apply, validation and the overlay: a sandbox's items run through
-- the Phase 1 handlers (mdm.apply_item) in a block that is always rolled back, and the capture hook records every row
-- they close ('-') and insert ('+'). What a read shows is: the facts as recorded at the sandbox's base, minus every
-- key the delta touches on the date, plus the '+' rows on the date. That is exact while the base is the current state;
-- when another request has changed a fact since, the item that relied on it fails its stale-base check and becomes a
-- conflict, and rebase moves the base.
-- =============================================================================

INSERT INTO mdm.system_setting VALUES
  ('sandbox_incremental_threshold', '1000',
   'Above this many items, a new last item that touches only a node no earlier item touched is trial-applied on its own '
   'and appended to the overlay, instead of a full refresh (Phase 5 LLD §7.1)');

-- The capture hook (V1 has a no-op body; apply_insert and apply_fact call it). It acts only inside a sandbox's own
-- trial: mdm.sandbox_capture names the sandbox, and the request being applied is that sandbox. A committed apply and
-- a validation clear the setting, so they never write an overlay.
-- A row the trial closes that the trial itself inserted (a later item changing what an earlier item wrote) is not a
-- change to the base: its '+' row is removed instead of recording a '-', so the overlay holds only the net effect.
CREATE OR REPLACE FUNCTION mdm.apply_capture(p_table text, p_op text, p_row jsonb)
RETURNS void LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE
  v_s     uuid := nullif(current_setting('mdm.sandbox_capture', true), '')::uuid;
  v_own   boolean;
  v_valid daterange := (p_row ->> 'valid_period')::daterange;
BEGIN
  IF v_s IS NULL OR v_s IS DISTINCT FROM nullif(current_setting('mdm.change_request_id', true), '')::uuid THEN
    RETURN;
  END IF;
  v_own := p_op = '-' AND coalesce((p_row ->> 'change_request_id')::uuid = v_s, false);

  IF p_table = 'hierarchy_relationship' THEN
    IF v_own THEN
      DELETE FROM mdm.sandbox_delta_relationship d
      WHERE d.sandbox_id = v_s AND d.op = '+' AND d.hierarchy_id = (p_row ->> 'hierarchy_id')::uuid
        AND d.parent_node_id = (p_row ->> 'parent_node_id')::uuid AND d.child_node_id = (p_row ->> 'child_node_id')::uuid
        AND d.valid_period = v_valid;
    ELSE
      INSERT INTO mdm.sandbox_delta_relationship
        (sandbox_id, hierarchy_id, parent_node_id, child_node_id, is_primary, sort_order, valid_period, op)
      VALUES (v_s, (p_row ->> 'hierarchy_id')::uuid, (p_row ->> 'parent_node_id')::uuid, (p_row ->> 'child_node_id')::uuid,
              (p_row ->> 'is_primary')::boolean, (p_row ->> 'sort_order')::numeric, v_valid, p_op);
    END IF;
  ELSIF p_table = 'node_attr' THEN
    IF v_own THEN
      DELETE FROM mdm.sandbox_delta_node_attr d
      WHERE d.sandbox_id = v_s AND d.op = '+' AND d.node_id = (p_row ->> 'node_id')::uuid AND d.valid_period = v_valid;
    ELSE
      INSERT INTO mdm.sandbox_delta_node_attr
        (sandbox_id, node_id, node_name, description, is_active, allows_children, valid_period, op)
      VALUES (v_s, (p_row ->> 'node_id')::uuid, p_row ->> 'node_name', p_row ->> 'description',
              (p_row ->> 'is_active')::boolean, (p_row ->> 'allows_children')::boolean, v_valid, p_op);
    END IF;
  ELSIF p_table = 'property_value' THEN
    IF v_own THEN
      DELETE FROM mdm.sandbox_delta_value d
      WHERE d.sandbox_id = v_s AND d.op = '+' AND d.node_id = (p_row ->> 'node_id')::uuid
        AND d.property_id = (p_row ->> 'property_id')::uuid
        AND d.hierarchy_key = coalesce((p_row ->> 'hierarchy_id')::uuid, '00000000-0000-0000-0000-000000000000'::uuid)
        AND d.valid_period = v_valid;
    ELSE
      INSERT INTO mdm.sandbox_delta_value (sandbox_id, node_id, property_id, hierarchy_key, value, valid_period, op)
      VALUES (v_s, (p_row ->> 'node_id')::uuid, (p_row ->> 'property_id')::uuid,
              coalesce((p_row ->> 'hierarchy_id')::uuid, '00000000-0000-0000-0000-000000000000'::uuid),
              p_row -> 'value', v_valid, p_op);          -- -> keeps a stored JSON null (an explicit blank)
    END IF;
  END IF;
  -- Other tables are not overlaid: the hierarchy row add_hierarchy inserts is a plain insert, and no action writes
  -- identifiers or legal-entity profiles yet.
END $$;

-- -----------------------------------------------------------------------------
-- Helpers (invoker)
-- -----------------------------------------------------------------------------

-- Every sandbox operation starts here: the request exists, is a sandbox, and is still a draft.
CREATE FUNCTION mdm.sandbox_require(p_cr mdm.change_request, p_id uuid)
RETURNS void LANGUAGE plpgsql STABLE SET search_path = mdm, public AS $$
BEGIN
  IF p_cr.change_request_id IS NULL THEN
    RAISE EXCEPTION 'Change request % not found', p_id USING ERRCODE = 'N2102', HINT = 'change_request.not_found';
  END IF;
  IF p_cr.kind <> 'sandbox' THEN
    RAISE EXCEPTION 'Change request % is not a sandbox', p_id USING ERRCODE = 'N2303', HINT = 'sandbox.not_sandbox';
  END IF;
  IF p_cr.status <> 'draft' THEN
    RAISE EXCEPTION 'Sandbox % is % and has no overlay', p_id, p_cr.status USING ERRCODE = 'N2303', HINT = 'sandbox.not_draft';
  END IF;
END $$;

-- The recorded instant the overlay reads the facts at.
CREATE FUNCTION mdm.sandbox_base(p_sandbox uuid)
RETURNS timestamptz LANGUAGE sql STABLE SET search_path = mdm, public AS $$
  SELECT c.sandbox_base_recorded_at FROM mdm.change_request c WHERE c.change_request_id = p_sandbox
$$;

-- The three overlay readers below compute the same thing for one table: the base rows recorded at p_recorded, minus
-- every row whose key has a delta row on the date (the trial closed it, or re-stated it), plus the '+' rows on the
-- date. For placements, a '+' primary placement of a child also hides the child's base primary placement, so a child
-- never shows two primary parents even when the base is behind the current state.

CREATE FUNCTION mdm.sandbox_children_of(p_sandbox uuid, p_recorded timestamptz, p_hierarchy uuid, p_parent uuid, p_as_of date)
RETURNS TABLE (child_node_id uuid, is_primary boolean, sort_order numeric)
LANGUAGE sql STABLE SET search_path = mdm, public AS $$
  SELECT r.child_node_id, r.is_primary, r.sort_order
  FROM mdm.hierarchy_relationship r
  WHERE r.hierarchy_id = p_hierarchy AND r.parent_node_id = p_parent
    AND r.valid_period @> p_as_of AND r.recorded_period @> p_recorded
    AND NOT EXISTS (SELECT 1 FROM mdm.sandbox_delta_relationship x
                    WHERE x.sandbox_id = p_sandbox AND x.hierarchy_id = p_hierarchy AND x.parent_node_id = p_parent
                      AND x.child_node_id = r.child_node_id AND x.valid_period @> p_as_of)
    AND NOT (r.is_primary AND EXISTS (SELECT 1 FROM mdm.sandbox_delta_relationship x
                                      WHERE x.sandbox_id = p_sandbox AND x.hierarchy_id = p_hierarchy
                                        AND x.child_node_id = r.child_node_id AND x.op = '+' AND x.is_primary
                                        AND x.valid_period @> p_as_of))
  UNION ALL
  SELECT x.child_node_id, x.is_primary, x.sort_order
  FROM mdm.sandbox_delta_relationship x
  WHERE x.sandbox_id = p_sandbox AND x.hierarchy_id = p_hierarchy AND x.parent_node_id = p_parent
    AND x.op = '+' AND x.valid_period @> p_as_of
$$;

CREATE FUNCTION mdm.sandbox_parent_of(p_sandbox uuid, p_recorded timestamptz, p_hierarchy uuid, p_node uuid, p_as_of date)
RETURNS TABLE (parent_node_id uuid, is_primary boolean, sort_order numeric)
LANGUAGE sql STABLE SET search_path = mdm, public AS $$
  SELECT r.parent_node_id, r.is_primary, r.sort_order
  FROM mdm.hierarchy_relationship r
  WHERE r.hierarchy_id = p_hierarchy AND r.child_node_id = p_node
    AND r.valid_period @> p_as_of AND r.recorded_period @> p_recorded
    AND NOT EXISTS (SELECT 1 FROM mdm.sandbox_delta_relationship x
                    WHERE x.sandbox_id = p_sandbox AND x.hierarchy_id = p_hierarchy AND x.parent_node_id = r.parent_node_id
                      AND x.child_node_id = p_node AND x.valid_period @> p_as_of)
    AND NOT (r.is_primary AND EXISTS (SELECT 1 FROM mdm.sandbox_delta_relationship x
                                      WHERE x.sandbox_id = p_sandbox AND x.hierarchy_id = p_hierarchy
                                        AND x.child_node_id = p_node AND x.op = '+' AND x.is_primary
                                        AND x.valid_period @> p_as_of))
  UNION ALL
  SELECT x.parent_node_id, x.is_primary, x.sort_order
  FROM mdm.sandbox_delta_relationship x
  WHERE x.sandbox_id = p_sandbox AND x.hierarchy_id = p_hierarchy AND x.child_node_id = p_node
    AND x.op = '+' AND x.valid_period @> p_as_of
$$;

CREATE FUNCTION mdm.sandbox_attr_of(p_sandbox uuid, p_recorded timestamptz, p_node uuid, p_as_of date)
RETURNS TABLE (node_name text, description text, is_active boolean, allows_children boolean)
LANGUAGE sql STABLE SET search_path = mdm, public AS $$
  SELECT a.node_name, a.description, a.is_active, a.allows_children
  FROM mdm.node_attr a
  WHERE a.node_id = p_node AND a.valid_period @> p_as_of AND a.recorded_period @> p_recorded
    AND NOT EXISTS (SELECT 1 FROM mdm.sandbox_delta_node_attr x
                    WHERE x.sandbox_id = p_sandbox AND x.node_id = p_node AND x.valid_period @> p_as_of)
  UNION ALL
  SELECT x.node_name, x.description, x.is_active, x.allows_children
  FROM mdm.sandbox_delta_node_attr x
  WHERE x.sandbox_id = p_sandbox AND x.node_id = p_node AND x.op = '+' AND x.valid_period @> p_as_of
$$;

-- Stored values of one node (hierarchy_id NULL for a global value), the same way.
CREATE FUNCTION mdm.sandbox_value_of(p_sandbox uuid, p_recorded timestamptz, p_node uuid, p_as_of date)
RETURNS TABLE (property_id uuid, hierarchy_id uuid, value jsonb)
LANGUAGE sql STABLE SET search_path = mdm, public AS $$
  SELECT pv.property_id, pv.hierarchy_id, pv.value
  FROM mdm.property_value pv
  WHERE pv.node_id = p_node AND pv.valid_period @> p_as_of AND pv.recorded_period @> p_recorded
    AND NOT EXISTS (SELECT 1 FROM mdm.sandbox_delta_value x
                    WHERE x.sandbox_id = p_sandbox AND x.node_id = p_node AND x.property_id = pv.property_id
                      AND x.hierarchy_key = coalesce(pv.hierarchy_id, '00000000-0000-0000-0000-000000000000'::uuid)
                      AND x.valid_period @> p_as_of)
  UNION ALL
  SELECT x.property_id, nullif(x.hierarchy_key, '00000000-0000-0000-0000-000000000000'::uuid), x.value
  FROM mdm.sandbox_delta_value x
  WHERE x.sandbox_id = p_sandbox AND x.node_id = p_node AND x.op = '+' AND x.valid_period @> p_as_of
$$;

-- -----------------------------------------------------------------------------
-- The trial (invoker; run only by nexus_apply's functions below)
-- -----------------------------------------------------------------------------
-- Runs the sandbox's items (or only p_items) in seq order as of its effective date, as its requester, inside a block
-- that is always rolled back (N9999). The first pass runs straight through. If an item hits a rule failure, a second,
-- careful pass runs each item in its own subtransaction, records each failure {seq, change_item_id, error_code,
-- message, detail} and carries on, so a failing item is left out of the overlay and the items after it still show.
-- Faults (anything that is not a rule failure) are raised. With p_capture, the overlay rows the trial produced are
-- read out of the delta tables before the rollback and returned as jsonb arrays (rel, attr, val); the delta tables
-- themselves are left as they were. There is no item-limit check here: 5-1a checks the limit as items are added.
CREATE FUNCTION mdm.sandbox_trial(p_sandbox uuid, p_items uuid[] DEFAULT NULL, p_capture boolean DEFAULT true,
                                  OUT failures jsonb, OUT rel jsonb, OUT attr jsonb, OUT val jsonb)
LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE
  cr       mdm.change_request%ROWTYPE;
  it       mdm.change_item%ROWTYPE;
  v_pass   int;
  v_state  text;
  v_msg    text;
  v_detail text;
  v_dj     jsonb;
BEGIN
  SELECT * INTO cr FROM mdm.change_request c WHERE c.change_request_id = p_sandbox;
  PERFORM mdm.sandbox_require(cr, p_sandbox);
  failures := '[]';

  FOR v_pass IN 1 .. 2 LOOP
    BEGIN                                                        -- the trial: always rolled back (N9999)
      -- Settings made here are undone with the block, so the caller's settings are back afterwards.
      PERFORM set_config('mdm.actor_id', cr.requester_id::text, true);
      PERFORM set_config('mdm.change_request_id', p_sandbox::text, true);
      PERFORM set_config('mdm.apply_date', cr.effective_from::text, true);
      PERFORM set_config('mdm.sandbox_capture', CASE WHEN p_capture THEN p_sandbox::text ELSE '' END, true);
      IF p_capture THEN                                          -- the capture starts from nothing
        DELETE FROM mdm.sandbox_delta_relationship d WHERE d.sandbox_id = p_sandbox;
        DELETE FROM mdm.sandbox_delta_node_attr d WHERE d.sandbox_id = p_sandbox;
        DELETE FROM mdm.sandbox_delta_value d WHERE d.sandbox_id = p_sandbox;
      END IF;

      FOR it IN SELECT i.* FROM mdm.apply_items_of(cr) i
                WHERE p_items IS NULL OR i.change_item_id = ANY (p_items) ORDER BY i.seq LOOP
        IF v_pass = 1 THEN
          PERFORM mdm.apply_item(it);
        ELSE
          BEGIN                                                  -- careful pass: one subtransaction per item
            PERFORM mdm.apply_item(it);
          EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
            IF NOT mdm.apply_is_rule_failure(v_state) THEN
              RAISE;
            END IF;
            v_dj := NULL;                                        -- the stale-base check puts JSON in DETAIL (ADR-020)
            IF v_detail LIKE '{%' THEN
              BEGIN
                v_dj := v_detail::jsonb;
              EXCEPTION WHEN OTHERS THEN
                v_dj := to_jsonb(v_detail);
              END;
            ELSIF nullif(v_detail, '') IS NOT NULL THEN
              v_dj := to_jsonb(v_detail);
            END IF;
            failures := failures || jsonb_build_array(jsonb_build_object('seq', it.seq, 'change_item_id', it.change_item_id,
                          'error_code', v_state, 'message', v_msg, 'detail', v_dj));
          END;
        END IF;
      END LOOP;

      IF p_capture THEN                                          -- read the capture out before it is rolled back
        SELECT coalesce(jsonb_agg(to_jsonb(d) - 'sandbox_id'), '[]') INTO rel
        FROM mdm.sandbox_delta_relationship d WHERE d.sandbox_id = p_sandbox;
        SELECT coalesce(jsonb_agg(to_jsonb(d) - 'sandbox_id'), '[]') INTO attr
        FROM mdm.sandbox_delta_node_attr d WHERE d.sandbox_id = p_sandbox;
        SELECT coalesce(jsonb_agg(to_jsonb(d) - 'sandbox_id'), '[]') INTO val
        FROM mdm.sandbox_delta_value d WHERE d.sandbox_id = p_sandbox;
      END IF;
      RAISE EXCEPTION 'trial rollback' USING ERRCODE = 'N9999';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
      IF v_state = 'N9999' THEN
        RETURN;                                                  -- done: the first pass applied every item, or the careful pass ran
      ELSIF v_pass = 1 AND mdm.apply_is_rule_failure(v_state) THEN
        NULL;                                                    -- an item failed: run the careful pass
      ELSE
        RAISE;
      END IF;
    END;
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- Refresh, conflicts, rebase (SECURITY DEFINER, owned by nexus_apply: the fact writer, whose trial is always
-- rolled back; the API calls them)
-- -----------------------------------------------------------------------------

-- Rebuilds a sandbox's overlay from its items and returns the items that failed, in seq order (LLD §6.2, §7.1).
-- Called after every item change, in the same transaction. p_new_item names the item just added: when it is the
-- last item of a sandbox above sandbox_incremental_threshold, is an update_node / set_property / clear_property, and
-- its node has no attribute or value in the overlay yet, it does not depend on any earlier item, so it is tried on
-- its own and appended. The result is kept only if it applied and its node name collides with no name already in the
-- overlay (the trial against the base cannot see the overlay's names); otherwise, and in every other case, the
-- overlay is rebuilt in full. The incremental path reports only the new item's outcome.
CREATE FUNCTION mdm.refresh_sandbox_delta(p_sandbox uuid, p_new_item uuid DEFAULT NULL)
RETURNS TABLE (seq int, change_item_id uuid, error_code text, message text, detail jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = mdm, public AS $$
#variable_conflict use_column
DECLARE
  cr          mdm.change_request%ROWTYPE;
  it          mdm.change_item%ROWTYPE;
  t           record;
  v_threshold int;
BEGIN
  SELECT * INTO cr FROM mdm.change_request c WHERE c.change_request_id = p_sandbox FOR UPDATE;   -- one refresh at a time
  PERFORM mdm.sandbox_require(cr, p_sandbox);

  IF p_new_item IS NOT NULL THEN
    SELECT * INTO it FROM mdm.change_item i WHERE i.change_item_id = p_new_item AND i.change_request_id = p_sandbox;
    SELECT coalesce(max(s.setting_value::int), 1000) INTO v_threshold
    FROM mdm.system_setting s WHERE s.setting_key = 'sandbox_incremental_threshold';
    IF it.change_item_id IS NOT NULL
       AND it.action IN ('update_node', 'set_property', 'clear_property')
       AND (SELECT count(*) FROM mdm.change_item i WHERE i.change_request_id = p_sandbox) > v_threshold
       AND NOT EXISTS (SELECT 1 FROM mdm.change_item i WHERE i.change_request_id = p_sandbox AND i.seq > it.seq)
       AND NOT EXISTS (SELECT 1 FROM mdm.sandbox_delta_node_attr x WHERE x.sandbox_id = p_sandbox AND x.node_id = it.node_id)
       AND NOT EXISTS (SELECT 1 FROM mdm.sandbox_delta_value x WHERE x.sandbox_id = p_sandbox AND x.node_id = it.node_id) THEN
      SELECT * INTO t FROM mdm.sandbox_trial(p_sandbox, ARRAY[p_new_item], true);
      IF jsonb_array_length(t.failures) = 0
         AND NOT EXISTS (SELECT 1 FROM jsonb_populate_recordset(NULL::mdm.sandbox_delta_node_attr, t.attr) n
                         JOIN mdm.sandbox_delta_node_attr x
                           ON x.sandbox_id = p_sandbox AND x.op = '+' AND x.node_name = n.node_name
                          AND x.node_id <> n.node_id AND x.valid_period && n.valid_period
                         WHERE n.op = '+') THEN
        INSERT INTO mdm.sandbox_delta_node_attr
          (sandbox_id, node_id, node_name, description, is_active, allows_children, valid_period, op)
        SELECT p_sandbox, n.node_id, n.node_name, n.description, n.is_active, n.allows_children, n.valid_period, n.op
        FROM jsonb_populate_recordset(NULL::mdm.sandbox_delta_node_attr, t.attr) n;
        INSERT INTO mdm.sandbox_delta_value (sandbox_id, node_id, property_id, hierarchy_key, value, valid_period, op)
        SELECT p_sandbox, (e ->> 'node_id')::uuid, (e ->> 'property_id')::uuid, (e ->> 'hierarchy_key')::uuid,
               e -> 'value', (e ->> 'valid_period')::daterange, e ->> 'op'
        FROM jsonb_array_elements(t.val) e;
        RETURN;                                                  -- these actions write no placements
      END IF;
    END IF;
  END IF;

  SELECT * INTO t FROM mdm.sandbox_trial(p_sandbox, NULL, true);
  DELETE FROM mdm.sandbox_delta_relationship d WHERE d.sandbox_id = p_sandbox;
  DELETE FROM mdm.sandbox_delta_node_attr d WHERE d.sandbox_id = p_sandbox;
  DELETE FROM mdm.sandbox_delta_value d WHERE d.sandbox_id = p_sandbox;
  INSERT INTO mdm.sandbox_delta_relationship
    (sandbox_id, hierarchy_id, parent_node_id, child_node_id, is_primary, sort_order, valid_period, op)
  SELECT p_sandbox, r.hierarchy_id, r.parent_node_id, r.child_node_id, r.is_primary, r.sort_order, r.valid_period, r.op
  FROM jsonb_populate_recordset(NULL::mdm.sandbox_delta_relationship, t.rel) r;
  INSERT INTO mdm.sandbox_delta_node_attr
    (sandbox_id, node_id, node_name, description, is_active, allows_children, valid_period, op)
  SELECT p_sandbox, n.node_id, n.node_name, n.description, n.is_active, n.allows_children, n.valid_period, n.op
  FROM jsonb_populate_recordset(NULL::mdm.sandbox_delta_node_attr, t.attr) n;
  INSERT INTO mdm.sandbox_delta_value (sandbox_id, node_id, property_id, hierarchy_key, value, valid_period, op)
  SELECT p_sandbox, (e ->> 'node_id')::uuid, (e ->> 'property_id')::uuid, (e ->> 'hierarchy_key')::uuid,
         e -> 'value', (e ->> 'valid_period')::daterange, e ->> 'op'       -- -> keeps a stored JSON null
  FROM jsonb_array_elements(t.val) e;

  RETURN QUERY
  SELECT (f ->> 'seq')::int, (f ->> 'change_item_id')::uuid, f ->> 'error_code', f ->> 'message', f -> 'detail'
  FROM jsonb_array_elements(t.failures) f
  ORDER BY (f ->> 'seq')::int;
END $$;

-- The items whose expected base no longer holds (LLD §7.3): the stale-base check (N3001) of a trial without capture.
-- Each names the field, what the item expected, what is there now, and the request that changed it: the latest
-- current row for that fact recorded after the sandbox's base (NULL when there is none, for example after a rebase).
-- The trial writes and rolls back, so this needs a read-write transaction. Only the first stale field of an item is
-- reported, as apply stops at it.
CREATE FUNCTION mdm.sandbox_conflicts(p_sandbox uuid)
RETURNS TABLE (seq int, change_item_id uuid, action text, field text, expected jsonb, actual jsonb,
               changed_by_request uuid, changed_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = mdm, public AS $$
#variable_conflict use_column
DECLARE
  cr mdm.change_request%ROWTYPE;
  t  record;
BEGIN
  SELECT * INTO cr FROM mdm.change_request c WHERE c.change_request_id = p_sandbox FOR SHARE;    -- no item changes meanwhile
  PERFORM mdm.sandbox_require(cr, p_sandbox);
  SELECT * INTO t FROM mdm.sandbox_trial(p_sandbox, NULL, false);

  RETURN QUERY
  SELECT i.seq, i.change_item_id, i.action::text, f -> 'detail' ->> 'field', f -> 'detail' -> 'expected',
         f -> 'detail' -> 'actual', w.change_request_id, w.recorded_at
  FROM jsonb_array_elements(t.failures) f
  JOIN mdm.change_item i ON i.change_item_id = (f ->> 'change_item_id')::uuid
  LEFT JOIN LATERAL (
    SELECT c.change_request_id, c.recorded_at FROM (
      SELECT a.change_request_id, lower(a.recorded_period) AS recorded_at
      FROM mdm.node_attr a
      WHERE f -> 'detail' ->> 'field' IN ('name', 'description') AND a.node_id = i.node_id
        AND upper_inf(a.recorded_period) AND lower(a.recorded_period) > cr.sandbox_base_recorded_at
      UNION ALL
      SELECT r.change_request_id, lower(r.recorded_period)
      FROM mdm.hierarchy_relationship r
      WHERE f -> 'detail' ->> 'field' IN ('parentId', 'parentIds') AND r.hierarchy_id = i.hierarchy_id
        AND r.child_node_id = i.node_id
        AND upper_inf(r.recorded_period) AND lower(r.recorded_period) > cr.sandbox_base_recorded_at
      UNION ALL
      SELECT pv.change_request_id, lower(pv.recorded_period)
      FROM mdm.property_value pv JOIN mdm.property_definition pd ON pd.property_id = pv.property_id
      WHERE f -> 'detail' ->> 'field' IN ('present', 'value') AND pv.node_id = i.node_id AND pv.property_id = i.property_id
        AND pv.hierarchy_id IS NOT DISTINCT FROM CASE WHEN pd.scope = 'local' THEN i.hierarchy_id END
        AND upper_inf(pv.recorded_period) AND lower(pv.recorded_period) > cr.sandbox_base_recorded_at
    ) c
    ORDER BY c.recorded_at DESC, c.change_request_id
    LIMIT 1
  ) w ON true
  WHERE f ->> 'error_code' = 'N3001'
  ORDER BY i.seq;
END $$;

-- Moves the sandbox's base to now and refreshes the overlay (LLD §5): the owner then sees the other requests' changes,
-- and the items that still assume the old state stay flagged until the owner changes them. Only the owner rebases.
CREATE FUNCTION mdm.rebase_sandbox(p_sandbox uuid, p_actor uuid)
RETURNS TABLE (seq int, change_item_id uuid, error_code text, message text, detail jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = mdm, public AS $$
#variable_conflict use_column
DECLARE cr mdm.change_request%ROWTYPE;
BEGIN
  SELECT * INTO cr FROM mdm.change_request c WHERE c.change_request_id = p_sandbox FOR UPDATE;
  PERFORM mdm.sandbox_require(cr, p_sandbox);
  IF cr.requester_id IS DISTINCT FROM p_actor THEN
    RAISE EXCEPTION 'Only the owner can rebase sandbox %', p_sandbox
      USING ERRCODE = 'N1025', HINT = 'change_request.not_requester';
  END IF;
  UPDATE mdm.change_request c SET sandbox_base_recorded_at = now() WHERE c.change_request_id = p_sandbox;
  RETURN QUERY SELECT * FROM mdm.refresh_sandbox_delta(p_sandbox);
END $$;

-- -----------------------------------------------------------------------------
-- Overlay reads (invoker, STABLE: they run with the caller's rights and write nothing). Each marks what differs
-- from the base on the date, so history the trial re-stated unchanged is not marked.
-- -----------------------------------------------------------------------------

-- A page of children (LLD §7.2), keyset-paged by (sort order, name, node id) as the Phase 1 children page.
CREATE FUNCTION mdm.sandbox_children(p_sandbox uuid, p_hierarchy uuid, p_parent uuid, p_as_of date,
                                     p_after_sort numeric DEFAULT NULL, p_after_name text DEFAULT NULL,
                                     p_after_id uuid DEFAULT NULL, p_limit int DEFAULT 100)
RETURNS TABLE (child_node_id uuid, node_name text, description text, is_active boolean, is_primary boolean,
               sort_order numeric, has_children boolean, changed boolean)
LANGUAGE plpgsql STABLE SET search_path = mdm, public AS $$
#variable_conflict use_column
DECLARE
  cr  mdm.change_request%ROWTYPE;
  v_b timestamptz;
BEGIN
  SELECT * INTO cr FROM mdm.change_request c WHERE c.change_request_id = p_sandbox;
  PERFORM mdm.sandbox_require(cr, p_sandbox);
  v_b := cr.sandbox_base_recorded_at;

  RETURN QUERY
  SELECT c.child_node_id, a.node_name, a.description, coalesce(a.is_active, false), c.is_primary, c.sort_order,
         EXISTS (SELECT 1 FROM mdm.sandbox_children_of(p_sandbox, v_b, p_hierarchy, c.child_node_id, p_as_of)),
         NOT EXISTS (SELECT 1 FROM mdm.hierarchy_relationship r
                     WHERE r.hierarchy_id = p_hierarchy AND r.parent_node_id = p_parent AND r.child_node_id = c.child_node_id
                       AND r.is_primary = c.is_primary AND r.sort_order = c.sort_order
                       AND r.valid_period @> p_as_of AND r.recorded_period @> v_b)
         OR (a.node_name, a.description, a.is_active) IS DISTINCT FROM (b.node_name, b.description, b.is_active)
  FROM mdm.sandbox_children_of(p_sandbox, v_b, p_hierarchy, p_parent, p_as_of) c
  LEFT JOIN LATERAL (SELECT * FROM mdm.sandbox_attr_of(p_sandbox, v_b, c.child_node_id, p_as_of) LIMIT 1) a ON true
  LEFT JOIN LATERAL (SELECT n.node_name, n.description, n.is_active FROM mdm.node_attr n
                     WHERE n.node_id = c.child_node_id AND n.valid_period @> p_as_of AND n.recorded_period @> v_b
                     LIMIT 1) b ON true
  WHERE p_after_sort IS NULL
     OR (c.sort_order, coalesce(a.node_name, ''), c.child_node_id) > (p_after_sort, coalesce(p_after_name, ''), p_after_id)
  ORDER BY c.sort_order, coalesce(a.node_name, ''), c.child_node_id
  LIMIT p_limit;
END $$;

-- Node detail: the node's attributes on the date, if it exists then.
CREATE FUNCTION mdm.sandbox_node(p_sandbox uuid, p_node uuid, p_as_of date)
RETURNS TABLE (node_name text, description text, is_active boolean, allows_children boolean, changed boolean)
LANGUAGE plpgsql STABLE SET search_path = mdm, public AS $$
#variable_conflict use_column
DECLARE
  cr  mdm.change_request%ROWTYPE;
  v_b timestamptz;
BEGIN
  SELECT * INTO cr FROM mdm.change_request c WHERE c.change_request_id = p_sandbox;
  PERFORM mdm.sandbox_require(cr, p_sandbox);
  v_b := cr.sandbox_base_recorded_at;

  RETURN QUERY
  SELECT a.node_name, a.description, a.is_active, a.allows_children,
         (a.node_name, a.description, a.is_active, a.allows_children)
           IS DISTINCT FROM (b.node_name, b.description, b.is_active, b.allows_children)
  FROM mdm.sandbox_attr_of(p_sandbox, v_b, p_node, p_as_of) a
  LEFT JOIN LATERAL (SELECT n.node_name, n.description, n.is_active, n.allows_children FROM mdm.node_attr n
                     WHERE n.node_id = p_node AND n.valid_period @> p_as_of AND n.recorded_period @> v_b
                     LIMIT 1) b ON true;
END $$;

-- Where the node is placed in one hierarchy on the date.
CREATE FUNCTION mdm.sandbox_placements(p_sandbox uuid, p_hierarchy uuid, p_node uuid, p_as_of date)
RETURNS TABLE (parent_node_id uuid, is_primary boolean, sort_order numeric, changed boolean)
LANGUAGE plpgsql STABLE SET search_path = mdm, public AS $$
#variable_conflict use_column
DECLARE
  cr  mdm.change_request%ROWTYPE;
  v_b timestamptz;
BEGIN
  SELECT * INTO cr FROM mdm.change_request c WHERE c.change_request_id = p_sandbox;
  PERFORM mdm.sandbox_require(cr, p_sandbox);
  v_b := cr.sandbox_base_recorded_at;

  RETURN QUERY
  SELECT p.parent_node_id, p.is_primary, p.sort_order,
         NOT EXISTS (SELECT 1 FROM mdm.hierarchy_relationship r
                     WHERE r.hierarchy_id = p_hierarchy AND r.parent_node_id = p.parent_node_id AND r.child_node_id = p_node
                       AND r.is_primary = p.is_primary AND r.sort_order = p.sort_order
                       AND r.valid_period @> p_as_of AND r.recorded_period @> v_b)
  FROM mdm.sandbox_parent_of(p_sandbox, v_b, p_hierarchy, p_node, p_as_of) p
  ORDER BY p.is_primary DESC, p.parent_node_id;
END $$;

-- Resolved properties (V3 rules: stored -> inherited from the nearest primary ancestor -> default), over the overlay's
-- placements and stored values. Derived values come from the base (their expressions read the facts). changed
-- compares with node_properties_resolved at the base, so a value inherited differently after a move is marked too.
CREATE FUNCTION mdm.sandbox_node_properties(p_sandbox uuid, p_node uuid, p_hierarchy uuid, p_as_of date)
RETURNS TABLE (property_id uuid, value jsonb, provenance text, source_node_id uuid, changed boolean)
LANGUAGE plpgsql STABLE SET search_path = mdm, public AS $$
#variable_conflict use_column
DECLARE
  cr  mdm.change_request%ROWTYPE;
  v_b timestamptz;
BEGIN
  SELECT * INTO cr FROM mdm.change_request c WHERE c.change_request_id = p_sandbox;
  PERFORM mdm.sandbox_require(cr, p_sandbox);
  v_b := cr.sandbox_base_recorded_at;

  RETURN QUERY
  WITH RECURSIVE
  defs AS (
    SELECT d.*, CASE WHEN d.scope = 'local' THEN p_hierarchy END AS value_hierarchy
    FROM mdm.property_definition d
    WHERE d.scope = 'global' OR p_hierarchy IS NOT NULL
  ),
  anc(node_id, dist) AS (                                  -- one walk up the overlay's primary placements
    SELECT p.parent_node_id, 1
    FROM mdm.sandbox_parent_of(p_sandbox, v_b, p_hierarchy, p_node, p_as_of) p
    WHERE p_hierarchy IS NOT NULL AND p.is_primary
    UNION ALL
    SELECT p.parent_node_id, anc.dist + 1
    FROM anc CROSS JOIN LATERAL mdm.sandbox_parent_of(p_sandbox, v_b, p_hierarchy, anc.node_id, p_as_of) p
    WHERE p.is_primary AND anc.dist < 100                  -- same bound as V3 (D-09)
  ),
  stored AS (
    SELECT v.property_id, v.value
    FROM mdm.sandbox_value_of(p_sandbox, v_b, p_node, p_as_of) v
    JOIN defs d ON d.property_id = v.property_id AND v.hierarchy_id IS NOT DISTINCT FROM d.value_hierarchy
  ),
  inherited AS (
    SELECT DISTINCT ON (v.property_id) v.property_id, v.value, anc.node_id AS source_node_id
    FROM anc
    CROSS JOIN LATERAL mdm.sandbox_value_of(p_sandbox, v_b, anc.node_id, p_as_of) v
    JOIN defs d ON d.property_id = v.property_id AND d.inheritance = 'inherit_from_ancestor'
               AND v.hierarchy_id IS NOT DISTINCT FROM d.value_hierarchy
    ORDER BY v.property_id, anc.dist
  ),
  res AS (
    SELECT d.property_id,
           CASE WHEN d.origin = 'derived' THEN
                  CASE WHEN d.derivation_engine = 'sql'
                       THEN mdm.property_value_asof(p_node, d.property_id, p_hierarchy, p_as_of, v_b) END
                WHEN s.property_id IS NOT NULL THEN s.value
                WHEN i.property_id IS NOT NULL THEN i.value
                ELSE d.default_value END AS value,
           CASE WHEN d.origin = 'derived'        THEN 'derived'
                WHEN s.property_id IS NOT NULL   THEN 'stored'
                WHEN i.property_id IS NOT NULL   THEN 'inherited'
                WHEN d.default_value IS NOT NULL THEN 'default'
                ELSE 'none' END AS provenance,
           CASE WHEN d.origin <> 'derived' AND s.property_id IS NULL THEN i.source_node_id END AS source_node_id
    FROM defs d
    LEFT JOIN stored s    ON s.property_id = d.property_id
    LEFT JOIN inherited i ON i.property_id = d.property_id
  )
  SELECT r.property_id, r.value, r.provenance, r.source_node_id,
         (r.value, r.provenance, r.source_node_id) IS DISTINCT FROM (b.value, b.provenance, b.source_node_id)
  FROM res r
  LEFT JOIN mdm.node_properties_resolved(p_node, p_hierarchy, p_as_of, v_b) b ON b.property_id = r.property_id;
END $$;

-- -----------------------------------------------------------------------------
-- Privileges (ADR-014, ADR-019)
-- -----------------------------------------------------------------------------
GRANT UPDATE (sandbox_base_recorded_at) ON mdm.change_request TO nexus_apply;    -- rebase only

ALTER FUNCTION mdm.refresh_sandbox_delta(uuid, uuid) OWNER TO nexus_apply;
ALTER FUNCTION mdm.sandbox_conflicts(uuid) OWNER TO nexus_apply;
ALTER FUNCTION mdm.rebase_sandbox(uuid, uuid) OWNER TO nexus_apply;

REVOKE EXECUTE ON FUNCTION
  mdm.sandbox_require(mdm.change_request, uuid), mdm.sandbox_base(uuid),
  mdm.sandbox_children_of(uuid, timestamptz, uuid, uuid, date), mdm.sandbox_parent_of(uuid, timestamptz, uuid, uuid, date),
  mdm.sandbox_attr_of(uuid, timestamptz, uuid, date), mdm.sandbox_value_of(uuid, timestamptz, uuid, date),
  mdm.sandbox_trial(uuid, uuid[], boolean),
  mdm.refresh_sandbox_delta(uuid, uuid), mdm.sandbox_conflicts(uuid), mdm.rebase_sandbox(uuid, uuid),
  mdm.sandbox_children(uuid, uuid, uuid, date, numeric, text, uuid, int), mdm.sandbox_node(uuid, uuid, date),
  mdm.sandbox_placements(uuid, uuid, uuid, date), mdm.sandbox_node_properties(uuid, uuid, uuid, date)
FROM PUBLIC;

-- The API refreshes, lists conflicts, rebases and reads; it never runs a trial or the capture hook itself.
GRANT EXECUTE ON FUNCTION
  mdm.refresh_sandbox_delta(uuid, uuid), mdm.sandbox_conflicts(uuid), mdm.rebase_sandbox(uuid, uuid),
  mdm.sandbox_children(uuid, uuid, uuid, date, numeric, text, uuid, int), mdm.sandbox_node(uuid, uuid, date),
  mdm.sandbox_placements(uuid, uuid, uuid, date), mdm.sandbox_node_properties(uuid, uuid, uuid, date),
  mdm.sandbox_require(mdm.change_request, uuid), mdm.sandbox_base(uuid),
  mdm.sandbox_children_of(uuid, timestamptz, uuid, uuid, date), mdm.sandbox_parent_of(uuid, timestamptz, uuid, uuid, date),
  mdm.sandbox_attr_of(uuid, timestamptz, uuid, date), mdm.sandbox_value_of(uuid, timestamptz, uuid, date)
TO nexus_api;
GRANT EXECUTE ON FUNCTION mdm.sandbox_trial(uuid, uuid[], boolean), mdm.sandbox_require(mdm.change_request, uuid)
TO nexus_apply;

-- =============================================================================
-- 5-2: leaving the sandbox (LLD §5, §6.1). Both are SECURITY DEFINER, owned by nexus_apply: the API may change
-- neither kind nor the overlay itself.
-- =============================================================================

INSERT INTO mdm.system_setting VALUES
  ('sandbox_max_active_per_user', '5',
   'How many sandboxes one person may have open (draft) at a time (Phase 5 LLD §4; checked by the API when a sandbox is created)');

-- The first step of submitting a sandbox: refused while any item conflicts (N2301), then the sandbox becomes an
-- ordinary draft request (kind sandbox -> request, the one-way change trg_cr_sandbox_kind allows) and its overlay is
-- cleared, since nothing reads it any more. The caller then validates and submits it as any draft (Phase 1/2), in the
-- same transaction, so a refused validation leaves it a sandbox.
CREATE FUNCTION mdm.convert_sandbox(p_sandbox uuid, p_actor uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = mdm, public AS $$
DECLARE
  cr mdm.change_request%ROWTYPE;
  t  record;
  v_conflicts int;
BEGIN
  SELECT * INTO cr FROM mdm.change_request c WHERE c.change_request_id = p_sandbox FOR UPDATE;
  PERFORM mdm.sandbox_require(cr, p_sandbox);
  IF cr.requester_id IS DISTINCT FROM p_actor THEN
    RAISE EXCEPTION 'Only the owner can submit sandbox %', p_sandbox
      USING ERRCODE = 'N1025', HINT = 'change_request.not_requester';
  END IF;
  SELECT * INTO t FROM mdm.sandbox_trial(p_sandbox, NULL, false);
  SELECT count(*) INTO v_conflicts FROM jsonb_array_elements(t.failures) f WHERE f ->> 'error_code' = 'N3001';
  IF v_conflicts > 0 THEN
    RAISE EXCEPTION 'Sandbox % has % conflicting item(s); rebase it or change those items first', p_sandbox, v_conflicts
      USING ERRCODE = 'N2301', HINT = 'sandbox.has_conflicts';
  END IF;
  DELETE FROM mdm.sandbox_delta_relationship d WHERE d.sandbox_id = p_sandbox;
  DELETE FROM mdm.sandbox_delta_node_attr d WHERE d.sandbox_id = p_sandbox;
  DELETE FROM mdm.sandbox_delta_value d WHERE d.sandbox_id = p_sandbox;
  UPDATE mdm.change_request c SET kind = 'request' WHERE c.change_request_id = p_sandbox;
END $$;

-- Discard: the sandbox is withdrawn (by the Phase 1 function, which re-checks the requester) and its overlay cleared.
CREATE FUNCTION mdm.discard_sandbox(p_sandbox uuid, p_actor uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = mdm, public AS $$
DECLARE cr mdm.change_request%ROWTYPE;
BEGIN
  SELECT * INTO cr FROM mdm.change_request c WHERE c.change_request_id = p_sandbox FOR UPDATE;
  PERFORM mdm.sandbox_require(cr, p_sandbox);
  IF cr.requester_id IS DISTINCT FROM p_actor THEN
    RAISE EXCEPTION 'Only the owner can discard sandbox %', p_sandbox
      USING ERRCODE = 'N1025', HINT = 'change_request.not_requester';
  END IF;
  PERFORM mdm.withdraw_change_request(p_sandbox, p_actor);
  DELETE FROM mdm.sandbox_delta_relationship d WHERE d.sandbox_id = p_sandbox;
  DELETE FROM mdm.sandbox_delta_node_attr d WHERE d.sandbox_id = p_sandbox;
  DELETE FROM mdm.sandbox_delta_value d WHERE d.sandbox_id = p_sandbox;
END $$;

GRANT UPDATE (kind) ON mdm.change_request TO nexus_apply;                     -- convert_sandbox only
GRANT EXECUTE ON FUNCTION mdm.withdraw_change_request(uuid, uuid) TO nexus_apply;
ALTER FUNCTION mdm.convert_sandbox(uuid, uuid) OWNER TO nexus_apply;
ALTER FUNCTION mdm.discard_sandbox(uuid, uuid) OWNER TO nexus_apply;
REVOKE EXECUTE ON FUNCTION mdm.convert_sandbox(uuid, uuid), mdm.discard_sandbox(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mdm.convert_sandbox(uuid, uuid), mdm.discard_sandbox(uuid, uuid) TO nexus_api;
