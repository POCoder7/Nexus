#!/usr/bin/env bash
# Rebuilds a throwaway test database, applies all migrations in order, runs the pgTAP tests.
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose up -d --build db
until docker compose exec -T db pg_isready -U nexus -d postgres >/dev/null 2>&1; do sleep 1; done
sleep 2

docker compose exec -T db psql -U nexus -d postgres \
  -c "DROP DATABASE IF EXISTS nexus_test" -c "CREATE DATABASE nexus_test"

for f in $(ls services/mdm-api/src/main/resources/db/migration/V*__*.sql | sort -V); do
  echo "Applying $f"
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -q -U nexus -d nexus_test -f "/workspace/$f"
done

docker compose exec -T db psql -q -U nexus -d nexus_test -c "CREATE EXTENSION IF NOT EXISTS pgtap"
docker compose exec -T db sh -c "pg_prove -U nexus -d nexus_test /workspace/db/tests/*.sql"
