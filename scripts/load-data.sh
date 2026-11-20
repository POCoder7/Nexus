#!/usr/bin/env bash
# Loads the hackathon CSV data set into Nexus (ADR-046; Phase 4 LLD §17.8.1): upload and check the files, prepare the
# load (plan and manifest), and, with --approve-as, approve and apply it as a second ADMIN. Everything goes through the
# API, so the load is governed like any other change: two ADMINs, change requests, validation, audit.
#
#   scripts/load-data.sh                         check and prepare data/ as u_admin, then stop for a second ADMIN
#   scripts/load-data.sh --approve-as e2e_admin  ... and approve and apply it as e2e_admin (local and test only)
#
# Options:
#   --dir <folder>        the CSV files (default data/)
#   --as <login>          the ADMIN who uploads and prepares (default u_admin)
#   --approve-as <login>  a different ADMIN who approves and applies. Local and test only: it names the user in the
#                         X-Nexus-User header, which only the local and test profiles accept.
#   --version <name>      the working version to load into (default: the files' working version, else the latest one)
#   --reset               first rebuild the local demo (scripts/demo-stop.sh, then scripts/demo.sh: fresh database
#                         and synthetic seed). Asks for confirmation unless --yes is given.
#   --yes                 do not ask before --reset
# Environment: NEXUS_API_URL (default http://localhost:8080). Synthetic data only (CLAUDE.md rule 5).
set -euo pipefail
cd "$(dirname "$0")/.."

API="${NEXUS_API_URL:-http://localhost:8080}"
DIR=data
AS=u_admin
APPROVE_AS=""
VERSION=""
RESET=0
YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --as) AS="$2"; shift 2 ;;
    --approve-as) APPROVE_AS="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --reset) RESET=1; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown option $1 (see --help)"; exit 2 ;;
  esac
done

# Node.js parses the API's JSON (jq is not assumed). On Windows it is usually not on Git Bash's PATH.
if ! command -v node >/dev/null 2>&1 && [ -x "/c/Program Files/nodejs/node.exe" ]; then
  export PATH="/c/Program Files/nodejs:$PATH"
