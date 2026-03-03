#!/usr/bin/env bash
# =============================================================================
# Full Stack Installer: Timesketch + OpenRelik + Hayabusa
# =============================================================================
# Run with: sudo bash install_stack.sh
#
# Design:
#   - Both installers run from /opt to avoid nested directories
#       /opt/timesketch/   ← Timesketch compose dir
#       /opt/openrelik/    ← OpenRelik compose dir
#   - Official compose files and ports are never modified
#   - Integration: timesketch-web joins openrelik_default network
#       → workers reach Timesketch at http://timesketch-web:5000
#   - Hayabusa: built locally from openrelik-contrib/openrelik-worker-hayabusa
#       → runs as a proper OpenRelik celery worker (no crash-looping)
#   - Both workers added via docker-compose.override.yml (persists on reboot)
#   - Noisy docker output suppressed on screen; full output captured in log
#
# Ports (official, unmodified):
#   Timesketch  :80  (nginx)   :443 (nginx HTTPS)
#   OpenRelik   :8711 (UI)     :8710 (API)
# =============================================================================

set -uo pipefail

# -----------------------------------------------------------------------------
# Logging — screen shows clean progress; log file captures everything
# -----------------------------------------------------------------------------
LOG_FILE="/opt/install_stack_$(date +%Y%m%d_%H%M%S).log"
mkdir -p /opt
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "================================================="
echo " Installation log: ${LOG_FILE}"
echo " Started: $(date)"
echo "================================================="

# Colours
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; echo "Failed. Log: ${LOG_FILE}"; exit 1; }
section_desc() { echo -e "${DIM}  $*${NC}"; echo ""; }

# Spinner — used for long silent operations (docker build)
SPINNER='/-\|'
spin_char() { printf '%s' "${SPINNER:$(($1 % 4)):1}"; }

[[ "$EUID" -ne 0 ]] && error "Please run as root: sudo bash $0"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
TS_ADMIN_USER="admin"
TS_ADMIN_PASS="admin1234"
OR_ADMIN_USER="admin"
OR_ADMIN_PASS="changeme"          # overwritten once installer output is captured

TS_DIR="/opt/timesketch"          # created by installer when run from /opt
OR_DIR="/opt/openrelik"           # created by installer when run from /opt

OR_HAYABUSA_DIR="/opt/openrelik-worker-hayabusa"
OR_HAYABUSA_IMAGE="openrelik-worker-hayabusa:local"

# The network OpenRelik's installer creates (project name = openrelik)
OR_NETWORK="openrelik_default"

# =============================================================================
# SECTION 1 — Cleanup
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}======================================================${NC}"
echo -e "${CYAN}${BOLD} SECTION 1 — Cleanup${NC}"
echo -e "${CYAN}${BOLD}======================================================${NC}"
section_desc "Stop all containers · prune volumes + networks · remove old dirs + Docker cache"

log "Stopping and removing all containers..."
docker ps -aq | xargs -r docker stop  2>/dev/null || true
docker ps -aq | xargs -r docker rm -f 2>/dev/null || true

log "Removing all volumes..."
docker volume prune -f

log "Removing all custom networks..."
docker network ls -q --filter type=custom | xargs -r docker network rm 2>/dev/null || true

log "Removing previous install directories..."
rm -rf /opt/timesketch /opt/openrelik /opt/openrelik-worker-hayabusa \
       ~/timesketch ~/openrelik

log "Pruning docker images and build cache..."
docker system prune -af --volumes

success "Cleanup complete."

# =============================================================================
# SECTION 2 — Install Timesketch
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}======================================================${NC}"
echo -e "${CYAN}${BOLD} SECTION 2 — Install Timesketch${NC}"
echo -e "${CYAN}${BOLD}======================================================${NC}"
section_desc "Download installer · patch health-check timeout · run from /opt · create data dirs · start stack"

log "Downloading Timesketch installer..."
curl -fsSL -o /tmp/deploy_timesketch.sh \
    https://raw.githubusercontent.com/google/timesketch/master/contrib/deploy_timesketch.sh
chmod +x /tmp/deploy_timesketch.sh

