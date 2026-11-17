# Developer setup (VS Code)

Goal: fresh laptop to green tests in under a day.

## 1. Install
| Tool | Version | Notes |
|---|---|---|
| Git | any recent | Configure `user.name` / `user.email` |
| JDK | 21 (Eclipse Temurin or your approved build) | `java -version` must show 21 |
| Maven | not needed | The Maven wrapper is committed: `services/mdm-api/mvnw` (`mvnw.cmd` on Windows) downloads and uses Maven 3.9.9 |
| Container runtime | Docker Desktop, Rancher Desktop or Podman | Check which is licensed/approved. Needed for the database and Testcontainers. **Windows 11 Home:** Docker Desktop needs WSL 2 — run `wsl --install --no-distribution` in an administrator PowerShell and reboot before starting Docker Desktop |
| VS Code | latest | Accept the recommended extensions when prompted (`.vscode/extensions.json`) |
| Node.js | 26 LTS (npm 11) | UI from Phase 3. Windows: `winget install OpenJS.NodeJS.LTS`. Versions in `ui/package.json` are pinned exactly (`ui/.npmrc` `save-exact`) |

## 2. Corporate network (fill in for your organisation)
- **Maven mirror**: add your Artifactory/Nexus mirror to `~/.m2/settings.xml`.
- **Container registry mirror**: configure your runtime to pull `postgres` images via the internal registry;
  for Testcontainers set `hub.image.name.prefix` in `~/.testcontainers.properties` if required.
- **TLS inspection**: if downloads fail with certificate errors, import the corporate CA into the JDK trust store
  (`keytool -importcert -cacerts -alias corp-ca -file corp-ca.crt`).
- **VDI**: confirm containers can run; many VDI images cannot.
- **npm mirror with a minimum package age**: some curated registries (e.g. Artifactory Curation) refuse any version
  published less than 72 hours ago ("CURATION BLOCK … only allowed for packages older than 72 hours"). Install the UI
  with `npm ci`, which uses only the versions in `ui/package-lock.json`. Whoever changes that lockfile resolves it with
  `npm install --before=<a date four days ago>` and checks that every exact pin in `ui/package.json` is older than
  that date, so the lockfile never pins anything too new. If an install fails part-way on Windows with `EPERM … rmdir`,
  close editors and terminals using `ui`, delete `ui\node_modules` and run `npm ci` again.

## 3. Verify
```
scripts\check-setup.ps1        # or scripts/check-setup.sh: Git, Java 21, Docker, Node.js 26 and npm
scripts\db-test.ps1            # migrations + pgTAP on a fresh database (or bash scripts/db-test.sh, also in Git Bash)
cd services\mdm-api
.\mvnw.cmd -B verify           # or ./mvnw -B verify
```

### Which databases are built from scratch
| Database | Built by | From scratch? |
|---|---|---|
| `nexus_test` | `scripts/db-test` | Yes, every run: migrations V1 onwards, then the pgTAP tests |
| Testcontainers databases | `mvnw verify` | Yes, a new container every run |
| `nexus_e2e` | `npx playwright test` (in `ui/`) | Yes, every run: the API migrates it, then the synthetic seed `ui/e2e/seed.sql` |
| `nexus_demo` | `scripts/demo` (below) | Yes, unless you pass `-Keep` / `--keep` |
| `nexus` | Flyway, when you start the API yourself | No: it keeps its data, and you add users by hand (below) |

**After pulling changes, recreate the databases that are not built from scratch** (`nexus`, and `nexus_demo` if you
kept it) whenever the pull edited a migration that was already applied. Until the first shared environment exists,
applied migrations may still be edited (CLAUDE.md rule 6; Phase 5 edited V1, V3, V4, V6, V8, V9, V10 and V11, for example: the users, roles and groups change of ADR-042 moved groups into `mdm` and renamed the roles, so every local `nexus` database from before it must be recreated). You can
tell it happened: the API refuses to start with a Flyway `Validate failed: Migrations have failed validation` /
`checksum mismatch` error. Recreate `nexus` with `docker compose down -v` (it removes the database volume, so every
local database starts again; the test databases are rebuilt anyway), or run `scripts/demo` again for the demo.
Once a shared environment exists, migrations are never edited again and existing databases upgrade in place.

### Demo: the whole app with synthetic data, in one command
```
scripts\demo.ps1               # or bash scripts/demo.sh (also in Git Bash)
scripts\demo-stop.ps1          # or bash scripts/demo-stop.sh
```
`demo` recreates the database `nexus_demo`, builds the API jar if it is missing (`-Build` / `--build` rebuilds it),
starts the API on 8080 with the in-process workflow worker (which migrates the database), loads the synthetic seed
`ui/e2e/seed.sql`, starts the UI on http://localhost:4200, and prints the synthetic users to sign in as with the
development user picker. `-Keep` / `--keep` keeps the existing `nexus_demo` (Flyway applies new migrations) and skips the
seed. Logs and process ids are in `.demo/` (git-ignored). `DEMO_DB`, `DEMO_API_PORT` and `DEMO_UI_PORT` override the
database name and ports. Rebuild the jar with `--build` after pulling Java changes. The API runs with the docker-compose
owner account, as below, so the demo does not prove privileges: the tests do.

