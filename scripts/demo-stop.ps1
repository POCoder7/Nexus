# Windows version of demo-stop.sh: stops the demo's API and UI dev server, with their child processes. The database
# container keeps running (docker compose stop db stops it too); the demo database stays until the next demo.ps1.
Set-Location (Join-Path $PSScriptRoot "..")
foreach ($name in @("ui", "api")) {
  $file = ".demo\$name.pid"
  if (-not (Test-Path $file)) { Write-Host "${name}: not running (no $file)"; continue }
  $id = (Get-Content $file).Trim()
  # /T stops the whole tree: npm.cmd leaves the node dev server running otherwise
  taskkill /PID $id /T /F *> $null
  if ($LASTEXITCODE -eq 0) { Write-Host "${name}: stopped" } else { Write-Host "${name}: already stopped" }
  Remove-Item $file
}
