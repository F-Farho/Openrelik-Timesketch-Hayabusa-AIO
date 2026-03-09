#!/usr/bin/env bash
# =============================================================================
# Full Stack Installer: Timesketch + OpenRelik 0.7.0
# =============================================================================
# Run with: sudo bash install_stack.sh
#
# Design:
#   - Both installers run from /opt to avoid nested directories
#       /opt/timesketch/   ← Timesketch compose dir
#       /opt/openrelik/    ← OpenRelik compose dir
#   - Official compose files and ports are never modified
#   - Integration: timesketch‑web joins openrelik_default network
#       → workers reach Timesketch at http://timesketch-web:5000
#   - This script assumes the selected OpenRelik release compose already defines
#     the baseline OpenRelik services/workers it needs.
#   - docker‑compose.override.yml does two things only:
#       1. Patches openrelik-worker-timesketch with Timesketch credentials
#       2. Adds extra workers: floss · capa · llm (+ ollama for llm)
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

# Spinner
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

TS_DIR="/opt/timesketch"
OR_DIR="/opt/openrelik"

OR_NETWORK="openrelik_default"

# OpenRelik release handling
# This script targets 0.7.0 explicitly. If upstream changes the menu ordering,
# we derive the correct menu selection from install.sh instead of hardcoding it.
OR_TARGET_RELEASE="0.7.0"
OR_RELEASE_CHOICE=""
OR_SELECTED_RELEASE=""
OR_EXPECTED_CONFIG_FILE=""
OR_EXPECTED_COMPOSE_FILE=""
OR_BASE_DEPLOY_URL="https://raw.githubusercontent.com/openrelik/openrelik-deploy/main/docker"

# =============================================================================
# Helpers
# =============================================================================
wait_for_healthy() {
    local dir="$1" timeout="${2:-180}" waited=0 tick=0
    cd "${dir}"
    until ! docker compose ps 2>/dev/null | grep -qE 'starting|restarting|unhealthy'; do
        [[ $waited -ge $timeout ]] && { warn "Timeout. State:"; docker compose ps; return 1; }
        echo -ne "\r  ${waited}s / ${timeout}s  $(spin_char $tick)  "
        waited=$((waited + 5)); tick=$((tick + 1)); sleep 5
    done
    echo ""
    docker compose ps
    success "All containers stable."
}

wait_for_postgres() {
    local ctr="$1" user="$2" timeout="${3:-60}" waited=0 tick=0
    log "Waiting for postgres..."
    until docker exec "${ctr}" pg_isready -U "${user}" -q 2>/dev/null; do
        [[ $waited -ge $timeout ]] && { warn "Postgres not ready after ${timeout}s."; return 1; }
        echo -ne "\r  ${waited}s  $(spin_char $tick)  "
        waited=$((waited + 3)); tick=$((tick + 1)); sleep 3
    done
    echo ""
    success "Postgres is ready."
}

