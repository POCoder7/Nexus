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
