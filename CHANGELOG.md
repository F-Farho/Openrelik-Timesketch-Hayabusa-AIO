# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [## [1.1.0] - 2026-03-08  OpenRelik 0.7.0 support

### Added

- **Systemd services** (`timesketch.service`, `openrelik.service`) written and enabled
  during install. Both stacks now auto-start on reboot without manual intervention.
  Startup order is enforced at the unit level (`After=timesketch.service` on the
  OpenRelik unit), fixing the race condition where OpenRelik's network did not exist
  when Timesketch tried to join it.

- **floss worker** (`ghcr.io/openrelik/openrelik-worker-floss`) added via override.
  FLARE Obfuscated String Solver for deobfuscating strings from malware binaries.

- **capa worker** (`ghcr.io/openrelik/openrelik-worker-capa`) added via override.
  Detects capabilities in executables and maps findings to ATT&CK techniques.

- **llm worker** (`ghcr.io/openrelik/openrelik-worker-llm`) added via override.
  Runs user-defined prompts against any UTF-8 readable file using a local Ollama backend.

- **Ollama backend** (`ollama/ollama:latest`) added as `openrelik-ollama` service.
  Runs in CPU mode by default. GPU block is present but commented out for NVIDIA hosts.
  Named volume `ollama-data` persists downloaded models across restarts.

- **Post-download file validation** in Section 4. After the OpenRelik installer runs,
  the script checks the first line of `docker-compose.yml` and `config.env` for HTTP
  error body signatures (`404`, `not found`, `error`, `<html>`). If detected,
  re-downloads using `curl -fsSL` which fails hard on HTTP errors. This catches the
  failure mode where `curl -s` in the upstream installer silently saves error responses
  as config files.

### Changed

- **OpenRelik installer stdin pipe removed.** The previous script piped `echo "1"` into
  the installer under the assumption it had a stable/dev menu prompt. The current
  installer has no such prompt; the piped input was reaching `docker compose` subprocess
  stdin and corrupting interactive volume-recreation prompts, which caused the 404 config
  file saves. The installer now runs with no stdin input.

- **Hayabusa no longer built locally.** The worker has moved from `openrelik-contrib`
  to the official `openrelik` org and now ships as a pre-built image in the default
  OpenRelik 0.7.0 `docker-compose.yml`. The previous clone of
  `openrelik-contrib/openrelik-worker-hayabusa` and 5–15 minute `docker build` are
  removed entirely.

- **Worker override strategy changed.** Previously the override added both
  `openrelik-worker-timesketch` and `openrelik-worker-hayabusa` as new services.
  Since both now ship in the default 0.7.0 compose, the override only patches the
  existing `openrelik-worker-timesketch` service by merging the four missing Timesketch
  credential env vars. No service definitions are duplicated.

- **`OR_HAYABUSA_DIR` and `OR_HAYABUSA_IMAGE` config variables removed.** No longer
  needed with the official image approach.

- **Cleanup section** no longer removes `/opt/openrelik-worker-hayabusa`.

- **Summary block** startup section replaced: `start.sh` paths removed, replaced with
  `systemctl` commands and a note that startup is automatic.

- **Section count**: 10 sections → 11 sections (Section 10 is the new systemd section;
  old Section 10 health check is now Section 11).

- **Script header** updated to reflect 0.7.0, correct worker list, and new override
  strategy.


## [1.0.1] - 2026-03-08

### Added

- **Release selection and file repair:** Installer now automatically selects the correct OpenRelik release (default `0.7.0`) from the upstream `install.sh` menu instead of piping `1` blindly. It also validates and, if needed, re-downloads `config.env` and `docker-compose.yml` using versioned filenames when HTML error bodies are saved.
- **Extra workers via override:** Added support for FLOSS, CAPA, and LLM workers through `docker-compose.override.yml`, alongside a local `openrelik-ollama` service. Pull an Ollama model (`llama3`) after deployment to enable the LLM worker.
- **Timesketch worker patch:** Script patches the existing `openrelik-worker-timesketch` service with correct Timesketch URL and credentials rather than redefining the entire service in override.
- **Persistent network integration:** Timesketch override now makes `timesketch-web` permanently join `openrelik_default`, eliminating manual `docker network connect` after reboots.
- **Health checks and helper functions:** Added helper functions (`wait_for_healthy`, `wait_for_postgres`, `compose_up`) and improved logging for readiness and Compose operations.
- **Deterministic startup scripts:** Script writes `/opt/timesketch/start.sh` and `/opt/openrelik/<compose-dir>/start.sh` to include overrides during startup.

### Changed

- **Script name:** Installer renamed to `install_stack.sh` (from `Install_Stack.sh`) for consistency.
- **Removed Hayabusa build step:** No longer clones/builds `openrelik-worker-hayabusa` locally. OpenRelik `0.7.0` includes Hayabusa by default.
- **Readability improvements:** README rewritten to clarify purpose, workflow, warnings, and worker behavior.
- **Cleaner cleanup:** Removed deletion of the Hayabusa build directory; cleanup still removes all containers, volumes, and custom networks.

### Fixed

- **Installer hang from menu mismatch:** Previously piping `1` could fail when release ordering changed. New logic derives the correct menu option for the target release.
- **Invalid fallback download names:** When upstream download failed, script now uses versioned filenames instead of unversioned names that return `404`.

## [1.0.0] - Initial release

- Initial version of full-stack installer combining Timesketch, OpenRelik, and a locally built Hayabusa worker.
- Set up network integration and Docker Compose overrides for Timesketch and Hayabusa workers.
- Included destructive cleanup logic and health checks.