log "Patching health-check timeout (300s → 10s)..."
sed -i 's/TIMEOUT=300/TIMEOUT=10/' /tmp/deploy_timesketch.sh

# Run from /opt → installer creates /opt/timesketch/ (no nesting)
# "n" = do not start containers yet (we start after pre-creating dirs)
log "Running Timesketch installer (creates /opt/timesketch/)..."
cd /opt
echo "n" | bash /tmp/deploy_timesketch.sh

[[ -f "${TS_DIR}/docker-compose.yml" ]] \
    || error "Installer did not create ${TS_DIR}/docker-compose.yml"

cd "${TS_DIR}"

log "Verifying config.env..."
grep -q 'POSTGRES_DATA_PATH' config.env \
    || echo 'POSTGRES_DATA_PATH=./postgres-data' >> config.env
source config.env

log "Pre-creating data directories with correct ownership..."
mkdir -p "${POSTGRES_DATA_PATH:-./postgres-data}" ./logs ./upload ./prometheus-data
chown -R 999:999    "${POSTGRES_DATA_PATH:-./postgres-data}"
chown -R 65534:65534 ./prometheus-data

log "Validating compose schema..."
docker compose config --quiet \
    && success "Timesketch compose schema OK."

wait_for_healthy() {
    local dir="$1" timeout="${2:-180}" waited=0 tick=0
    cd "${dir}"
    until ! docker compose ps 2>/dev/null | grep -qE 'starting|restarting|unhealthy'; do
        [[ $waited -ge $timeout ]] && { warn "Timeout. State:"; docker compose ps; return 1; }
        echo -ne "\r  ${waited}s / ${timeout}s  $(spin_char $tick)  "
        waited=$((waited + 5)); tick=$((tick + 1)); sleep 5
    done
    echo ""; docker compose ps; success "All containers stable."
}

wait_for_postgres() {
    local ctr="$1" user="$2" timeout="${3:-60}" waited=0 tick=0
    log "Waiting for postgres..."
    until docker exec "${ctr}" pg_isready -U "${user}" -q 2>/dev/null; do
        [[ $waited -ge $timeout ]] && { warn "Postgres not ready after ${timeout}s."; return 1; }
        echo -ne "\r  ${waited}s  $(spin_char $tick)  "
        waited=$((waited + 3)); tick=$((tick + 1)); sleep 3
    done
    echo ""; success "Postgres is ready."
}

# compose_up: run docker compose up silently on screen (full output in log)
# Usage: compose_up "Description" [compose dir] [extra flags...]
# All docker compose up calls use this helper so:
#   - Screen shows a clean spinner line only
#   - Log file captures everything
#   - stdin is /dev/null → interactive volume-recreation prompts auto-answer N
compose_up() {
    local desc="$1"; shift
    local dir="$1";  shift   # compose dir (cd into it)
    local tick=0
    log "${desc}..."
    (
        cd "${dir}"
        # stdin from /dev/null → auto-answers "N" to any interactive prompts
        # (e.g. "Volume X exists but doesn't match configuration. Recreate?")
        docker compose "$@" up -d --remove-orphans --quiet-pull < /dev/null
    ) >> "${LOG_FILE}" 2>&1 &
    local pid=$!
    while kill -0 $pid 2>/dev/null; do
        echo -ne "\r  ${desc}  $(spin_char $tick)  (output in log)"
        tick=$((tick + 1)); sleep 3
    done
    wait $pid
    local rc=$?
    echo ""
    [[ $rc -eq 0 ]] && success "${desc} complete." || { error "${desc} failed — check log: ${LOG_FILE}"; }
}

compose_up "Starting Timesketch" "${TS_DIR}"
log "Waiting for Timesketch containers to stabilise..."
wait_for_healthy "${TS_DIR}" 180
success "Timesketch stack running."

# =============================================================================
# SECTION 3 — Verify Timesketch + Create Admin
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}======================================================${NC}"
echo -e "${CYAN}${BOLD} SECTION 3 — Verify Timesketch + Create Admin${NC}"
echo -e "${CYAN}${BOLD}======================================================${NC}"
section_desc "Wait for nginx on :80 · create admin user (${TS_ADMIN_USER} / ${TS_ADMIN_PASS})"

cd "${TS_DIR}"

