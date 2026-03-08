# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.1] - 2026-03-08

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

## [1.0] - Initial release

- Initial version of full-stack installer combining Timesketch, OpenRelik, and a locally built Hayabusa worker.
- Set up network integration and Docker Compose overrides for Timesketch and Hayabusa workers.
- Included destructive cleanup logic and health checks.
