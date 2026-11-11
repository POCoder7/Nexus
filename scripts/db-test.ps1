# Windows version of db-test.sh: fresh test database, all migrations, pgTAP tests.
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

docker compose up -d --build db
do { Start-Sleep -Seconds 1; docker compose exec -T db pg_isready -U nexus -d postgres *> $null } until ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 2

docker compose exec -T db psql -U nexus -d postgres -c "DROP DATABASE IF EXISTS nexus_test" -c "CREATE DATABASE nexus_test"

$dir = "services/mdm-api/src/main/resources/db/migration"
Get-ChildItem $dir -Filter "V*__*.sql" |
  Sort-Object { [int]($_.Name -replace '^V(\d+)__.*', '$1') } |
  ForEach-Object {
    Write-Host "Applying $($_.Name)"
    docker compose exec -T db psql -v ON_ERROR_STOP=1 -q -U nexus -d nexus_test -f "/workspace/$dir/$($_.Name)"
    if ($LASTEXITCODE -ne 0) { throw "Migration $($_.Name) failed" }
  }

docker compose exec -T db psql -q -U nexus -d nexus_test -c "CREATE EXTENSION IF NOT EXISTS pgtap"
docker compose exec -T db sh -c "pg_prove -U nexus -d nexus_test /workspace/db/tests/*.sql"
if ($LASTEXITCODE -ne 0) { throw "pgTAP tests failed" }