log "Waiting for Timesketch on port 80 (up to 120s)..."
WAIT_SECS=0; TICK=0; TS_HTTP="000"
until [[ "$TS_HTTP" =~ ^(200|302)$ ]]; do
    [[ $WAIT_SECS -ge 120 ]] && { warn "Not reachable after 120s (HTTP ${TS_HTTP}) — continuing."; break; }
    echo -ne "\r  ${WAIT_SECS}s — HTTP ${TS_HTTP}  $(spin_char $TICK)  "
    sleep 5; WAIT_SECS=$((WAIT_SECS + 5)); TICK=$((TICK + 1))
    TS_HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://localhost 2>/dev/null || echo "000")
done
echo ""
[[ "$TS_HTTP" =~ ^(200|302)$ ]] \
    && success "Timesketch reachable on :80 (HTTP ${TS_HTTP})." \
    || warn "Timesketch HTTP ${TS_HTTP} — still initialising."

log "Detecting Timesketch web container..."
TS_WEB=$(docker ps --format '{{.Names}}' \
    | grep -i 'timesketch.*web\|web.*timesketch' | head -1 || true)
[[ -z "$TS_WEB" ]] && error "Cannot find timesketch-web container."
log "Container: ${TS_WEB}"

log "Creating Timesketch admin user..."
docker exec "${TS_WEB}" tsctl create-user "${TS_ADMIN_USER}" \
    --password "${TS_ADMIN_PASS}" \
    && success "Admin user created." \
    || warn "Admin may already exist — continuing."

success "Timesketch ready."

# =============================================================================
# SECTION 4 — Install OpenRelik
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}======================================================${NC}"
echo -e "${CYAN}${BOLD} SECTION 4 — Install OpenRelik${NC}"
echo -e "${CYAN}${BOLD}======================================================${NC}"
section_desc "Download installer · run from /opt (creates /opt/openrelik/) · capture generated password"

# Run from /opt → installer creates /opt/openrelik/ (no nesting)
cd /opt

log "Downloading OpenRelik installer..."
curl -fsSL -o /tmp/openrelik_install.sh \
    https://raw.githubusercontent.com/openrelik/openrelik-deploy/main/docker/install.sh
chmod +x /tmp/openrelik_install.sh

OR_INSTALL_LOG="/tmp/openrelik_install_$$.log"
log "Running OpenRelik installer (option 1 = stable) — Docker pull progress below..."
echo "1" | bash /tmp/openrelik_install.sh 2>&1 | tee "${OR_INSTALL_LOG}" \
    || warn "Installer exited non-zero — checking state."

# Strip ANSI codes before grepping for password
OR_ADMIN_PASS=$(sed 's/\x1B\[[0-9;]*[mK]//g' "${OR_INSTALL_LOG}" \
    | grep -oP '(?<=Password:\s)\S+' | head -1 || true)

if [[ -n "${OR_ADMIN_PASS}" ]]; then
    success "Captured installer-generated admin password."
else
    warn "Could not extract password — generating fallback."
    OR_ADMIN_PASS="$(openssl rand -base64 12 | tr -d '=+/')"
    warn "Fallback password: ${OR_ADMIN_PASS} (you may need to reset manually)"
fi

success "OpenRelik installer complete."

# =============================================================================
# SECTION 5 — Locate .env + Verify OpenRelik Stack
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}======================================================${NC}"
echo -e "${CYAN}${BOLD} SECTION 5 — Locate .env + Verify OpenRelik Stack${NC}"
echo -e "${CYAN}${BOLD}======================================================${NC}"
section_desc "Find .env · validate schema · ensure stack healthy · verify postgres and DB migrations"

log "Locating .env..."
ENV_FILE=$(find "${OR_DIR}" -maxdepth 3 -name ".env" \
    -not -path "*/.git/*" 2>/dev/null | head -1 || true)

if [[ -z "${ENV_FILE}" ]]; then
    # Fallback: check running server container's working dir
    OR_CWD=$(docker inspect openrelik-server \
        --format '{{.Config.WorkingDir}}' 2>/dev/null || true)
    [[ -n "${OR_CWD}" ]] && log "Server working dir hint: ${OR_CWD}"
    error ".env not found under ${OR_DIR} — installer may have failed."
