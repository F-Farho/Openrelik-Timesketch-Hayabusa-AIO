# install_stack.sh

Full-stack installer for **Timesketch + OpenRelik 0.7.0** on a single Linux host using Docker Compose.

---

## What it installs

| Component | Version | Notes |
|---|---|---|
| Timesketch | latest (official installer) | nginx on :80, API on :5000 (internal) |
| OpenRelik | 0.7.0 | UI on :8711, API on :8710 |
| openrelik-worker-strings | default | Ships with OpenRelik 0.7.0 |
| openrelik-worker-plaso | default | Ships with OpenRelik 0.7.0 |
| openrelik-worker-hayabusa | default | Ships with OpenRelik 0.7.0 |
| openrelik-worker-timesketch | default + patched | Ships with OpenRelik 0.7.0; credentials injected via override |
| openrelik-worker-floss | latest | Added via override |
| openrelik-worker-capa | latest | Added via override |
| openrelik-worker-llm | latest | Added via override |
| openrelik-ollama | latest (CPU mode) | Added via override; LLM backend for llm worker |

---

## Requirements

- Ubuntu 22.04 or 24.04
- Docker Engine + Docker Compose v2
- Root access (`sudo`)
- Outbound internet (GitHub, ghcr.io, docker.io)
- Minimum 16 GB RAM recommended (OpenSearch alone needs 8 GB)

---

## Usage

```bash
sudo bash install_stack.sh
```

The script is fully unattended. It will:

1. Stop and remove all existing containers, volumes, networks, and images
2. Install Timesketch from the official Google installer
3. Install OpenRelik using the official installer
4. Validate all downloaded config files (guards against silent 404 saves)
5. Connect Timesketch into OpenRelik's Docker network
6. Patch the Timesketch worker with credentials and add floss, capa, llm workers
7. Register both stacks as systemd services with correct startup ordering
8. Run a health check and print a summary

Full output is captured in `/opt/install_stack_<timestamp>.log`.

---

## Access

| Service | URL | Default credentials |
|---|---|---|
| Timesketch | http://localhost | admin / admin1234 |
| OpenRelik UI | http://localhost:8711 | admin / (generated, shown in summary) |
| OpenRelik API | http://localhost:8710 | — |

---

## After install: LLM worker

The `openrelik-worker-llm` container starts in CPU mode with no model loaded.
Pull a model before using it:

```bash
docker exec openrelik-ollama ollama pull llama3
```

To enable GPU acceleration, uncomment the `deploy` block in
`/opt/openrelik/docker-compose.override.yml` and restart:

```bash
systemctl restart openrelik
```

---

## File layout

```
/opt/timesketch/
  docker-compose.yml            # official, unmodified
  docker-compose.override.yml   # connects timesketch-web to openrelik_default network
  config.env
  start.sh                      # convenience script (systemd is the primary method)

/opt/openrelik/
  docker-compose.yml            # official, unmodified
  docker-compose.override.yml   # patches timesketch worker + adds floss, capa, llm
  config.env → .env (symlink)
  start.sh                      # convenience script (systemd is the primary method)

/etc/systemd/system/
  timesketch.service
  openrelik.service

/opt/install_stack_<timestamp>.log
```

---

## Auto-start on reboot

Both stacks are registered as systemd services and start automatically after reboot.
Startup order is enforced: Timesketch always starts before OpenRelik.

```bash
# Manual control
systemctl start timesketch
systemctl start openrelik

systemctl stop openrelik
systemctl stop timesketch

systemctl status timesketch
systemctl status openrelik
```

---

## Network integration

`timesketch-web` is attached to both its own default network and `openrelik_default`.
This allows all OpenRelik workers to reach Timesketch at `http://timesketch-web:5000`
via Docker internal DNS — without exposing any additional ports.

---

## Workers

### Default (ships with OpenRelik 0.7.0)

| Worker | Purpose |
|---|---|
| openrelik-worker-strings | Extracts plain strings from any file |
| openrelik-worker-plaso | Generates super timelines from disk images |
| openrelik-worker-hayabusa | Fast EVTX triage and threat hunting |
| openrelik-worker-timesketch | Pushes Plaso/CSV timelines into Timesketch |

### Added via override

| Worker | Purpose |
|---|---|
| openrelik-worker-floss | FLARE Obfuscated String Solver — deobfuscates strings from malware |
| openrelik-worker-capa | Detects binary capabilities and maps them to ATT&CK techniques |
| openrelik-worker-llm | Runs user-defined prompts against any UTF-8 file via Ollama |
| openrelik-ollama | Local Ollama LLM backend (CPU by default, GPU optional) |

---

## Known limitations

- The `openrelik-worker-timesketch` repository is archived upstream. The worker still
  functions with 0.7.0 but receives no further updates.
- Ollama runs in CPU mode by default. Large models will be slow without a GPU.
- Timesketch credentials are hardcoded in the script (`admin / admin1234`).
  Change them in the configuration block at the top of `install_stack.sh` before running.
