-- Test-only migration (classpath:db/testroles, never packaged): a login in role nexus_api, so every API test runs
-- with the same privileges as the application in production (ADR-014). The password is a fixed test value for a
-- throwaway Testcontainers database; it is not a secret.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nexus_api_test') THEN
    CREATE ROLE nexus_api_test LOGIN PASSWORD 'nexus_api_test' IN ROLE nexus_api;
  END IF;
END $$;

-- The workflow worker's login in tests (role nexus_wf), so the worker's steps run with the worker's privileges.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nexus_wf_test') THEN
    CREATE ROLE nexus_wf_test LOGIN PASSWORD 'nexus_wf_test' IN ROLE nexus_wf;
  END IF;
END $$;