fi

OR_COMPOSE_DIR=$(dirname "${ENV_FILE}")
log ".env:         ${ENV_FILE}"
log "Compose dir:  ${OR_COMPOSE_DIR}"
cd "${OR_COMPOSE_DIR}"

[[ -f "docker-compose.yml" ]] \
    || error "docker-compose.yml not found at ${OR_COMPOSE_DIR}"

log "Checking .env completeness..."
while IFS= read -r VAR; do
    [[ -z "$VAR" ]] && continue
    grep -q "^${VAR}=" "${ENV_FILE}" && continue
    warn "${VAR} missing — adding default."
    case "$VAR" in
        POSTGRES_DATA_PATH) echo "${VAR}=${OR_COMPOSE_DIR}/postgres-data" >> "${ENV_FILE}" ;;
        *)                  echo "${VAR}=latest" >> "${ENV_FILE}" ;;
    esac
done <<< "$(grep -oE '\$\{[A-Z_]+\}' docker-compose.yml | tr -d '${}' | sort -u)"

log "Final .env:"
cat "${ENV_FILE}"
source "${ENV_FILE}"

log "Validating OpenRelik compose schema..."
docker compose config --quiet && success "OpenRelik compose schema OK."

log "Checking running containers..."
RUNNING_COUNT=$(docker compose ps --format '{{.State}}' 2>/dev/null \
    | grep -c 'running' || echo "0")
log "Running containers: ${RUNNING_COUNT}"
[[ "${RUNNING_COUNT}" -lt 3 ]] && {
    warn "Fewer than 3 running — starting stack..."
    compose_up "Starting OpenRelik" "${OR_COMPOSE_DIR}"
}

log "Waiting for OpenRelik containers to stabilise..."
wait_for_healthy "${OR_COMPOSE_DIR}" 180

OR_PG=$(docker compose ps --format '{{.Name}} {{.Service}}' 2>/dev/null \
    | awk '/postgres/{print $1}' | head -1 || true)
[[ -z "$OR_PG" ]] && OR_PG=$(docker ps --format '{{.Names}}' \
    | grep -i 'openrelik.*postgres' | head -1 || true)
log "Postgres container: ${OR_PG}"

wait_for_postgres "${OR_PG}" "${POSTGRES_USER:-openrelik}" 60

log "DB tables:"
docker exec "${OR_PG}" psql \
    -U "${POSTGRES_USER:-openrelik}" -d "${POSTGRES_DB:-openrelik}" \
    -c "\dt" 2>/dev/null || warn "Could not list tables."

success "OpenRelik stack verified."

# =============================================================================
# SECTION 6 — Confirm OpenRelik Admin
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}======================================================${NC}"
echo -e "${CYAN}${BOLD} SECTION 6 — Confirm OpenRelik Admin${NC}"
echo -e "${CYAN}${BOLD}======================================================${NC}"
section_desc "Verify admin login via POST /api/v1/auth/login on :8710"

log "Verifying OpenRelik admin login..."
OR_LOGIN=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST http://localhost:8710/api/v1/auth/login \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${OR_ADMIN_USER}\",\"password\":\"${OR_ADMIN_PASS}\"}" \
    2>/dev/null || true)
log "Login HTTP: ${OR_LOGIN}"
[[ "$OR_LOGIN" == "200" ]] \
    && success "OpenRelik admin login verified." \
    || warn "Login returned ${OR_LOGIN} — check credentials in installer output above."

success "OpenRelik ready."

# =============================================================================
# SECTION 7 — Build Hayabusa Worker Image
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}======================================================${NC}"
echo -e "${CYAN}${BOLD} SECTION 7 — Build Hayabusa Worker Image${NC}"
echo -e "${CYAN}${BOLD}======================================================${NC}"
section_desc "Clone openrelik-contrib/openrelik-worker-hayabusa · build ${OR_HAYABUSA_IMAGE} (5-15 min)"

log "Cloning openrelik-contrib/openrelik-worker-hayabusa..."
git clone --depth 1 \
    https://github.com/openrelik-contrib/openrelik-worker-hayabusa.git \
    "${OR_HAYABUSA_DIR}" \
    || error "Failed to clone openrelik-worker-hayabusa — check connectivity."

