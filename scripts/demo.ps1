# Windows version of demo.sh: starts the local demo from scratch. A fresh demo database built by the migrations, the
# synthetic seed, the API (with the in-process workflow worker) and the UI dev server. Synthetic data only.
# Stop it with scripts\demo-stop.ps1.
#
#   scripts\demo.ps1            recreate the demo database, then start everything
#   scripts\demo.ps1 -Keep      keep the existing demo database (Flyway applies any new migrations); no seed
#   scripts\demo.ps1 -Build     rebuild the API jar first (otherwise it is built only when missing)
#
# Overrides (environment): DEMO_DB (nexus_demo), DEMO_API_PORT (8080), DEMO_UI_PORT (4200).
# Logs and process ids go to .demo\ (git-ignored).
param([switch]$Keep, [switch]$Build)
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

$db = if ($env:DEMO_DB) { $env:DEMO_DB } else { "nexus_demo" }
$apiPort = if ($env:DEMO_API_PORT) { $env:DEMO_API_PORT } else { "8080" }
$uiPort = if ($env:DEMO_UI_PORT) { $env:DEMO_UI_PORT } else { "4200" }
New-Item -ItemType Directory -Force .demo | Out-Null

function Test-Url($url) {
  try { Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2 | Out-Null; return $true } catch { return $false }
}
foreach ($p in @($apiPort, $uiPort)) {
  if (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) {
    throw "Port $p is already in use. Stop the running demo first: scripts\demo-stop.ps1"
  }
}
if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) { throw "npm not found: install Node.js (docs/DEVELOPER_SETUP.md)" }

Write-Host "== Database"
docker compose up -d --build db
do { Start-Sleep -Seconds 1; docker compose exec -T db pg_isready -U nexus -d postgres *> $null } until ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 2
if (-not $Keep) {
  docker compose exec -T db psql -q -U nexus -d postgres -c "DROP DATABASE IF EXISTS $db WITH (FORCE)" -c "CREATE DATABASE $db"
  if ($LASTEXITCODE -ne 0) { throw "Could not recreate $db" }
  Write-Host "Recreated $db"
} else {
  $exists = docker compose exec -T db psql -q -U nexus -d postgres -tc "SELECT 1 FROM pg_database WHERE datname = '$db'"
  if (-not ($exists -match "1")) { docker compose exec -T db psql -q -U nexus -d postgres -c "CREATE DATABASE $db" }
  Write-Host "Keeping $db"
}

Write-Host "== API"
$jar = Get-ChildItem "services\mdm-api\target\mdm-api-*.jar" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($Build -or -not $jar) {
  Push-Location services\mdm-api
  try { .\mvnw.cmd -B -q -DskipTests package; if ($LASTEXITCODE -ne 0) { throw "API build failed" } } finally { Pop-Location }
  $jar = Get-ChildItem "services\mdm-api\target\mdm-api-*.jar" | Select-Object -First 1
}
$java = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME "bin\java.exe" } else { "java" }
# UTC JVM: recorded time is UTC everywhere (ADR-018). The worker runs in the same JVM, so requests move through their
# workflow stages without Camunda (ADR-035).
$api = Start-Process -FilePath $java -PassThru -WindowStyle Hidden `
  -RedirectStandardOutput .demo\api.log -RedirectStandardError .demo\api.err.log `
  -ArgumentList "-Duser.timezone=UTC", "-jar", $jar.FullName, "--spring.profiles.active=local", "--server.port=$apiPort",
                "--spring.datasource.url=jdbc:postgresql://localhost:5432/$db", "--mdm.workflow.worker.enabled=true"
$api.Id | Set-Content .demo\api.pid
$up = $false
for ($i = 0; $i -lt 90 -and -not $up; $i++) {
  if ($api.HasExited) { Get-Content .demo\api.log -Tail 20; throw "The API stopped while starting: see .demo\api.log" }
  try { $up = (Invoke-RestMethod "http://localhost:$apiPort/actuator/health" -TimeoutSec 2).status -eq "UP" } catch { Start-Sleep -Seconds 2 }
}
if (-not $up) { throw "The API did not start: see .demo\api.log" }
Write-Host "API up on http://localhost:$apiPort (migrations applied)"

if (-not $Keep) {
  docker compose exec -T db psql -q -v ON_ERROR_STOP=1 -U nexus -d $db -f /workspace/ui/e2e/seed.sql | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Loading the seed failed" }
  Write-Host "Loaded the synthetic seed (ui/e2e/seed.sql)"
}

Write-Host "== UI"
$env:NEXUS_API_URL = "http://localhost:$apiPort"
$ui = Start-Process -FilePath "npm.cmd" -PassThru -WindowStyle Hidden -WorkingDirectory ui `
  -RedirectStandardOutput .demo\ui.log -RedirectStandardError .demo\ui.err.log -ArgumentList "start", "--", "--port", $uiPort
$ui.Id | Set-Content .demo\ui.pid
for ($i = 0; $i -lt 90 -and -not (Test-Url "http://localhost:$uiPort/"); $i++) { Start-Sleep -Seconds 2 }
if (-not (Test-Url "http://localhost:$uiPort/")) { throw "The UI did not start: see .demo\ui.log" }

Write-Host @"

Demo running: http://localhost:$uiPort   (API http://localhost:$apiPort, database $db)
Sign in with the "Development user" picker. Synthetic users from ui/e2e/seed.sql:
  e2e_architect (every change)  e2e_steward (propose)  e2e_approver (approve)  e2e_committer (commit)
  e2e_viewer (read only)        e2e_vadmin / e2e_vadmin2 / e2e_admin / e2e_admin2 (ADMIN)
  Roles through groups (ORGTL, ORGTP, AMBUS): u_admin (ADMIN)  u_editor1 / u_approver1 (ORGTL, ORGTP)
  u_editor2 / u_approver2 (AMBUS)  u_viewer (all three)  svc_dw_consumer (service account: published output only)
Logs: .demo\api.log, .demo\ui.log    Stop: scripts\demo-stop.ps1
"@
