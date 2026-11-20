# Windows version of load-data.sh: loads the hackathon CSV data set into Nexus (ADR-046; Phase 4 LLD §17.8.1). Upload
# and check the files, prepare the load (plan and manifest) and, with -ApproveAs, approve and apply it as a second ADMIN.
# Everything goes through the API, so the load is governed like any other change: two ADMINs, change requests,
# validation, audit.
#
#   scripts\load-data.ps1                          check and prepare data\ as u_admin, then stop for a second ADMIN
#   scripts\load-data.ps1 -ApproveAs e2e_admin     ... and approve and apply it as e2e_admin (local and test only)
#
# Parameters:
#   -Dir <folder>        the CSV files (default data)
#   -As <login>          the ADMIN who uploads and prepares (default u_admin)
#   -ApproveAs <login>   a different ADMIN who approves and applies. Local and test only: it names the user in the
#                        X-Nexus-User header, which only the local and test profiles accept.
#   -Version <name>      the working version to load into (default: the files' working version, else the latest one)
#   -Reset               rebuild the local demo instead (scripts\demo-stop.ps1, then scripts\demo.ps1: a fresh database
#                        with the data set loaded) and stop. Asks first unless -Yes.
# Environment: NEXUS_API_URL (default http://localhost:8080). Synthetic data only (CLAUDE.md rule 5).
param([string]$Dir = "data", [string]$As = "u_admin", [string]$ApproveAs = "", [string]$Version = "", [switch]$Reset, [switch]$Yes)
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

$api = if ($env:NEXUS_API_URL) { $env:NEXUS_API_URL } else { "http://localhost:8080" }
if ($ApproveAs -and $ApproveAs -eq $As) { throw "-ApproveAs must be a different ADMIN from -As ($As)" }
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw "curl.exe not found (it ships with Windows 10 and later)" }

# One API call as a login; returns the parsed body, or stops with the server's words.
function Invoke-Nexus([string]$Login, [string]$Method, [string]$Path, $Body = $null) {
  $params = @{ Uri = "$api$Path"; Method = $Method; Headers = @{ "X-Nexus-User" = $Login }; TimeoutSec = 900 }
  if ($null -ne $Body) { $params.ContentType = "application/json"; $params.Body = ($Body | ConvertTo-Json -Compress) }
  try { return Invoke-RestMethod @params }
  catch {
    $detail = $_.ErrorDetails.Message
    try { $detail = ($detail | ConvertFrom-Json).detail } catch { }
    throw "Failed: $detail"
  }
}

if ($Reset) {
  if (-not $Yes) {
    $answer = Read-Host "Rebuild the local demo database? Everything in it is replaced by a fresh load of the data set. [y/N]"
    if ($answer -notmatch '^[yY]$') { Write-Host "Not reset."; exit 1 }
  }
  & (Join-Path $PSScriptRoot "demo-stop.ps1")
  & (Join-Path $PSScriptRoot "demo.ps1")      # a fresh demo loads the data set itself (setup ADMINs, then switched off)
  exit 0
}

try { $health = Invoke-RestMethod -Uri "$api/actuator/health" -TimeoutSec 5 } catch { $health = $null }
if (-not $health -or $health.status -ne "UP") { throw "The API at $api is not up. Start it with scripts\demo.ps1" }
$files = @(Get-ChildItem -Path $Dir -Filter *.csv -File)
if ($files.Count -eq 0) { throw "No CSV files in $Dir" }

Write-Host "== 1. Upload and check $($files.Count) files from $Dir (as $As)"
$form = @()
foreach ($f in $files) { $form += @("-F", "files=@$($f.FullName);type=text/csv") }
$out = New-TemporaryFile
try {
  $status = & curl.exe -s -o $out.FullName -w "%{http_code}" -H "X-Nexus-User: $As" @form "$api/api/v1/admin/load-runs/uploads"
  $staged = Get-Content $out.FullName -Raw | ConvertFrom-Json
} finally { Remove-Item $out.FullName -ErrorAction SilentlyContinue }
if ($status -ne "201") { throw "Upload failed ($status): $($staged.detail)" }
$load = $staged.loadId
foreach ($s in $staged.staged) { Write-Host ("   staged  {0,-28} {1,5} rows" -f $s.fileName, $s.rows) }
foreach ($r in $staged.rejected) { Write-Host "   REJECTED $($r.fileName): $($r.reason)" }
foreach ($x in $staged.findings) {
  $where = if ($x.lineNo) { "$($x.fileName):$($x.lineNo)" } else { $x.fileName }
  Write-Host ("   {0,-7} {1}  {2}" -f $x.severity, $where, $x.detail)
}
$problems = $staged.errors + @($staged.rejected).Count
if ($problems -gt 0) { Write-Host "The files have $problems problem(s). Fix them and run again. (load $load)"; exit 1 }

Write-Host "== 2. Prepare the load (as $As)"
$body = if ($Version) { @{ version = $Version } } else { @{} }
$run = Invoke-Nexus $As POST "/api/v1/admin/load-runs/$load/prepare" $body
Write-Host "   target version: $($run.targetVersion)"
foreach ($s in $run.plan.steps) { Write-Host "   $($s.label) ($($s.count))" }
if (@($run.plan.skipped).Count -gt 0) { Write-Host "   skipped: $($run.plan.skipped -join ', ')" }
if (@($run.plan.rules.storedInactive).Count -gt 0) { Write-Host "   rules stored inactive (no library entry): $($run.plan.rules.storedInactive -join ', ')" }
Write-Host "   load run: $load"
Write-Host "   manifest: $($run.manifestSha256)"

if (-not $ApproveAs) {
  Write-Host "Prepared. A second ADMIN now reviews the plan, approves this manifest and applies the load, either on the"
  Write-Host "Admin > Data loads screen or through the API:"
  Write-Host "  POST $api/api/v1/admin/load-runs/$load/approve  {`"manifestSha256`":`"$($run.manifestSha256)`"}"
  Write-Host "  POST $api/api/v1/admin/load-runs/$load/apply"
  exit 0
}

Write-Host "== 3. Approve the manifest (as $ApproveAs)"
$null = Invoke-Nexus $ApproveAs POST "/api/v1/admin/load-runs/$load/approve" @{ manifestSha256 = $run.manifestSha256 }
Write-Host "   approved"

Write-Host "== 4. Apply (as $ApproveAs); this can take a few minutes"
$done = Invoke-Nexus $ApproveAs POST "/api/v1/admin/load-runs/$load/apply"
foreach ($q in $done.requests) { Write-Host ("   {0,2}. {1,-22} {2}  {3}" -f $q.seq, $q.step, $q.status, $q.changeRequestId) }
if ($done.report -and $done.report.reconciliation) {
  $rec = $done.report.reconciliation
  $state = if ($rec.clean) { "clean" } else { "DIFFERENCES" }
  Write-Host "   reconciliation: $state, values $($rec.valuesApplied)/$($rec.valuesStaged)"
}
if ($done.report -and $done.report.access -and @($done.report.access.skipped).Count -gt 0) {
  Write-Host "   left for another ADMIN: $($done.report.access.skipped -join '; ')"
}
if ($done.status -ne "applied") { Write-Host "The load $($done.status): $($done.error)"; exit 1 }
Write-Host "Loaded. Load run $load is applied."