[[ -f "${OR_HAYABUSA_DIR}/Dockerfile" ]] \
    || error "No Dockerfile found in cloned repo — unexpected repo structure."

log "Building ${OR_HAYABUSA_IMAGE} (output suppressed on screen, captured in log)..."
log "This takes 5-15 minutes — progress shown below..."
echo ""

# Build with plain progress so Rust compile steps are readable in log
# but suppress the per-layer download noise on screen via log redirect
docker build \
    --progress=plain \
    -t "${OR_HAYABUSA_IMAGE}" \
    "${OR_HAYABUSA_DIR}" \
    >> "${LOG_FILE}" 2>&1 &

BUILD_PID=$!
BUILD_TICK=0
while kill -0 $BUILD_PID 2>/dev/null; do
    echo -ne "\r  Building ${OR_HAYABUSA_IMAGE}...  $(spin_char $BUILD_TICK)  (full output in log)"
    BUILD_TICK=$((BUILD_TICK + 1))
    sleep 3
done
wait $BUILD_PID || error "Hayabusa worker build failed — check log: ${LOG_FILE}"
echo ""

log "Verifying image..."
docker images --format "  {{.Repository}}:{{.Tag}}  ({{.Size}})" \
    | grep hayabusa \
    || warn "Image not found in list — check build output in log."

success "Hayabusa worker image built."

# =============================================================================
# SECTION 8 — Network Integration
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}======================================================${NC}"
echo -e "${CYAN}${BOLD} SECTION 8 — Network Integration${NC}"
echo -e "${CYAN}${BOLD}======================================================${NC}"
section_desc "Connect timesketch-web to ${OR_NETWORK} · write Timesketch override for reboot persistence"

# Connect timesketch-web to OpenRelik's internal network so all OpenRelik
# containers can reach it at http://timesketch-web:5000 via Docker DNS.
log "Connecting timesketch-web to ${OR_NETWORK}..."
if docker network inspect "${OR_NETWORK}" &>/dev/null; then
    docker network connect "${OR_NETWORK}" timesketch-web 2>/dev/null \
        && success "timesketch-web connected to ${OR_NETWORK}." \
        || log "timesketch-web already on ${OR_NETWORK}."
else
    warn "${OR_NETWORK} not found — OpenRelik may not be running yet."
fi

# Write a Timesketch override that makes this connection permanent.
# On every `docker compose up -d`, timesketch-web will automatically
# rejoin openrelik_default without needing a manual docker network connect.
log "Writing Timesketch override for network persistence..."
cat > "${TS_DIR}/docker-compose.override.yml" << YAMLEOF
# Auto-generated by install_stack.sh
# Connects timesketch-web to OpenRelik's network so workers can reach
# Timesketch at http://timesketch-web:5000 via Docker internal DNS.
networks:
  ${OR_NETWORK}:
    external: true

services:
  timesketch-web:
    networks:
      default:
      ${OR_NETWORK}:
YAMLEOF

log "Validating Timesketch override schema..."
docker compose \
    -f "${TS_DIR}/docker-compose.yml" \
    -f "${TS_DIR}/docker-compose.override.yml" \
    config --quiet \
    && success "Timesketch override schema OK." \
    || warn "Override validation warning — check schema above."

success "Network integration complete."

# =============================================================================
# SECTION 9 — OpenRelik Compose Override (workers)
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}======================================================${NC}"
echo -e "${CYAN}${BOLD} SECTION 9 — OpenRelik Worker Override${NC}"
echo -e "${CYAN}${BOLD}======================================================${NC}"
section_desc "Write docker-compose.override.yml: Timesketch worker + Hayabusa worker"

cd "${OR_COMPOSE_DIR}"

# Read the OPENRELIK_WORKER_TIMESKETCH_VERSION from .env if it exists,
# otherwise fall back to 'latest' so the compose file resolves.
OR_TS_WORKER_VER="${OPENRELIK_WORKER_TIMESKETCH_VERSION:-latest}"