fi
command -v node >/dev/null 2>&1 || { echo "node not found: install Node.js (docs/DEVELOPER_SETUP.md)"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl not found"; exit 1; }
[ -n "$APPROVE_AS" ] && [ "$APPROVE_AS" = "$AS" ] && { echo "--approve-as must be a different ADMIN from --as ($AS)"; exit 2; }

# js <file> <expression>: evaluates a JavaScript expression with `r` bound to the JSON in <file>, prints the result.
js() { node -e 'const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const v = eval(process.argv[2]); if (v !== undefined) console.log(v);' "$1" "$2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# call <login> <method> <path> [json body] -> body in $TMP/out.json, HTTP status in $STATUS
call() {
  local login="$1" method="$2" path="$3" body="${4:-}"
  local args=(-s -o "$TMP/out.json" -w '%{http_code}' -X "$method" -H "X-Nexus-User: $login" --max-time 900)
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' --data "$body")
  STATUS=$(curl "${args[@]}" "$API$path")
}
fail_with() {
  echo "Failed ($STATUS):"
  js "$TMP/out.json" 'r.detail || r.message || JSON.stringify(r)' 2>/dev/null || cat "$TMP/out.json"
  exit 1
}

if [ "$RESET" = 1 ]; then
  if [ "$YES" = 0 ]; then
    read -r -p "Rebuild the local demo database? Everything in it is replaced by the synthetic seed. [y/N] " answer
    [ "$answer" = y ] || [ "$answer" = Y ] || { echo "Not reset."; exit 1; }
  fi
  bash scripts/demo-stop.sh
  bash scripts/demo.sh
fi

curl -s --max-time 5 "$API/actuator/health" | grep -q '"UP"' || { echo "The API at $API is not up. Start it with scripts/demo.sh"; exit 1; }
shopt -s nullglob
FILES=("$DIR"/*.csv)
[ ${#FILES[@]} -gt 0 ] || { echo "No CSV files in $DIR"; exit 1; }

echo "== 1. Upload and check ${#FILES[@]} files from $DIR (as $AS)"
FORM=()
for f in "${FILES[@]}"; do FORM+=(-F "files=@$f;type=text/csv"); done
STATUS=$(curl -s -o "$TMP/out.json" -w '%{http_code}' -H "X-Nexus-User: $AS" "${FORM[@]}" "$API/api/v1/admin/load-runs/uploads")
[ "$STATUS" = 201 ] || fail_with
LOAD=$(js "$TMP/out.json" 'r.loadId')
js "$TMP/out.json" 'r.staged.map(f => `   staged  ${f.fileName.padEnd(28)} ${String(f.rows).padStart(5)} rows`).join("\n")'
js "$TMP/out.json" 'r.rejected.map(f => `   REJECTED ${f.fileName}: ${f.reason}`).join("\n") || undefined'
js "$TMP/out.json" 'r.findings.map(f => `   ${f.severity.padEnd(7)} ${f.fileName ?? ""}${f.lineNo ? ":" + f.lineNo : ""}  ${f.detail}`).join("\n") || undefined'
ERRORS=$(js "$TMP/out.json" 'r.errors + r.rejected.length')
if [ "$ERRORS" != 0 ]; then
  echo "The files have $ERRORS problem(s). Fix them and run again. (load $LOAD)"
  exit 1
fi

echo "== 2. Prepare the load (as $AS)"
BODY='{}'
[ -n "$VERSION" ] && BODY=$(node -e 'console.log(JSON.stringify({version: process.argv[1]}))' "$VERSION")
call "$AS" POST "/api/v1/admin/load-runs/$LOAD/prepare" "$BODY"
[ "$STATUS" = 200 ] || fail_with
MANIFEST=$(js "$TMP/out.json" 'r.manifestSha256')
js "$TMP/out.json" '`   target version: ${r.targetVersion}\n` + r.plan.steps.map(s => `   ${s.label} (${s.count})`).join("\n")'
js "$TMP/out.json" '[r.plan.skipped.length ? "   skipped: " + r.plan.skipped.join(", ") : "", r.plan.rules.storedInactive.length ? "   rules stored inactive (no library entry): " + r.plan.rules.storedInactive.join(", ") : ""].filter(Boolean).join("\n") || undefined'
echo "   load run: $LOAD"
echo "   manifest: $MANIFEST"

if [ -z "$APPROVE_AS" ]; then
  echo "Prepared. A second ADMIN now reviews the plan, approves this manifest and applies the load, either on the"
  echo "Admin > Data loads screen or through the API:"
  echo "  POST $API/api/v1/admin/load-runs/$LOAD/approve  {\"manifestSha256\":\"$MANIFEST\"}"
  echo "  POST $API/api/v1/admin/load-runs/$LOAD/apply"
  exit 0
fi

echo "== 3. Approve the manifest (as $APPROVE_AS)"
call "$APPROVE_AS" POST "/api/v1/admin/load-runs/$LOAD/approve" "{\"manifestSha256\":\"$MANIFEST\"}"
[ "$STATUS" = 200 ] || fail_with
echo "   approved"

echo "== 4. Apply (as $APPROVE_AS); this can take a few minutes"
call "$APPROVE_AS" POST "/api/v1/admin/load-runs/$LOAD/apply"
[ "$STATUS" = 200 ] || fail_with
js "$TMP/out.json" 'r.requests.map(q => `   ${String(q.seq).padStart(2)}. ${q.step.padEnd(22)} ${q.status}  ${q.changeRequestId}`).join("\n")'
js "$TMP/out.json" 'r.report && r.report.reconciliation ? `   reconciliation: ${r.report.reconciliation.clean ? "clean" : "DIFFERENCES"}, values ${r.report.reconciliation.valuesApplied}/${r.report.reconciliation.valuesStaged}` : undefined'
js "$TMP/out.json" 'r.report && r.report.access && r.report.access.skipped.length ? "   left for another ADMIN: " + r.report.access.skipped.join("; ") : undefined'
RESULT=$(js "$TMP/out.json" 'r.status')
if [ "$RESULT" != applied ]; then
  echo "The load $RESULT: $(js "$TMP/out.json" 'r.error')"
  exit 1
fi
echo "Loaded. Load run $LOAD is applied."
