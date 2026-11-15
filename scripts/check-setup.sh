#!/usr/bin/env bash
# Checks the local toolchain on macOS/Linux (and Git Bash on Windows).
# Maven is not needed: the Maven wrapper (services/mdm-api/mvnw) downloads it.
ok=1
# Node.js on Windows is usually not on Git Bash's PATH.
if ! command -v node >/dev/null 2>&1 && [ -x "/c/Program Files/nodejs/node.exe" ]; then
  export PATH="/c/Program Files/nodejs:$PATH"
fi
check() { if out=$($2 2>&1) && echo "$out" | grep -qE "$3"; then echo "[OK]   $1: $(echo "$out" | head -1)"; else echo "[FAIL] $1: $out"; ok=0; fi; }
check "Git"            "git --version" "git version"
check "Java 21"        "java -version" 'version "21'
check "Docker"         "docker version --format {{.Server.Version}}" "^[0-9]"
check "Node.js 26 LTS" "node --version" "^v26\."
check "npm"            "npm --version" "^[0-9]+\."
[ $ok = 1 ] && echo "All checks passed. Next: scripts/db-test.sh, then scripts/demo.sh to try the app" \
            || echo "Fix the failures above (see docs/DEVELOPER_SETUP.md)."
