# Checks the local toolchain on Windows.
$ok = $true
function Check($name, $cmd, $pattern) {
  try {
    $out = (& cmd /c "$cmd 2>&1") -join " "
    if ($out -match $pattern) { Write-Host "[OK]   $name : $out" }
    else { Write-Host "[FAIL] $name : unexpected output: $out"; $script:ok = $false }
  } catch { Write-Host "[FAIL] $name : not found"; $script:ok = $false }
}
Check "Git"    "git --version"    "git version"
Check "Java 21" "java -version"    'version "21'
Check "Maven"  "mvn -v"           "Apache Maven"
Check "Docker" "docker version --format {{.Server.Version}}" "^\d"
if ($ok) { Write-Host "`nAll checks passed. Next: scripts\db-test.ps1" } else { Write-Host "`nFix the failures above (see docs/DEVELOPER_SETUP.md)." }