compose_up() {
    local desc="$1"; shift
    local dir="$1";  shift
    local tick=0
    log "${desc}..."
    (
        cd "${dir}"
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

is_http_error_body() {
    local file="$1"
    [[ ! -s "${file}" ]] && return 0
    head -5 "${file}" | grep -qiE '^(404|not found|error|<html|<!doctype html)' && return 0
    return 1
}

# Resolves the actual filename to use for a given base name by checking if the
# exact file exists upstream. If not, it searches for an RC variant
# (e.g. config_0.7.0-rc.1.env) and returns that instead.
resolve_filename() {
    local base_url="$1"
    local filename="$2"
    local status

    status="$(curl -s -o /dev/null -w "%{http_code}" "${base_url}/${filename}" || true)"
    if [[ "${status}" == "200" ]]; then
        echo "${filename}"
        return
    fi

    local stem="${filename%.*}"
    local ext=".${filename##*.}"
    local rc_num
    local rc_filename

    for rc_num in $(seq 1 9); do
        rc_filename="${stem}-rc.${rc_num}${ext}"
        status="$(curl -s -o /dev/null -w "%{http_code}" "${base_url}/${rc_filename}" || true)"
        if [[ "${status}" == "200" ]]; then
            echo "${rc_filename}"
            return
        fi
    done

    # No variant found, return original and let normal recovery continue.
    echo "${filename}"
}

download_first_valid() {
    local dest="$1"; shift
    local kind="${1:-generic}"
    shift
    local tmp

    for url in "$@"; do
        tmp="$(mktemp)"
        log "Trying ${url}"
        if curl -fsSL "${url}" -o "${tmp}"; then
            if ! is_http_error_body "${tmp}"; then
                if [[ "${kind}" == "config" ]] && grep -qE '=<REPLACE_WITH_[A-Z0-9_]+>' "${tmp}"; then
                    warn "Rejected ${url}: contains placeholder values."
                    rm -f "${tmp}"
                    continue
                fi
                if [[ "${kind}" == "compose" ]] && ! grep -qE '^services:' "${tmp}"; then
                    warn "Rejected ${url}: missing compose services block."
                    rm -f "${tmp}"
                    continue
                fi
                mv "${tmp}" "${dest}"
                success "Downloaded valid file to ${dest}"
                return 0
            fi
            warn "Downloaded body from ${url} looked invalid."
        else
            warn "Download failed: ${url}"
        fi
        rm -f "${tmp}"
    done

    return 1
}

resolve_openrelik_release_selection() {
    local install_src="$1"
    local latest_release releases_blob release
    local other_idx=0

    latest_release="$(grep -oP 'LATEST_RELEASE="\K[^"]+' "${install_src}" | head -1 || true)"
    [[ -z "${latest_release}" ]] && latest_release="0.7.0"

    if [[ "${OR_TARGET_RELEASE}" == "latest" ]]; then
        OR_RELEASE_CHOICE="2"
        OR_SELECTED_RELEASE="latest"
    elif [[ "${OR_TARGET_RELEASE}" == "${latest_release}" ]]; then
        OR_RELEASE_CHOICE="1"
        OR_SELECTED_RELEASE="${latest_release}"
    else
        releases_blob="$(grep -oP 'RELEASES=\(\K[^)]+' "${install_src}" | head -1 || true)"
        if [[ -n "${releases_blob}" ]]; then
            while read -r release; do
                [[ -z "${release}" ]] && continue
                [[ "${release}" == "${latest_release}" ]] && continue
                other_idx=$((other_idx + 1))
                if [[ "${release}" == "${OR_TARGET_RELEASE}" ]]; then
                    OR_RELEASE_CHOICE="$((other_idx + 2))"
                    OR_SELECTED_RELEASE="${release}"
                    break
                fi
            done < <(printf '%s\n' "${releases_blob}" | grep -oE '"[^"]+"' | tr -d '"')
        fi
    fi

    [[ -z "${OR_SELECTED_RELEASE}" ]] && error "Target OpenRelik release ${OR_TARGET_RELEASE} not found in installer menu."

    if [[ "${OR_SELECTED_RELEASE}" == "latest" ]]; then
        OR_EXPECTED_CONFIG_FILE="config_latest.env"
        OR_EXPECTED_COMPOSE_FILE="docker-compose_latest.yml"
    else
        OR_EXPECTED_CONFIG_FILE="config_${OR_SELECTED_RELEASE}.env"
        OR_EXPECTED_COMPOSE_FILE="docker-compose_${OR_SELECTED_RELEASE}.yml"
    fi

    log "Target OpenRelik release: ${OR_SELECTED_RELEASE}"
    log "Installer menu choice:     ${OR_RELEASE_CHOICE}"
    log "Expected config file:      ${OR_EXPECTED_CONFIG_FILE}"
    log "Expected compose file:     ${OR_EXPECTED_COMPOSE_FILE}"
}

repair_openrelik_deploy_file_if_needed() {
    local local_name="$1"
    local file_type="$2"
    local local_path="${OR_DIR}/${local_name}"
    local selected="${OR_SELECTED_RELEASE}"
    local -a candidates=()
    local -a urls=()
    local c
    local rc
    local resolved_primary=""
    local expected_file=""

    if [[ -s "${local_path}" ]] && ! is_http_error_body "${local_path}"; then
        success "${local_name} looks valid."
        return 0
    fi

    warn "${local_name} missing or invalid — attempting recovery..."

    if [[ "${file_type}" == "config" ]]; then
        expected_file="${OR_EXPECTED_CONFIG_FILE}"
    elif [[ "${file_type}" == "compose" ]]; then
        expected_file="${OR_EXPECTED_COMPOSE_FILE}"
    fi
    if [[ -n "${expected_file}" ]]; then
        resolved_primary="$(resolve_filename "${OR_BASE_DEPLOY_URL}" "${expected_file}")"
        [[ -n "${resolved_primary}" ]] && candidates+=("${resolved_primary}")
    fi

    if [[ "${file_type}" == "config" ]]; then
        if [[ "${selected}" == "latest" ]]; then
            candidates+=("config_latest.env" "config-latest.env")
        else
            # OpenRelik release files may be published as rc even when menu
            # shows stable release text (example: config_0.7.0-rc.1.env).
            for rc in 1 2 3 4 5 6 7 8 9 10; do
                candidates+=("config_${selected}-rc.${rc}.env" "config-${selected}-rc.${rc}.env")
            done
            candidates+=("config_${selected}.env" "config-${selected}.env")
        fi
        candidates+=("config.env" "config_latest.env")
    elif [[ "${file_type}" == "compose" ]]; then
        if [[ "${selected}" == "latest" ]]; then
            candidates+=("docker-compose_latest.yml" "docker-compose_latest.yaml" "docker-compose-latest.yml" "docker-compose-latest.yaml")
        else
            # Match documented rc naming first, then stable names.
            for rc in 1 2 3 4 5 6 7 8 9 10; do
                candidates+=("docker-compose_${selected}-rc.${rc}.yml" "docker-compose_${selected}-rc.${rc}.yaml" "docker-compose-${selected}-rc.${rc}.yml" "docker-compose-${selected}-rc.${rc}.yaml")
            done
            candidates+=("docker-compose_${selected}.yml" "docker-compose_${selected}.yaml" "docker-compose-${selected}.yml" "docker-compose-${selected}.yaml")
        fi
        candidates+=("docker-compose.yml" "docker-compose.yaml" "docker-compose_latest.yml")
    else
        error "Unknown recovery type: ${file_type}"
    fi

    # Build URL list with de-duplication while preserving order.
    for c in "${candidates[@]}"; do
        [[ -z "${c}" ]] && continue
        [[ " ${urls[*]} " == *" ${OR_BASE_DEPLOY_URL}/${c} "* ]] && continue
        urls+=("${OR_BASE_DEPLOY_URL}/${c}")
    done

    download_first_valid "${local_path}" "${file_type}" "${urls[@]}" \
        || error "Failed to recover ${local_name}. Check access to raw.githubusercontent.com and upstream OpenRelik deploy filenames."
}

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
rm -rf /opt/timesketch /opt/openrelik \
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
section_desc "Download installer · patch health‑check timeout · run from /opt · create data dirs · start stack"

log "Downloading Timesketch installer..."
curl -fsSL -o /tmp/deploy_timesketch.sh \
    https://raw.githubusercontent.com/google/timesketch/master/contrib/deploy_timesketch.sh
chmod +x /tmp/deploy_timesketch.sh

log "Patching health‑check timeout (300s → 10s)..."
sed -i 's/TIMEOUT=300/TIMEOUT=10/' /tmp/deploy_timesketch.sh

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

log "Pre‑creating data directories with correct ownership..."
mkdir -p "${POSTGRES_DATA_PATH:-./postgres-data}" ./logs ./upload ./prometheus-data
chown -R 999:999    "${POSTGRES_DATA_PATH:-./postgres-data}"
chown -R 65534:65534 ./prometheus-data

log "Validating compose schema..."
docker compose config --quiet \
    && success "Timesketch compose schema OK."

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
[[ -z "$TS_WEB" ]] && error "Cannot find timesketch‑web container."
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
section_desc "Download installer · derive correct menu choice for target release · run from /opt · validate/repair deploy files · capture generated password"

cd /opt

log "Downloading OpenRelik installer..."
curl -fsSL -o /tmp/openrelik_install.sh \
    https://raw.githubusercontent.com/openrelik/openrelik-deploy/main/docker/install.sh
chmod +x /tmp/openrelik_install.sh

resolve_openrelik_release_selection "/tmp/openrelik_install.sh"

OR_INSTALL_LOG="/tmp/openrelik_install_$$.log"
log "Running OpenRelik installer — Docker pull progress below..."
printf '%s\n' "${OR_RELEASE_CHOICE}" | bash /tmp/openrelik_install.sh 2>&1 | tee "${OR_INSTALL_LOG}" \
    || warn "Installer exited non‑zero — checking state."

# The installer downloads release‑specific files and writes them locally as:
#   /opt/openrelik/config.env
#   /opt/openrelik/docker-compose.yml
# If curl inside the installer saved an HTTP error body instead of a real file,
# repair them here using the release‑aware filenames we derived above.
repair_openrelik_deploy_file_if_needed "config.env" "config"
repair_openrelik_deploy_file_if_needed "docker-compose.yml" "compose"

OR_ADMIN_PASS=$(sed 's/\x1B\[[0-9;]*[mK]//g' "${OR_INSTALL_LOG}" \
    | grep -oP '(?<=Password:\s)\S+' | head -1 || true)

if [[ -n "${OR_ADMIN_PASS}" ]]; then
    success "Captured installer‑generated admin password."
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

if grep -qE '=<REPLACE_WITH_[A-Z0-9_]+>' "${ENV_FILE}"; then
    error ".env still contains placeholder values (<REPLACE_WITH_...>). OpenRelik deploy file does not match selected release."
fi

POSTGRES_USER=$(grep -E '^POSTGRES_USER=' "${ENV_FILE}" | tail -1 | cut -d'=' -f2-)
POSTGRES_DB=$(grep -E '^POSTGRES_DB=' "${ENV_FILE}" | tail -1 | cut -d'=' -f2-)

log "Validating OpenRelik compose schema..."
docker compose config --quiet && success "OpenRelik compose schema OK."

log "Checking running containers..."
RUNNING_COUNT=$(docker compose ps --format '{{.State}}' 2>/dev/null \
    | awk 'BEGIN{c=0} /running/{c++} END{print c+0}')
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
# SECTION 7 — Network Integration
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}======================================================${NC}"
echo -e "${CYAN}${BOLD} SECTION 7 — Network Integration${NC}"
echo -e "${CYAN}${BOLD}======================================================${NC}"
section_desc "Connect timesketch‑web to ${OR_NETWORK} · write Timesketch override for reboot persistence"

log "Connecting timesketch‑web to ${OR_NETWORK}..."
if docker network inspect "${OR_NETWORK}" &>/dev/null; then
    docker network connect "${OR_NETWORK}" timesketch-web 2>/dev/null \
        && success "timesketch‑web connected to ${OR_NETWORK}." \
        || log "timesketch‑web already on ${OR_NETWORK}."
else
    warn "${OR_NETWORK} not found — OpenRelik may not be running yet."
fi

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
# SECTION 8 — OpenRelik Compose Override (patch + extra workers)
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}======================================================${NC}"
echo -e "${CYAN}${BOLD} SECTION 8 — OpenRelik Worker Override${NC}"
echo -e "${CYAN}${BOLD}======================================================${NC}"
section_desc "Patch openrelik-worker-timesketch with TS credentials · add floss · capa · llm + ollama"

cd "${OR_COMPOSE_DIR}"

# This override assumes the base OpenRelik compose already defines
# openrelik-worker-timesketch. If upstream removes or renames it,
# docker compose config validation below will fail fast.
OR_FLOSS_VER="${OPENRELIK_WORKER_FLOSS_VERSION:-latest}"
OR_CAPA_VER="${OPENRELIK_WORKER_CAPA_VERSION:-latest}"
OR_LLM_VER="${OPENRELIK_WORKER_LLM_VERSION:-latest}"

log "Writing ${OR_COMPOSE_DIR}/docker-compose.override.yml..."
cat > "${OR_COMPOSE_DIR}/docker-compose.override.yml" << YAMLEOF
# Auto-generated by install_stack.sh
#
# 1. Patches openrelik-worker-timesketch with Timesketch credentials.
#    This assumes the base compose already defines the service.
#
# 2. Adds extra workers:
#    openrelik-worker-floss  — FLARE Obfuscated String Solver
#    openrelik-worker-capa   — capability detection for executables
#    openrelik-worker-llm    — prompt-driven file analysis via Ollama
#    openrelik-ollama        — Ollama backend for the llm worker
#
# NOTE: Pull an Ollama model before using the llm worker:
#   docker exec openrelik-ollama ollama pull llama3

services:

  openrelik-worker-timesketch:
    environment:
      - TIMESKETCH_SERVER_URL=http://timesketch-web:5000
      - TIMESKETCH_SERVER_PUBLIC_URL=http://127.0.0.1
      - TIMESKETCH_USERNAME=${TS_ADMIN_USER}
      - TIMESKETCH_PASSWORD=${TS_ADMIN_PASS}

  openrelik-worker-floss:
    container_name: openrelik-worker-floss
    image: ghcr.io/openrelik/openrelik-worker-floss:${OR_FLOSS_VER}
    restart: always
    environment:
      - REDIS_URL=redis://openrelik-redis:6379
    volumes:
      - ./data:/usr/share/openrelik/data
    command: "celery --app=src.app worker --task-events --concurrency=2 --loglevel=INFO -Q openrelik-worker-floss"

  openrelik-worker-capa:
    container_name: openrelik-worker-capa
    image: ghcr.io/openrelik/openrelik-worker-capa:${OR_CAPA_VER}
    restart: always
    environment:
      - REDIS_URL=redis://openrelik-redis:6379
    volumes:
      - ./data:/usr/share/openrelik/data
    command: "celery --app=src.app worker --task-events --concurrency=2 --loglevel=INFO -Q openrelik-worker-capa"

  openrelik-ollama:
    container_name: openrelik-ollama
    image: ollama/ollama:latest
    restart: always
    volumes:
      - ollama-data:/root/.ollama
    # GPU: uncomment the deploy block below if the host has an NVIDIA GPU.
    # deploy:
    #   resources:
    #     reservations:
    #       devices:
    #         - driver: nvidia
    #           count: all
    #           capabilities: [gpu]

  openrelik-worker-llm:
    container_name: openrelik-worker-llm
    image: ghcr.io/openrelik/openrelik-worker-llm:${OR_LLM_VER}
    restart: always
    environment:
      - REDIS_URL=redis://openrelik-redis:6379
      - OLLAMA_HOST=http://openrelik-ollama:11434
    volumes:
      - ./data:/usr/share/openrelik/data
    depends_on:
      - openrelik-ollama
    command: "celery --app=src.app worker --task-events --concurrency=1 --loglevel=INFO -Q openrelik-worker-llm"

volumes:
  ollama-data:
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
# SECTION 9 — Apply Overrides + Final Restart
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}======================================================${NC}"
echo -e "${CYAN}${BOLD} SECTION 9 — Apply Overrides + Final Restart${NC}"
echo -e "${CYAN}${BOLD}======================================================${NC}"
section_desc "Restart Timesketch with network override · restart OpenRelik with workers · verify all healthy"

