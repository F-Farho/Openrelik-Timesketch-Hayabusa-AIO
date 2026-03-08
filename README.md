# OpenRelik + Timesketch Full-Stack Installer

This repository provides a single automation script, `install_stack.sh`, that deploys and integrates:

- **Timesketch** — forensic timeline analysis platform
- **OpenRelik** (release `0.7.0` or latest) — automated forensic processing and reporting
- A suite of OpenRelik workers, including optional **FLOSS**, **CAPA**, and **LLM** workers powered by **Ollama**

The script installs both platforms with Docker Compose, configures Timesketch and OpenRelik to communicate, and writes Docker Compose overrides to attach extra workers without modifying upstream Compose files.

## Why this installer exists

By default, OpenRelik and Timesketch are separate deployments:

- Standard OpenRelik deployment does not include Timesketch and usually ships only a core worker set.
- Timesketch has no built-in awareness of OpenRelik.

This script bridges that gap by:

1. Installing Timesketch and OpenRelik under `/opt` with flat directory structures.
2. Patching the built-in `openrelik-worker-timesketch` service with Timesketch credentials and URLs.
3. Adding extra workers (FLOSS, CAPA, and an LLM worker) via `docker-compose.override.yml` so they persist across restarts.
4. Connecting the `timesketch-web` container to the OpenRelik internal network (`openrelik_default`) so workers can reach Timesketch at `http://timesketch-web:5000`.
5. Selecting the correct OpenRelik release (`0.7.0` by default) and repairing deployment files if the installer downloads HTML error bodies.

## What the script does

`install_stack.sh` runs this end-to-end workflow:

1. Cleans previous Docker containers, volumes, networks, and prior install directories (**destructive reset** — use a dedicated host).
2. Downloads and runs the Timesketch installer from Google, patches health-check timeout, creates data directories, and starts the Timesketch stack.
3. Creates a Timesketch admin account (`admin` / `admin1234` by default).
4. Downloads and runs the OpenRelik installer, automatically selecting the correct release menu option (`0.7.0` by default, or latest if configured), and captures the generated admin password.
5. Verifies the OpenRelik stack, ensures `.env` is complete, waits for PostgreSQL readiness and DB migrations, and validates Compose schema.
6. Writes a Timesketch Docker Compose override to attach `timesketch-web` to OpenRelik’s internal network.
7. Writes an OpenRelik Docker Compose override that:
   - Patches `openrelik-worker-timesketch` with Timesketch URL and credentials.
   - Adds FLOSS (`openrelik-worker-floss`), CAPA (`openrelik-worker-capa`), and LLM (`openrelik-worker-llm` + `openrelik-ollama`) services.
8. Restarts both stacks with overrides and prints a deployment summary, including access URLs and credentials.

## Important warnings

- **Destructive cleanup:** The script stops and removes all Docker containers, volumes, custom networks, and prunes Docker system cache before deployment.
- **Root required:** Run with `sudo` or as root.
- **Default credentials in script:** Timesketch defaults are hard-coded (`admin` / `admin1234`). Change credentials after deployment.
- **Release selection:** Defaults to OpenRelik `0.7.0`. You can change `OR_TARGET_RELEASE` at the top of the script.
- **LLM worker setup:** Pull an Ollama model after installation:

```bash
docker exec openrelik-ollama ollama pull llama3
```

## Requirements

- Linux host with Docker Engine and Docker Compose plugin
- Internet access to download installer scripts and images
- Sufficient CPU / RAM / disk for Timesketch, OpenRelik, and additional workers

## Usage

```bash
sudo bash install_stack.sh
```

## Default access endpoints

- Timesketch: <http://localhost> (port 80)
- OpenRelik UI: <http://localhost:8711>
- OpenRelik API: <http://localhost:8710>

After deployment, the script writes startup helper scripts:

- `/opt/timesketch/start.sh`
- `/opt/openrelik/<compose-dir>/start.sh`

## Additional workers

OpenRelik `0.7.0` includes several built-in workers such as strings, plaso, timesketch, and hayabusa.
This installer adds the following via override:

| Worker | Description |
|---|---|
| `openrelik-worker-floss` | FLARE Obfuscated String Solver (malware strings) |
| `openrelik-worker-capa` | Binary capability detection with ATT&CK mapping |
| `openrelik-worker-llm` | Runs prompts over files via the Ollama backend |
| `openrelik-ollama` | Local Ollama service used by the LLM worker |

You can disable any of these by removing the corresponding service from `docker-compose.override.yml` after installation.

## Logging

Installation output is logged to:

- `/opt/install_stack_<timestamp>.log`

## Repository contents

- `install_stack.sh` — main full-stack installer and integration workflow
- `README.md` — project documentation
- `CHANGELOG.md` — release history and change log
- `LICENSE` — repository license

## License

This repository is licensed under the MIT License. See `LICENSE`.

Upstream projects installed by the script are licensed separately. See `THIRD_PARTY_LICENSES.md` for pointers.

## Credits

- Maintainer: Farah Farho ([@F-Farho](https://github.com/F-Farho))
- Script design and integration: Farah Farho
