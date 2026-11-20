# Windows version of demo.sh: starts the local demo from scratch. A fresh demo database built by the migrations, the
# hackathon data set (ADR-046) loaded through the governed two-ADMIN load, the API (with the in-process workflow worker)
# and the UI dev server. Synthetic data only. Stop it with scripts\demo-stop.ps1.
#
#   scripts\demo.ps1            recreate the demo database, load the data set, then start everything
#   scripts\demo.ps1 -Keep      keep the existing demo database (Flyway applies any new migrations); nothing loaded
#   scripts\demo.ps1 -Build     rebuild the API jar first (otherwise it is built only when missing)
#   scripts\demo.ps1 -E2eSeed   load the automated tests' seed (ui/e2e/seed.sql) instead of the data set
#
# The data set comes from data\ (git-ignored), or from the tracked synthetic sample if data\ has no CSV files.
# Overrides (environment): DEMO_DB (nexus_demo), DEMO_API_PORT (8080), DEMO_UI_PORT (4200), DEMO_DATA (data).
# Logs and process ids go to .demo\ (git-ignored).
param([switch]$Keep, [switch]$Build, [switch]$E2eSeed)
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

if (-not $Keep -and $E2eSeed) {
  docker compose exec -T db psql -q -v ON_ERROR_STOP=1 -U nexus -d $db -f /workspace/ui/e2e/seed.sql | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Loading the seed failed" }
  Write-Host "Loaded the synthetic test seed (ui/e2e/seed.sql)"
} elseif (-not $Keep) {
  # Only the hackathon data set (ADR-046): two setup ADMINs load it through the governed load, then are switched off.
  $data = if ($env:DEMO_DATA) { $env:DEMO_DATA } else { "data" }
  if (-not (Get-ChildItem -Path $data -Filter *.csv -File -ErrorAction SilentlyContinue)) {
    $data = "services\mdm-api\src\test\resources\load\hackathon"   # data\ is git-ignored
  }
  docker compose exec -T db psql -q -v ON_ERROR_STOP=1 -U nexus -d $db -f /workspace/db/demo/setup.sql | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "The demo setup failed" }
  Write-Host "== Data set from $data"
  $env:NEXUS_API_URL = "http://localhost:$apiPort"
  & (Join-Path $PSScriptRoot "load-data.ps1") -Dir $data -As setup_admin1 -ApproveAs setup_admin2 *> .demo\load.log
  if ($LASTEXITCODE -ne 0) { Get-Content .demo\load.log -Tail 15; throw "The data set did not load: see .demo\load.log" }
  Get-Content .demo\load.log -Tail 3
  docker compose exec -T db psql -q -v ON_ERROR_STOP=1 -U nexus -d $db -f /workspace/db/demo/after-load.sql | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "The demo setup after the load failed" }
  Write-Host "Workflows set up; setup administrators switched off"
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
Sign in with the "Development user" picker. The users of data\users.csv (with -E2eSeed: the e2e_* users):
  u_admin (ADMIN)   u_editor1 (ORGNEXUS, ORGNHYD)   u_editor2 (ORGSPI)   u_editor3 (all three)
  u_approver1 / u_approver3 approve and commit ORGNEXUS, ORGNHYD   u_approver2 / u_approver4 approve and commit ORGSPI
  u_viewer / u_auditor (read only)   svc_dw_consumer (service account: published output only)
  Every edit goes Submit, Approve, Commit; approving and committing are two different people.
Logs: .demo\api.log, .demo\ui.log    Stop: scripts\demo-stop.ps1
"@
