#!/usr/bin/env bash
# Starts the local demo from scratch: a fresh demo database built by the migrations, the hackathon data set (ADR-046)
# loaded through the governed two-ADMIN load, the API (with the in-process workflow worker) and the UI dev server.
# Synthetic data only. Stop it with scripts/demo-stop.sh.
#
#   scripts/demo.sh              recreate the demo database, load the data set, then start everything
#   scripts/demo.sh --keep       keep the existing demo database (Flyway applies any new migrations); nothing loaded
#   scripts/demo.sh --build      rebuild the API jar first (otherwise it is built only when missing)
#   scripts/demo.sh --e2e-seed   load the automated tests' seed (ui/e2e/seed.sql) instead of the data set
#
# The data set comes from data/ (git-ignored), or from the tracked synthetic sample if data/ has no CSV files.
# Overrides (environment): DEMO_DB (nexus_demo), DEMO_API_PORT (8080), DEMO_UI_PORT (4200), DEMO_DATA (data).
# Logs and process ids go to .demo/ (git-ignored).
set -euo pipefail
export MSYS_NO_PATHCONV=1            # Git Bash on Windows: keep /workspace/... paths for docker as written
cd "$(dirname "$0")/.."

DB="${DEMO_DB:-nexus_demo}"
API_PORT="${DEMO_API_PORT:-8080}"
UI_PORT="${DEMO_UI_PORT:-4200}"
KEEP=0
BUILD=0
E2E_SEED=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    --build) BUILD=1 ;;
    --e2e-seed) E2E_SEED=1 ;;
    *) echo "Unknown option $arg (use --keep, --build, --e2e-seed)"; exit 2 ;;
  esac
done
mkdir -p .demo

# Node.js on Windows is usually not on Git Bash's PATH.
if ! command -v npm >/dev/null 2>&1 && [ -x "/c/Program Files/nodejs/node.exe" ]; then
  export PATH="/c/Program Files/nodejs:$PATH"
fi
command -v npm >/dev/null 2>&1 || { echo "npm not found: install Node.js (docs/DEVELOPER_SETUP.md)"; exit 1; }

port_in_use() { curl -s -o /dev/null --max-time 2 "http://localhost:$1/" && return 0 || return 1; }
http_ok() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1")" = 200 ]; }
for p in "$API_PORT" "$UI_PORT"; do
  if port_in_use "$p"; then
    echo "Port $p is already in use. Stop the running demo first: scripts/demo-stop.sh"
    exit 1
  fi
done

echo "== Database"
docker compose up -d --build db
until docker compose exec -T db pg_isready -U nexus -d postgres >/dev/null 2>&1; do sleep 1; done
sleep 2
if [ "$KEEP" = 0 ]; then
  docker compose exec -T db psql -q -U nexus -d postgres \
    -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" -c "CREATE DATABASE $DB"
  echo "Recreated $DB"
else
  docker compose exec -T db psql -q -U nexus -d postgres -tc "SELECT 1 FROM pg_database WHERE datname = '$DB'" | grep -q 1 \
    || docker compose exec -T db psql -q -U nexus -d postgres -c "CREATE DATABASE $DB"
  echo "Keeping $DB"
fi

echo "== API"
JAR=$(ls services/mdm-api/target/mdm-api-*.jar 2>/dev/null | grep -v '\.original$' | head -1 || true)
if [ "$BUILD" = 1 ] || [ -z "$JAR" ]; then
  (cd services/mdm-api && ./mvnw -B -q -DskipTests package)
  JAR=$(ls services/mdm-api/target/mdm-api-*.jar | grep -v '\.original$' | head -1)
fi
JAVA="${JAVA_HOME:+$JAVA_HOME/bin/}java"
# UTC JVM: recorded time is UTC everywhere (ADR-018). The worker runs in the same JVM, so requests move through
# their workflow stages without Camunda (ADR-035).
nohup "$JAVA" -Duser.timezone=UTC -jar "$JAR" --spring.profiles.active=local --server.port="$API_PORT" \
  --spring.datasource.url="jdbc:postgresql://localhost:5432/$DB" --mdm.workflow.worker.enabled=true \
  > .demo/api.log 2>&1 &
echo $! > .demo/api.pid
for i in $(seq 1 90); do
  curl -s "http://localhost:$API_PORT/actuator/health" | grep -q '"UP"' && break
  if ! kill -0 "$(cat .demo/api.pid)" 2>/dev/null; then
    echo "The API stopped while starting. Last lines of .demo/api.log:"; tail -20 .demo/api.log; exit 1
  fi
  sleep 2
done
curl -s "http://localhost:$API_PORT/actuator/health" | grep -q '"UP"' || { echo "The API did not start: see .demo/api.log"; exit 1; }
echo "API up on http://localhost:$API_PORT (migrations applied)"

if [ "$KEEP" = 0 ] && [ "$E2E_SEED" = 1 ]; then
  docker compose exec -T db psql -q -v ON_ERROR_STOP=1 -U nexus -d "$DB" -f /workspace/ui/e2e/seed.sql >/dev/null
  echo "Loaded the synthetic test seed (ui/e2e/seed.sql)"
elif [ "$KEEP" = 0 ]; then
  # Only the hackathon data set (ADR-046): two setup ADMINs load it through the governed load, then are switched off.
  DATA="${DEMO_DATA:-data}"
  ls "$DATA"/*.csv >/dev/null 2>&1 || DATA=services/mdm-api/src/test/resources/load/hackathon   # data/ is git-ignored
  docker compose exec -T db psql -q -v ON_ERROR_STOP=1 -U nexus -d "$DB" -f /workspace/db/demo/setup.sql >/dev/null
  echo "== Data set from $DATA"
  NEXUS_API_URL="http://localhost:$API_PORT" bash scripts/load-data.sh --dir "$DATA" --as setup_admin1 --approve-as setup_admin2 \
    > .demo/load.log 2>&1 || { echo "The data set did not load: see .demo/load.log"; tail -15 .demo/load.log; exit 1; }
  tail -3 .demo/load.log
  docker compose exec -T db psql -q -v ON_ERROR_STOP=1 -U nexus -d "$DB" -f /workspace/db/demo/after-load.sql >/dev/null
  echo "Workflows set up; setup administrators switched off"
fi

echo "== UI"
(cd ui && NEXUS_API_URL="http://localhost:$API_PORT" exec nohup npm start -- --port "$UI_PORT") > .demo/ui.log 2>&1 &
echo $! > .demo/ui.pid
for i in $(seq 1 150); do                  # the first dev-server compile can take a few minutes
  http_ok "http://localhost:$UI_PORT/" && break
  sleep 2
done
http_ok "http://localhost:$UI_PORT/" || { echo "The UI did not answer within 5 minutes: see .demo/ui.log (scripts/demo-stop.sh stops it)"; exit 1; }

cat <<EOF

Demo running: http://localhost:$UI_PORT   (API http://localhost:$API_PORT, database $DB)
Sign in with the "Development user" picker. The users of data/users.csv (with --e2e-seed: the e2e_* users):
  u_admin (ADMIN)   u_editor1 (ORGNEXUS, ORGNHYD)   u_editor2 (ORGSPI)   u_editor3 (all three)
  u_approver1 / u_approver3 approve and commit ORGNEXUS, ORGNHYD   u_approver2 / u_approver4 approve and commit ORGSPI
  u_viewer / u_auditor (read only)   svc_dw_consumer (service account: published output only)
  Every edit goes Submit, Approve, Commit; approving and committing are two different people.
Logs: .demo/api.log, .demo/ui.log    Stop: scripts/demo-stop.sh
EOF