compose_up "Restarting Timesketch with network override" "${TS_DIR}" \
    -f docker-compose.yml -f docker-compose.override.yml
log "Waiting for Timesketch to stabilise..."
wait_for_healthy "${TS_DIR}" 120

log "Removing stale prometheus volumes (if any)..."
docker volume rm openrelik_prometheus-data openrelik_prometheus-config 2>/dev/null \
    && log "Stale volumes removed." || log "No stale volumes found."

compose_up "Restarting OpenRelik with worker override" "${OR_COMPOSE_DIR}" \
    -f docker-compose.yml -f docker-compose.override.yml
log "Waiting for OpenRelik to stabilise..."
wait_for_healthy "${OR_COMPOSE_DIR}" 120

cat > "${TS_DIR}/start.sh" << EOF
#!/usr/bin/env bash
# Start Timesketch (with network override for OpenRelik integration)
cd ${TS_DIR}
docker compose -f docker-compose.yml -f docker-compose.override.yml up -d
EOF
chmod +x "${TS_DIR}/start.sh"

cat > "${OR_COMPOSE_DIR}/start.sh" << EOF
#!/usr/bin/env bash
# Start OpenRelik (default workers + extra workers)
cd ${OR_COMPOSE_DIR}
docker compose -f docker-compose.yml -f docker-compose.override.yml up -d
EOF
chmod +x "${OR_COMPOSE_DIR}/start.sh"

success "Both stacks restarted with overrides."

# =============================================================================
# SECTION 10 — Health Check + Summary
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}======================================================${NC}"
echo -e "${CYAN}${BOLD} SECTION 10 — Health Check + Summary${NC}"
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
log "Verifying timesketch‑web is on ${OR_NETWORK}:"
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
echo "  ┌──────────────────────────────────────────────────────────────┐"
echo "  │  Base workers/services come from the selected OpenRelik      │"
echo "  │  release compose.                                            │"
echo "  │                                                              │"
echo "  │  Added here via override:                                    │"
echo "  │    openrelik-worker-floss       (deobfuscated strings)      │"
echo "  │    openrelik-worker-capa        (binary capabilities/ATT&CK)│"
echo "  │    openrelik-worker-llm         (LLM prompts via Ollama)    │"
echo "  │    openrelik-ollama             (Ollama backend, CPU mode)  │"
echo "  └──────────────────────────────────────────────────────────────┘"
echo ""
echo -e "${YELLOW}  NOTE: Pull an Ollama model before using the llm worker:${NC}"
echo "    docker exec openrelik-ollama ollama pull llama3"
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
