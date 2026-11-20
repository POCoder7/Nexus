-- =============================================================================
-- V17 — Ledgers for the hackathon CSV load (ADR-046 D4; Phase 4 LLD §17.4; increment H-3). Each increment of the
-- hackathon load has its own migration file, so a kept demo database only ever gains new files (V16 is H-2).
-- =============================================================================
SET search_path = mdm, public;

-- -----------------------------------------------------------------------------
-- H-3 Ledgers (ADR-046 D4, LLD §17.4): reference data for finance attributes (LEDGER_ID) and rule VR17 (the ledger's
-- currency). Configuration like property_definition: not bitemporal, audited, readable by every role. Written by the
-- API for an ADMIN (PUT /admin/ledgers/{id}) and, from H-6, by the loader under an approved load run. Never deleted:
-- a ledger in use is retired with is_active = false, so values that name it keep their meaning.
-- -----------------------------------------------------------------------------
CREATE TABLE mdm.ledger (
  ledger_id       text PRIMARY KEY CHECK (ledger_id ~ '^\S{1,20}$'),
  ledger_name     text NOT NULL CHECK (length(btrim(ledger_name)) > 0),
  currency_code   char(3) NOT NULL CHECK (currency_code ~ '^[A-Z]{3}$'),
  finance_country text NOT NULL CHECK (length(btrim(finance_country)) > 0),
  is_active       boolean NOT NULL DEFAULT true
);
CREATE TRIGGER ledger_audit AFTER INSERT OR UPDATE OR DELETE ON mdm.ledger
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_audit_row();
GRANT INSERT, UPDATE ON mdm.ledger TO nexus_api;               -- no DELETE: retire instead
