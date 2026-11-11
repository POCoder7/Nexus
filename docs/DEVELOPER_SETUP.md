# Developer setup (VS Code)

Goal: fresh laptop to green tests in under a day.

## 1. Install
| Tool | Version | Notes |
|---|---|---|
| Git | any recent | Configure `user.name` / `user.email` |
| JDK | 21 (Eclipse Temurin or your approved build) | `java -version` must show 21 |
| Maven | 3.9+ (optional) | The Maven wrapper is committed: `services/mdm-api/mvnw` (`mvnw.cmd` on Windows) downloads and uses Maven 3.9.9. `scripts/check-setup` still checks for a local `mvn` |
| Container runtime | Docker Desktop, Rancher Desktop or Podman | Check which is licensed/approved. Needed for the database and Testcontainers. **Windows 11 Home:** Docker Desktop needs WSL 2 — run `wsl --install --no-distribution` in an administrator PowerShell and reboot before starting Docker Desktop |
| VS Code | latest | Accept the recommended extensions when prompted (`.vscode/extensions.json`) |

## 2. Corporate network (fill in for your organisation)
- **Maven mirror**: add your Artifactory/Nexus mirror to `~/.m2/settings.xml`.
- **Container registry mirror**: configure your runtime to pull `postgres` images via the internal registry;
  for Testcontainers set `hub.image.name.prefix` in `~/.testcontainers.properties` if required.
- **TLS inspection**: if downloads fail with certificate errors, import the corporate CA into the JDK trust store
  (`keytool -importcert -cacerts -alias corp-ca -file corp-ca.crt`).
- **VDI**: confirm containers can run; many VDI images cannot.

## 3. Verify
```
scripts\check-setup.ps1        # or scripts/check-setup.sh
scripts\db-test.ps1            # migrations + pgTAP on a fresh database (or bash scripts/db-test.sh, also in Git Bash)
cd services\mdm-api
.\mvnw.cmd -B verify           # or ./mvnw -B verify
```

Known issues:
- **"Could not find a valid Docker environment" with Docker Engine 29 or later.** Testcontainers older than 1.21.4
  requests a Docker API version that Engine 29 rejects. `pom.xml` pins `testcontainers.version` to 1.21.4; keep the
  pin until the Spring Boot parent manages a compatible version.
- **Git Bash on Windows** rewrites `/workspace/...` paths passed to `docker`; `scripts/db-test.sh` sets
  `MSYS_NO_PATHCONV=1` for this.

## 4. Claude Code (if approved by your organisation)
Install the Claude Code extension, open this folder, and start with:
1. "Read CLAUDE.md and README.md and summarise the project and the rules you'll follow."
2. "Run scripts/db-test and fix any failures. Never weaken a trigger or constraint; explain each fix first."
3. "Run the Maven build and fix any failures the same way."

Do not open production data in the editor while an AI agent is running.
