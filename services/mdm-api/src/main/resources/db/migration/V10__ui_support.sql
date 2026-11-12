-- =============================================================================
-- V10 — UI support (Phase 3 LLD §4): user preferences and in-tree search.
-- Not governed data: nothing here is a bitemporal fact, and nothing reaches mdm facts from here.
-- =============================================================================

SET search_path = mdm, public;

-- One row per user (OD-27 start page). The API writes only the caller's own row (MeController); preferences are
-- server-side so they follow the user between browsers and never sit in browser storage (LLD §9).
CREATE TABLE mdm.user_preference (
  user_id           uuid PRIMARY KEY REFERENCES mdm.app_user,
  start_page        text NOT NULL DEFAULT 'home' CHECK (start_page IN ('home', 'hierarchies', 'worklist')),
  last_hierarchy_id uuid REFERENCES mdm.hierarchy,
  density           text NOT NULL DEFAULT 'compact' CHECK (density IN ('compact', 'comfortable')),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE mdm.user_preference IS 'UI preferences per user (Phase 3, OD-27). Not governed; the API writes only the caller''s row.';

-- SELECT comes from the default privileges in V7; only the API may write, and only these columns.
GRANT INSERT (user_id, start_page, last_hierarchy_id, density, updated_at),
      UPDATE (start_page, last_hierarchy_id, density, updated_at) ON mdm.user_preference TO nexus_api;

-- HIE-12 in-tree search by name or description (OD-21: PostgreSQL search first). pg_trgm is PostgreSQL contrib and a
-- trusted extension; the trigram GIN indexes serve ILIKE '%text%' on the current belief only.
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;

CREATE INDEX node_attr_name_trgm ON mdm.node_attr USING gin (node_name public.gin_trgm_ops)
  WHERE upper_inf(recorded_period);
CREATE INDEX node_attr_description_trgm ON mdm.node_attr USING gin (description public.gin_trgm_ops)
  WHERE upper_inf(recorded_period) AND description IS NOT NULL;

-- PRP-09 / SEC-03 edit side (ADR-036): a grant may be limited to property categories. NULL = every category, so every
-- existing grant keeps its meaning. The API checks it on set_property / clear_property (EntitlementService).
ALTER TABLE mdm.user_role ADD COLUMN category_codes text[]
  CHECK (category_codes IS NULL OR cardinality(category_codes) > 0);
COMMENT ON COLUMN mdm.user_role.category_codes IS
  'Property categories this grant covers for property edits (ADR-036); NULL = all categories.';
