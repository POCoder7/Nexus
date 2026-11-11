#!/usr/bin/env bash
# Checks the local toolchain on macOS/Linux.
ok=1
check() { if out=$($2 2>&1) && echo "$out" | grep -qE "$3"; then echo "[OK]   $1"; else echo "[FAIL] $1: $out"; ok=0; fi; }
check "Git"     "git --version" "git version"
check "Java 21" "java -version" 'version "21'
check "Maven"   "mvn -v"        "Apache Maven"
check "Docker"  "docker version --format {{.Server.Version}}" "^[0-9]"
[ $ok = 1 ] && echo "All checks passed. Next: scripts/db-test.sh" || echo "Fix the failures above (see docs/DEVELOPER_SETUP.md)."
