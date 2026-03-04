# OpenRelik + Timesketch + Hayabusa AIO Installer

This repository provides a single automation script, `install_stack.sh`, that deploys and integrates:

- [Timesketch](https://github.com/google/timesketch)
- [OpenRelik](https://github.com/openrelik/openrelik-deploy)
- [openrelik-worker-hayabusa](https://github.com/openrelik-contrib/openrelik-worker-hayabusa)

The script installs both platforms with Docker Compose, builds the Hayabusa worker image locally, and connects all components so OpenRelik workers can push results into Timesketch.

## Why this installer exists

By default, OpenRelik and Timesketch are separate deployments.

- The standard OpenRelik deploy compose does **not** include Timesketch.
- The standard OpenRelik deploy compose also does **not** include
  `openrelik-worker-timesketch` or `openrelik-worker-hayabusa` workers.

This repository addresses those gaps by installing Timesketch separately, then
manually adding and wiring the Timesketch and Hayabusa workers through
`docker-compose.override.yml`.

This behavior matches the upstream OpenRelik deploy defaults at the time this
README was updated.

## What this script does

`install_stack.sh` performs the following end-to-end workflow:

1. Cleans previous Docker containers, volumes, networks, and prior install directories.
2. Installs Timesketch under `/opt/timesketch`.
3. Creates a Timesketch admin account.
4. Installs OpenRelik under `/opt/openrelik`.
5. Verifies OpenRelik services and database readiness.
6. Clones and builds `openrelik-worker-hayabusa` locally.
7. Integrates Docker networking between OpenRelik and Timesketch.
8. Writes Docker Compose override files to enable:
   - `openrelik-worker-timesketch`
   - `openrelik-worker-hayabusa`
9. Restarts both stacks and prints a deployment summary.

## Important warnings

- **Destructive cleanup:** The script intentionally removes Docker containers, volumes, custom networks, and prunes Docker system artifacts before deployment.
- **Root required:** Run with `sudo` or as root.
- **Default credentials in script:** The script currently sets Timesketch default credentials (`admin` / `admin1234`) and captures or generates OpenRelik credentials.

Use this script only on dedicated hosts or lab environments unless you have reviewed and adapted it for production safety.

## Requirements

- Linux host with Docker Engine and Docker Compose plugin available.
- Internet access to download installer scripts and clone worker repositories.
- Root/sudo privileges.

## Usage

```bash
sudo bash install_stack.sh
```

## Default access endpoints

After successful deployment:

- Timesketch: `http://localhost` (port 80)
- OpenRelik UI: `http://localhost:8711`
- OpenRelik API: `http://localhost:8710`

The script also writes startup helper scripts:

- `/opt/timesketch/start.sh`
- `/opt/openrelik/<compose-dir>/start.sh` (exact path depends on installer layout)

## Logging

Installation output is logged to:

- `/opt/install_stack_<timestamp>.log`

## Repository contents

- `install_stack.sh` — main full-stack installer and integration workflow.
- `README.md` — project documentation.
- `LICENSE` — license for this repository.
- `THIRD_PARTY_LICENSES.md` — license pointers for upstream dependencies used by this installer.

## License

This repository is licensed under the MIT License. See [LICENSE](LICENSE).

Upstream projects installed by the script are licensed separately. See [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
