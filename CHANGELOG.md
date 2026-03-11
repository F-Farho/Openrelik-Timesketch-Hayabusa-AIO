# Changelog

---
## [Current] — OpenRelik 0.7.0 support + resilience overhaul

### Added

- **RC filename resolution** (`patch_openrelik_installer`): injects a
  `resolve_filename()` function into the upstream installer before running it.
  This probes for release-candidate variants (`-rc.1` through `-rc.9`) of each
  versioned config and compose file, so the script does not break when OpenRelik
  publishes an RC that does not yet have a final filename.

- **Release selection logic** (`resolve_openrelik_release_selection`): reads the
  installer's own `LATEST_RELEASE` and `RELEASES` arrays to derive the correct
  numeric menu choice for any target release. Replaces the old hard-coded
  `echo "1"` stdin pipe, which was sending input to the wrong subprocess and
  corrupting the install.

- **Post-install file repair** (`repair_openrelik_deploy_file_if_needed`): after
  the installer runs, validates `config.env` and `docker-compose.yml`. If either
  is missing, empty, or contains an HTTP error body, tries a prioritised list of
  candidate filenames (versioned, latest, plain) from the deploy repo URL.

- **Download validation** (`download_first_valid`, `is_http_error_body`): shared
  helpers used by the repair logic. Rejects files whose first 5 lines match HTML,
  404, or error signatures. Also rejects config files that still contain
  `<REPLACE_WITH_...>` placeholders, and compose files missing a `services:` block.

- **Placeholder detection in Section 5**: if `.env` still contains
  `<REPLACE_WITH_...>` values after the installer and repair logic both run,
  the script hard-fails with a clear error message rather than starting a broken
  stack.

- **Dynamic timesketch worker detection in Section 8**: checks whether
  `openrelik-worker-timesketch` is already defined in the base release compose.
  If yes: patch mode (merge credentials env vars only). If no: add mode (full
  service definition including image, volumes, command, and network membership).
  Makes the override forward-compatible across OpenRelik releases.

- **`timesketch_default` network declared in override**: when the timesketch
  worker is added in full (add mode), it joins `timesketch_default` as an
  external network so it can communicate with Timesketch across the compose
  project boundary.

- **Hayabusa local build**: `openrelik-worker-hayabusa` is cloned from
  `openrelik-contrib/openrelik-worker-hayabusa` and built locally as
  `openrelik-worker-hayabusa:local`. Added as a service in the override.

- **Extra workers via override**: `openrelik-worker-floss`, `openrelik-worker-capa`,
  `openrelik-worker-llm`, and `openrelik-ollama` added as new services in
  `docker-compose.override.yml`.

- **OpenSearch memory patch in Section 2**: `8GB/8g/8192m` replaced with
  `4GB/4g/4096m` in the Timesketch installer to allow deployment on hosts
  with less than 16 GB RAM.

- **Carriage-return strip in Section 4**: the upstream installer is passed through
  `python3` to strip `\r\n` line endings before patching, preventing sed/grep
  failures on Windows-style line endings.

- **`POSTGRES_USER` / `POSTGRES_DB` extracted from `.env` in Section 5**:
  replaces the previous hardcoded fallback values so these are always read from
  the actual generated config.

- **`RUNNING_COUNT` now uses `awk`** instead of `grep -c`, which avoids the
  non-zero exit code `grep -c` returns when there are no matches (caused silent
  failures with `set -e`).

### Changed

- **`OR_TARGET_RELEASE` variable** replaces the old `echo "1"` stdin pipe.
  Set to `"0.7.0"` by default. Change to `"latest"` or another version string
  to target a different release.

- **Section 4 description updated** to reflect installer patching and release
  selection logic.

- **Section count**: 10 sections → 11 sections (new Section 10 is systemd;
  old Section 10 health check is now Section 11).

---

## [Original] — OpenRelik 0.6.0 baseline

### Stack

- Timesketch via official Google installer.
- OpenRelik via official installer with `echo "1"` stdin pipe (broken — see above).
- No hayabusa worker (added in subsequent version via `openrelik-contrib` build).
- No floss, capa, or llm workers.
- No systemd integration — stacks required manual `start.sh` after every reboot.
- No RC filename resolution or post-install file repair.
- `RUNNING_COUNT` used `grep -c` (could exit non-zero with `set -e`).
- OpenSearch memory requirement not patched (required 16 GB+ host).

### Known issues at this version

- `echo "1" | bash installer.sh` sent stdin to `docker compose` subprocesses
  inside the installer, causing interactive prompts to auto-answer destructively.
  Manifested as `curl -s` saving HTTP 404 error bodies as `docker-compose.yml`
  and `config.env`, which broke compose validation with:
  `non-string key at top level: 404`.
- No auto-start on reboot.
- No resilience against upstream filename changes or RC releases.