log "Writing ${OR_COMPOSE_DIR}/docker-compose.override.yml..."
cat > "${OR_COMPOSE_DIR}/docker-compose.override.yml" << YAMLEOF
# Auto-generated by install_stack.sh
# Adds two workers to the OpenRelik stack:
#   openrelik-worker-timesketch — pushes timelines to Timesketch
#   openrelik-worker-hayabusa   — runs Hayabusa on EVTX files (local image)

services:
  openrelik-worker-timesketch:
    container_name: openrelik-worker-timesketch
    image: ghcr.io/openrelik/openrelik-worker-timesketch:${OR_TS_WORKER_VER}
    restart: always
    environment:
      - REDIS_URL=redis://openrelik-redis:6379
      - TIMESKETCH_SERVER_URL=http://timesketch-web:5000
      - TIMESKETCH_SERVER_PUBLIC_URL=http://127.0.0.1
      - TIMESKETCH_USERNAME=${TS_ADMIN_USER}
      - TIMESKETCH_PASSWORD=${TS_ADMIN_PASS}
    volumes:
      - ./data:/usr/share/openrelik/data
    command: "celery --app=src.app worker --task-events --concurrency=1 --loglevel=INFO -Q openrelik-worker-timesketch"

  openrelik-worker-hayabusa:
    container_name: openrelik-worker-hayabusa
    image: ${OR_HAYABUSA_IMAGE}
    restart: always
    environment:
      - REDIS_URL=redis://openrelik-redis:6379
    volumes:
      - ./data:/usr/share/openrelik/data
    command: "celery --app=src.app worker --task-events --concurrency=4 --loglevel=INFO -Q openrelik-worker-hayabusa"
YAMLEOF

log "Validating override schema..."
docker compose \
    -f "${OR_COMPOSE_DIR}/docker-compose.yml" \
    -f "${OR_COMPOSE_DIR}/docker-compose.override.yml" \
    config --quiet \
    && success "OpenRelik override schema OK." \
    || error "Override schema invalid — check output above."

success "OpenRelik override written."

# =============================================================================
# SECTION 10 — Apply Overrides + Final Restart
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}======================================================${NC}"
echo -e "${CYAN}${BOLD} SECTION 10 — Apply Overrides + Final Restart${NC}"
echo -e "${CYAN}${BOLD}======================================================${NC}"
section_desc "Restart Timesketch with override · restart OpenRelik with workers · verify all healthy"

compose_up "Restarting Timesketch with network override" "${TS_DIR}" \
    -f docker-compose.yml -f docker-compose.override.yml
log "Waiting for Timesketch to stabilise..."
wait_for_healthy "${TS_DIR}" 120

# Pre-remove any named prometheus volumes that may have stale host-path
# config from a previous install — prevents the interactive
# "Volume exists but doesn't match configuration. Recreate?" prompt.
log "Removing stale prometheus volumes (if any)..."
docker volume rm openrelik_prometheus-data openrelik_prometheus-config 2>/dev/null \
    && log "Stale volumes removed." || log "No stale volumes found."

compose_up "Restarting OpenRelik with worker override" "${OR_COMPOSE_DIR}" \
    -f docker-compose.yml -f docker-compose.override.yml
log "Waiting for OpenRelik to stabilise..."
wait_for_healthy "${OR_COMPOSE_DIR}" 120

# Write startup scripts — both reference the correct override file
cat > "${TS_DIR}/start.sh" << EOF
#!/usr/bin/env bash
# Start Timesketch (with network override for OpenRelik integration)
cd ${TS_DIR}
docker compose -f docker-compose.yml -f docker-compose.override.yml up -d
EOF
chmod +x "${TS_DIR}/start.sh"

cat > "${OR_COMPOSE_DIR}/start.sh" << EOF
#!/usr/bin/env bash
# Start OpenRelik (with Timesketch + Hayabusa workers)
cd ${OR_COMPOSE_DIR}
docker compose -f docker-compose.yml -f docker-compose.override.yml up -d
EOF
chmod +x "${OR_COMPOSE_DIR}/start.sh"

success "Both stacks restarted with overrides."