Run the API yourself instead (Phase 1 onwards):
```
docker compose up -d db
cd services\mdm-api
.\mvnw.cmd spring-boot:run "-Dspring-boot.run.profiles=local" "-Dspring-boot.run.arguments=--mdm.api.local-user=dev_steward"
```
The API refuses to start without an identity adapter; `local` reads the user from `mdm.api.local-user` or the
`X-Nexus-User` header. Create a synthetic user and a grant first (after the API has migrated the database once), for example:
```sql
INSERT INTO mdm.app_user (login, display_name, kind) VALUES ('dev_admin', 'Dev admin', 'human'), ('dev_steward', 'Dev steward', 'human');
INSERT INTO mdm.user_role (user_id, role_code, granted_by, valid_period)
SELECT s.user_id, 'EDITOR', a.user_id, daterange(current_date - 1, NULL)
FROM mdm.app_user s, mdm.app_user a WHERE s.login = 'dev_steward' AND a.login = 'dev_admin';
```
Or load the synthetic seed the demo and the end-to-end tests use (users, hierarchies, properties, workflow models),
once, after the API has migrated an empty `nexus` database:
```
docker compose exec -T db psql -q -v ON_ERROR_STOP=1 -U nexus -d nexus -f /workspace/ui/e2e/seed.sql
```
(In Git Bash, put `MSYS_NO_PATHCONV=1` in front, or the `/workspace/...` path is rewritten.)
Locally the API connects with the single docker-compose account; in tests it runs as the least-privilege login
`nexus_api_test` (role `nexus_api`), which is how shared environments must run it (ADR-014).

Workflow (Phase 2 onwards): requests submitted with a workflow model move between stages only when a workflow worker
runs. Locally, start a second instance of the API as the worker with the in-process engine (no Camunda needed):
```
.\mvnw.cmd spring-boot:run "-Dspring-boot.run.profiles=local" "-Dspring-boot.run.arguments=--server.port=8081 --mdm.workflow.worker.enabled=true"
```
It needs the system actor that records policy evaluations, a synthetic user of kind `system_feed`:
`INSERT INTO mdm.app_user (login, display_name, kind) VALUES ('nexus_system', 'Nexus system', 'system_feed');`
Locally both use the docker-compose account; in tests the worker runs as `nexus_wf_test` (role `nexus_wf`), as shared
environments must. The Camunda engine (`--mdm.workflow.engine=camunda`) and its contract tests (`./mvnw -B verify -Dcamunda`)
need Camunda and Elasticsearch in Docker, which needs more memory than 4 GB (deferred; see BUILD_STATE).

Performance tests (tag `perf`) are excluded from the default build and deferred to the end of the build; run them with
`./mvnw -B verify -Dperf`.

Steward UI (Phase 3 onwards), from `ui/`:
```
npm ci                         # install the pinned toolchain (public npm registry here; point ~/.npmrc at your mirror)
npx playwright install chromium   # one browser build serves both story and end-to-end tests (package.json overrides playwright)
npm start                      # dev server on http://localhost:4200, proxies /api to http://localhost:8080 (NEXUS_API_URL)
npm run lint                   # Stylelint token rules + their self-test
npm run api:check              # generated client matches docs/api/openapi.json (npm run api:generate after an API change)
npm test                       # unit and component tests (Vitest)
npm run build                  # production build + compressed budgets + "no dev identity in the bundle" check
npm run build-storybook; npm run test:storybook   # every story, with axe
npx playwright test            # SLICE-01 journeys: builds the API jar, fresh database nexus_e2e, synthetic seed, API on 8180
```
Locally the UI identifies you with the development user picker in the header (local and test builds only): pick a synthetic
login from `ui/e2e/seed.sql` (for example `e2e_steward`) or one you created as above. The production build has no picker.
Design-system packages (OD-02) will come only from the internal registry and are never committed.

Known issues:
- **"Could not find a valid Docker environment" with Docker Engine 29 or later.** Testcontainers older than 1.21.4
  requests a Docker API version that Engine 29 rejects. `pom.xml` pins `testcontainers.version` to 1.21.4; keep the
  pin until the Spring Boot parent manages a compatible version.
- **Git Bash on Windows** rewrites `/workspace/...` paths passed to `docker`; `scripts/db-test.sh` and `scripts/demo.sh`
  set `MSYS_NO_PATHCONV=1` for this.
- **Node.js in Git Bash on Windows.** The installer puts Node.js in `C:\Program Files\nodejs`, which Git Bash may not have
  on its PATH. `scripts/check-setup.sh` and `scripts/demo.sh` add it; elsewhere run
  `export PATH="/c/Program Files/nodejs:$PATH"` first.
- **Storybook tests find no stories from Git Bash** (`No tests found` with a `c:/...` path) when the working directory's
  drive letter is lower case. Run them from `cd "C:/Projects/Nexus/ui"` (upper-case drive), or from PowerShell.
- **The API jar is locked while the demo runs.** On Windows, `mvnw verify` fails at its last step (`repackage`: "Unable to
  rename … mdm-api-…jar") while the demo API runs from that jar. The tests have already run by then. Stop the demo
  (`scripts/demo-stop`) to build the jar.
- **Serving the UI from a server over plain HTTP** (for example `http://<server address>:4200`). Browsers treat such a
  page as insecure and leave out some features there: `crypto.randomUUID()` (the UI now falls back to
  `crypto.getRandomValues()`, `core/random-id.ts`) and the clipboard (the "copy id" buttons then do nothing). The data
  and the development sign-in header also travel unencrypted. Use HTTPS for any shared server; `localhost` counts as
  secure, so a single laptop is fine.

## 4. Claude Code (if approved by your organisation)
Install the Claude Code extension, open this folder, and start with:
1. "Read CLAUDE.md and README.md and summarise the project and the rules you'll follow."
2. "Run scripts/db-test and fix any failures. Never weaken a trigger or constraint; explain each fix first."
3. "Run the Maven build and fix any failures the same way."

Do not open production data in the editor while an AI agent is running.
