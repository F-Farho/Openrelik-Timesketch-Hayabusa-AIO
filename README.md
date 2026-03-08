OpenRelik + Timesketch Full‑Stack Installer
This repository provides a single automation script, install_stack.sh, that deploys and integrates:
•	Timesketch — forensic timeline analysis platform
•	OpenRelik (release 0.7.0 or latest) — automated forensic processing and reporting
•	A suite of OpenRelik workers, including optional FLOSS, CAPA, and LLM workers powered by Ollama
The script installs both platforms with Docker Compose, configures Timesketch and OpenRelik to talk to one another, and writes Docker Compose overrides to attach extra workers without modifying upstream compose files.
Why this installer exists
By default, OpenRelik and Timesketch are separate deployments. The standard OpenRelik deploy compose does not include Timesketch and typically ships only a core set of workers. Likewise, Timesketch has no knowledge of OpenRelik. This script fills that gap by:
1.	Installing Timesketch and OpenRelik under /opt so the directory structures are flat and do not nest installers.
2.	Patching the built‑in openrelik‑worker‑timesketch service with the proper Timesketch credentials and URLs.
3.	Adding extra workers (FLOSS, CAPA, and an LLM worker) via docker‑compose.override.yml so they persist across reboots.
4.	Connecting the timesketch‑web container to the OpenRelik internal network (openrelik_default) so workers can reach Timesketch at http://timesketch-web:5000.
5.	Selecting the correct OpenRelik release (0.7.0 by default) from the installer menu and repairing any deployment files if the installer downloads HTML error bodies.
What this script does
install_stack.sh performs the following end‑to‑end workflow:
1.	Cleans previous Docker containers, volumes, networks, and prior install directories (destructive reset — use a dedicated host).
2.	Downloads and runs the Timesketch installer from Google, patching the health‑check timeout, creating data directories, and starting the Timesketch stack.
3.	Creates a Timesketch admin account (admin / admin1234 by default).
4.	Downloads and runs the OpenRelik installer. The script automatically chooses the correct release menu option for version 0.7.0 (or latest if configured) and captures the generated admin password.
5.	Verifies the OpenRelik stack, ensures the .env file is complete, waits for PostgreSQL to be ready and DB migrations to run, and validates the compose schema.
6.	Writes a Timesketch Docker Compose override that attaches timesketch‑web to OpenRelik’s internal network. This ensures OpenRelik workers can reach Timesketch without exposing internal ports.
7.	Writes an OpenRelik Docker Compose override that:
8.	Patches openrelik‑worker‑timesketch with Timesketch URL and credentials.
9.	Adds FLOSS (openrelik‑worker‑floss), CAPA (openrelik‑worker‑capa), and LLM (openrelik‑worker‑llm + openrelik‑ollama) workers. The LLM worker requires an Ollama model (llama3 by default) pulled after installation.
10.	Restarts both stacks with the overrides and prints a deployment summary, including access URLs and credentials.
Important warnings
•	Destructive cleanup: The script stops and removes all Docker containers, volumes, custom networks, and prunes the Docker system cache before deployment. Use a dedicated host or adapt the cleanup section for production.
•	Root required: Run the script with sudo or as root.
•	Default credentials in script: Timesketch credentials are hard coded (admin / admin1234). OpenRelik credentials are captured from the installer. Change these credentials after deployment if using in production.
•	Release selection: By default the script targets OpenRelik 0.7.0. You can change OR_TARGET_RELEASE at the top of the script to latest or another available release.
•	LLM worker: The LLM worker will not function until you pull an Ollama model inside the openrelik‑ollama container:
docker exec openrelik-ollama ollama pull llama3
Requirements
•	Linux host with Docker Engine and the Docker Compose plugin.
•	Internet access to download installer scripts and images.
•	Sufficient CPU/RAM/disk for Timesketch, OpenRelik, and additional workers.
Usage
sudo bash install_stack.sh
Default access endpoints
•	Timesketch: http://localhost (port 80)
•	OpenRelik UI: http://localhost:8711
•	OpenRelik API: http://localhost:8710
After deployment the script writes startup helper scripts:
•	/opt/timesketch/start.sh
•	/opt/openrelik/<compose‑dir>/start.sh
Additional workers
OpenRelik 0.7.0 includes several built‑in workers such as strings, plaso, timesketch, and hayabusa. This installer adds the following via override:
Worker	Description
openrelik-worker-floss	FLARE Obfuscated String Solver (malware strings)
openrelik-worker-capa	Binary capability detection with ATT&CK mapping
openrelik-worker-llm	Runs prompts over files via the Ollama backend
openrelik-ollama	Local Ollama service used by the LLM worker
You can disable any of these workers by removing the corresponding service from docker‑compose.override.yml after installation.
Logging
Installation output is logged to:
•	/opt/install_stack_<timestamp>.log
Repository contents
•	install_stack.sh — main full‑stack installer and integration workflow.
•	README.md — project documentation (this file).
•	CHANGELOG.md — release history and change log.
•	LICENSE — license for this repository.
License
This repository is licensed under the MIT License. See LICENSE.
Upstream projects installed by the script are licensed separately. See THIRD_PARTY_LICENSES.md for pointers to upstream licenses.
Credits
•	Maintainer: Farah Farho (@F‑Farho)
•	Script design and integration: Farah Farho
________________________________________