# =============================================================================
# SECTION 11 — Health Check + Summary
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}======================================================${NC}"
echo -e "${CYAN}${BOLD} SECTION 11 — Health Check + Summary${NC}"
echo -e "${CYAN}${BOLD}======================================================${NC}"
section_desc "Container status · HTTP checks · DB tables · cleanup"

echo ""
log "All running containers:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo ""
log "Problem containers (exited / restarting):"
docker ps -a --filter "status=exited" --filter "status=restarting" \
    --format "table {{.Names}}\t{{.Status}}" || true

echo ""
log "Timesketch HTTP (port 80):"
curl -s -o /dev/null -w "  http://localhost → HTTP %{http_code}\n" \
    http://localhost 2>/dev/null || true

echo ""
log "OpenRelik UI HTTP (port 8711):"
curl -s -o /dev/null -w "  http://localhost:8711 → HTTP %{http_code}\n" \
    http://localhost:8711 2>/dev/null || true

echo ""
log "OpenRelik API HTTP (port 8710):"
curl -s -o /dev/null -w "  http://localhost:8710 → HTTP %{http_code}\n" \
    http://localhost:8710 2>/dev/null || true

echo ""
log "Verifying timesketch-web is on ${OR_NETWORK}:"
docker network inspect "${OR_NETWORK}" \
    --format '  {{range .Containers}}{{.Name}}  {{end}}' 2>/dev/null \
    | tr ' ' '\n' | grep -v '^$' | sed 's/^/  /' \
    || warn "${OR_NETWORK} not found."

echo ""
log "OpenRelik DB tables:"
OR_PG_FINAL=$(docker ps --format '{{.Names}}' \
    | grep -i 'openrelik.*postgres' | head -1 || true)
[[ -n "$OR_PG_FINAL" ]] && docker exec "${OR_PG_FINAL}" psql \
    -U "${POSTGRES_USER:-openrelik}" -d "${POSTGRES_DB:-openrelik}" \
    -c "\dt" 2>/dev/null || warn "Could not list DB tables."

log "Cleaning up temp files..."
rm -f /tmp/deploy_timesketch.sh /tmp/openrelik_install.sh
rm -f /tmp/openrelik_install_*.log

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo -e "${GREEN}${BOLD}  DEPLOYMENT COMPLETE${NC}"
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo ""
echo -e "${CYAN}  ACCESS POINTS${NC}"
echo "  ┌──────────────────────────────────────────────────────┐"
echo "  │  Timesketch   http://localhost         (port 80)     │"
echo "  │  OpenRelik    http://localhost:8711    (UI)          │"
echo "  │               http://localhost:8710    (API)         │"
echo "  └──────────────────────────────────────────────────────┘"
echo ""
echo -e "${CYAN}  ACCOUNTS${NC}"
echo "  ┌──────────────────────────────────────────────────────┐"
echo "  │  System       Username    Password                   │"
echo "  │  ──────────── ─────────   ─────────────────────────  │"
printf "  │  Timesketch   %-10s %-26s │\n" "${TS_ADMIN_USER}" "${TS_ADMIN_PASS}"
printf "  │  OpenRelik    %-10s %-26s │\n" "${OR_ADMIN_USER}" "${OR_ADMIN_PASS}"
echo "  └──────────────────────────────────────────────────────┘"
echo ""
echo -e "${CYAN}  WORKERS${NC}"
echo "  ┌──────────────────────────────────────────────────────┐"
echo "  │  openrelik-worker-timesketch  (pushes to Timesketch) │"
echo "  │  openrelik-worker-hayabusa    (EVTX triage)          │"
echo "  └──────────────────────────────────────────────────────┘"
echo ""
echo -e "${CYAN}  NETWORK INTEGRATION${NC}"
echo "  timesketch-web is on ${OR_NETWORK}"
echo "  Workers reach Timesketch at http://timesketch-web:5000"
echo ""
echo -e "${CYAN}  STARTUP SCRIPTS (after reboot)${NC}"
echo "    ${TS_DIR}/start.sh"
echo "    ${OR_COMPOSE_DIR}/start.sh"
echo ""
echo -e "${CYAN}  INSTALLATION LOG${NC}"
echo "    ${LOG_FILE}"
echo ""
echo "  Finished: $(date)"
echo -e "${GREEN}${BOLD}============================================================${NC}"