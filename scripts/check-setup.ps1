# Checks the local toolchain on Windows. Maven is not needed: the Maven wrapper (services\mdm-api\mvnw.cmd) downloads it.
$ok = $true
function Check($name, $cmd, $pattern) {
  try {
    $out = (& cmd /c "$cmd 2>&1") -join " "
    if ($out -match $pattern) { Write-Host "[OK]   $name : $out" }
    else { Write-Host "[FAIL] $name : unexpected output: $out"; $script:ok = $false }
  } catch { Write-Host "[FAIL] $name : not found"; $script:ok = $false }
}
Check "Git"            "git --version"    "git version"
Check "Java 21"        "java -version"    'version "21'
Check "Docker"         "docker version --format {{.Server.Version}}" "^\d"
Check "Node.js 26 LTS" "node --version"   "^v26\."
Check "npm"            "npm --version"    "^\d+\."
if ($ok) { Write-Host "`nAll checks passed. Next: scripts\db-test.ps1, then scripts\demo.ps1 to try the app" } else { Write-Host "`nFix the failures above (see docs/DEVELOPER_SETUP.md)." }
