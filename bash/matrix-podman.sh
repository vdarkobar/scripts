#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID=""                             # empty = auto-assign via pvesh; set e.g. CT_ID=120 to pin
HN="matrix"
CPU=4
RAM=4096
DISK=16
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Matrix / Podman
MATRIX_DOMAIN="example.com"
APP_TZ="Europe/Berlin"
SYNAPSE_PORT=8008
ELEMENT_PORT=8080
TAGS="matrix;podman;lxc"

# Images / versions (install-time tag must be concrete semver; AUTO_UPDATE=1 moves to :latest)
SYNAPSE_IMAGE_REPO="ghcr.io/element-hq/synapse"
SYNAPSE_TAG="v1.148.0"
SYNAPSE_IMAGE="${SYNAPSE_IMAGE_REPO}:${SYNAPSE_TAG}"
POSTGRES_IMAGE="docker.io/library/postgres:18-alpine"
ELEMENT_IMAGE_REPO="docker.io/vectorim/element-web"
ELEMENT_TAG="v1.12.11"
ELEMENT_IMAGE="${ELEMENT_IMAGE_REPO}:${ELEMENT_TAG}"
REDIS_IMAGE="docker.io/library/redis:8-alpine"
DEBIAN_VERSION=13

# TURN / VoIP relay (openrelay free tier by default; 500 MB/month relay data)
# For production voice/video, replace TURN_HOST and TURN_SHARED_SECRET with your own coturn.
TURN_HOST="staticauth.openrelay.metered.ca"
TURN_SHARED_SECRET="openrelayprojectsecret"
TURN_USER_LIFETIME_MS=86400000
TURN_ALLOW_GUESTS=0

# Element Web — MapTiler API key (empty = map feature disabled in Element)
MAPTILER_KEY=""

# Optional features
AUTO_UPDATE=0                        # 1 = timer-driven updates pull :latest for Synapse + Element on schedule

# Extra packages to install
EXTRA_PACKAGES=(
  qemu-guest-agent
)

# Behavior
CLEANUP_ON_FAIL=1

# Derived
APP_DIR="/opt/matrix"
SYNAPSE_FQDN="matrix.${MATRIX_DOMAIN}"
ELEMENT_FQDN="chat.${MATRIX_DOMAIN}"

# ── Custom configs created by this script ─────────────────────────────────────
#   /opt/matrix/docker-compose.yml         (Podman compose stack)
#   /opt/matrix/.env                       (runtime configuration)
#   /opt/matrix/element-config.json
#   /opt/matrix/element-nginx.conf
#   /opt/matrix/synapse/homeserver.yaml    (generated + patched)
#   /usr/local/bin/matrix-maint.sh         (maintenance helper)
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/systemd/system/matrix-stack.service
#   /etc/systemd/system/matrix-update.service
#   /etc/systemd/system/matrix-update.timer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/sysctl.d/99-hardening.conf

# ── Config validation ─────────────────────────────────────────────────────────
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }
[[ "$SYNAPSE_PORT" =~ ^[0-9]+$ ]] || { echo "  ERROR: SYNAPSE_PORT must be numeric." >&2; exit 1; }
(( SYNAPSE_PORT >= 1 && SYNAPSE_PORT <= 65535 )) || { echo "  ERROR: SYNAPSE_PORT must be between 1 and 65535." >&2; exit 1; }
[[ "$ELEMENT_PORT" =~ ^[0-9]+$ ]] || { echo "  ERROR: ELEMENT_PORT must be numeric." >&2; exit 1; }
(( ELEMENT_PORT >= 1 && ELEMENT_PORT <= 65535 )) || { echo "  ERROR: ELEMENT_PORT must be between 1 and 65535." >&2; exit 1; }
[[ "$AUTO_UPDATE" =~ ^[01]$ ]] || { echo "  ERROR: AUTO_UPDATE must be 0 or 1." >&2; exit 1; }
[[ "$SYNAPSE_TAG" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: SYNAPSE_TAG must be a concrete semver like v1.148.0 at install time." >&2
  echo "         (AUTO_UPDATE=1 will switch to :latest after first timer run.)" >&2
  exit 1
}
[[ "$ELEMENT_TAG" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: ELEMENT_TAG must be a concrete semver like v1.12.11 at install time." >&2
  echo "         (AUTO_UPDATE=1 will switch to :latest after first timer run.)" >&2
  exit 1
}
if [[ ! "$MATRIX_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "  ERROR: MATRIX_DOMAIN contains invalid characters: $MATRIX_DOMAIN" >&2
  exit 1
fi
[[ "$TURN_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "  ERROR: TURN_HOST contains invalid characters." >&2; exit 1; }
[[ -n "$TURN_SHARED_SECRET" ]] || { echo "  ERROR: TURN_SHARED_SECRET cannot be empty." >&2; exit 1; }
[[ "$TURN_USER_LIFETIME_MS" =~ ^[0-9]+$ ]] || { echo "  ERROR: TURN_USER_LIFETIME_MS must be numeric." >&2; exit 1; }
[[ "$TURN_ALLOW_GUESTS" =~ ^[01]$ ]] || { echo "  ERROR: TURN_ALLOW_GUESTS must be 0 or 1." >&2; exit 1; }
if [[ -n "$MAPTILER_KEY" && ! "$MAPTILER_KEY" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "  ERROR: MAPTILER_KEY contains invalid characters." >&2
  exit 1
fi

# ── Trap cleanup ──────────────────────────────────────────────────────────────
trap 'rc=$?;
  trap - ERR
  echo "  ERROR: failed (rc=$rc) near line ${BASH_LINENO[0]:-?}" >&2
  echo "  Command: $BASH_COMMAND" >&2
  if [[ "${CLEANUP_ON_FAIL:-0}" -eq 1 && "${CREATED:-0}" -eq 1 ]]; then
    echo "  Cleanup: stopping/destroying CT ${CT_ID} ..." >&2
    pct stop "${CT_ID}" >/dev/null 2>&1 || true
    pct destroy "${CT_ID}" >/dev/null 2>&1 || true
  fi
  exit "$rc"
' ERR

trap 'rc=$?;
  echo "  Interrupted (rc=$rc)" >&2
  echo "  Command: $BASH_COMMAND" >&2
  if [[ "${CLEANUP_ON_FAIL:-0}" -eq 1 && "${CREATED:-0}" -eq 1 ]]; then
    echo "  Cleanup: stopping/destroying CT ${CT_ID} ..." >&2
    pct stop "${CT_ID}" >/dev/null 2>&1 || true
    pct destroy "${CT_ID}" >/dev/null 2>&1 || true
  fi
  exit "$rc"
' INT TERM

# ── Preflight — root & commands ───────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pvesh pveam pct qm pvesm curl python3 ip awk sort paste; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

if [[ -n "$CT_ID" ]]; then
  [[ "$CT_ID" =~ ^[0-9]+$ ]] && (( CT_ID >= 100 && CT_ID <= 999999999 )) \
    || { echo "  ERROR: CT_ID must be an integer >= 100." >&2; exit 1; }
  if pct status "$CT_ID" >/dev/null 2>&1 || qm status "$CT_ID" >/dev/null 2>&1; then
    echo "  ERROR: CT_ID $CT_ID is already in use on this node." >&2
    exit 1
  fi
else
  CT_ID="$(pvesh get /cluster/nextid)"
  [[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }
fi

# ── Discover available resources ──────────────────────────────────────────────
AVAIL_TMPL_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'vztmpl' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_CT_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^vmbr' | sort | paste -sd, | sed 's/,/, /g' || echo "n/a")"

# ── Show defaults & confirm ───────────────────────────────────────────────────
cat <<EOF

  Matrix-Podman LXC Creator — Configuration
  ────────────────────────────────────────
  CT ID:             $CT_ID
  Hostname:          $HN
  CPU cores:         $CPU
  RAM (MB):          $RAM
  Disk (GB):         $DISK
  Bridge:            $BRIDGE ($AVAIL_BRIDGES)
  Template storage:  $TEMPLATE_STORAGE ($AVAIL_TMPL_STORES)
  Container storage: $CONTAINER_STORAGE ($AVAIL_CT_STORES)
  Debian:            $DEBIAN_VERSION
  Domain:            $MATRIX_DOMAIN
  Synapse FQDN:      $SYNAPSE_FQDN
  Element FQDN:      $ELEMENT_FQDN
  Synapse port:      $SYNAPSE_PORT
  Element port:      $ELEMENT_PORT
  Timezone:          $APP_TZ
  Tags:              $TAGS
  Synapse tag:       $SYNAPSE_TAG
  Element tag:       $ELEMENT_TAG
  Postgres image:    $POSTGRES_IMAGE
  Redis image:       $REDIS_IMAGE
  TURN host:         $TURN_HOST
  TURN guests:       $([ "$TURN_ALLOW_GUESTS" -eq 1 ] && echo "allowed" || echo "denied")
  MapTiler key:      $([ -n "$MAPTILER_KEY" ] && echo "set" || echo "unset (map feature disabled)")
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled (timer pulls :latest)" || echo "disabled (manual updates only)")
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/matrix-podman.sh"
SCRIPT_LOCAL="/root/matrix-podman.sh"
SCRIPT_SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

read -r -p "  Continue with these settings? [y/N]: " response
case "$response" in
  [yY][eE][sS]|[yY]) ;;
  *)
    echo ""
    echo "  Saving current script to ${SCRIPT_LOCAL} for editing..."
    if [[ -f "$SCRIPT_SELF" ]] && cp -f -- "$SCRIPT_SELF" "$SCRIPT_LOCAL"; then
      chmod +x "$SCRIPT_LOCAL"
      echo "  Edit:  nano ${SCRIPT_LOCAL}"
      echo "  Run:   bash ${SCRIPT_LOCAL}"
      echo ""
    elif curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_LOCAL"; then
      chmod +x "$SCRIPT_LOCAL"
      echo "  WARNING: Could not copy the running script; downloaded fallback from GitHub instead."
      echo "  Edit:  nano ${SCRIPT_LOCAL}"
      echo "  Run:   bash ${SCRIPT_LOCAL}"
      echo ""
    else
      echo "  ERROR: Failed to save a local editable copy of the script." >&2
    fi
    exit 0
    ;;
esac
echo ""

# ── Preflight — environment ───────────────────────────────────────────────────
pvesm status | awk -v s="$TEMPLATE_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Template storage not found: $TEMPLATE_STORAGE" >&2; exit 1; }

pvesm status | awk -v s="$CONTAINER_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Container storage not found: $CONTAINER_STORAGE" >&2; exit 1; }

ip link show "$BRIDGE" >/dev/null 2>&1 || { echo "  ERROR: Bridge not found: $BRIDGE" >&2; exit 1; }

# ── Root password ─────────────────────────────────────────────────────────────
PASSWORD=""
while true; do
  read -r -s -p "  Set root password: " PW1; echo
  if [[ -z "$PW1" ]]; then echo "  Password cannot be blank."; continue; fi
  if [[ "$PW1" == *" "* ]]; then echo "  Password cannot contain spaces."; continue; fi
  if [[ ${#PW1} -lt 8 ]]; then echo "  Password must be at least 8 characters."; continue; fi
  read -r -s -p "  Verify root password: " PW2; echo
  if [[ "$PW1" == "$PW2" ]]; then PASSWORD="$PW1"; break; fi
  echo "  Passwords do not match. Try again."
done
echo ""

# ── Template discovery & download ─────────────────────────────────────────────
pveam update
echo ""

TEMPLATE="$(pveam available -section system | awk -v p="debian-${DEBIAN_VERSION}" '$2 ~ ("^" p) {print $2}' | sort -V | tail -n1)"
if [[ -z "$TEMPLATE" ]]; then
  echo "  WARNING: No Debian ${DEBIAN_VERSION} template found, trying any Debian..." >&2
  TEMPLATE="$(pveam available -section system | awk '$2 ~ /^debian-/ {print $2}' | sort -V | tail -n1)"
fi
[[ -n "$TEMPLATE" ]] || { echo "  ERROR: No Debian template found via pveam." >&2; exit 1; }
echo "  Template: $TEMPLATE"

if [[ "$TEMPLATE_STORAGE" == "local" && -f "/var/lib/vz/template/cache/$TEMPLATE" ]]; then
  echo "  Template already present: $TEMPLATE"
else
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

# ── Create LXC ────────────────────────────────────────────────────────────────
PCT_OPTIONS=(
  -hostname "$HN"
  -cores "$CPU"
  -memory "$RAM"
  -rootfs "${CONTAINER_STORAGE}:${DISK}"
  -onboot 1
  -ostype debian
  -unprivileged 1
  -features "nesting=1,keyctl=1,fuse=1"
  -tags "$TAGS"
  -net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,ip6=manual"
  -password "$PASSWORD"
)

pct create "$CT_ID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" "${PCT_OPTIONS[@]}"
CREATED=1

# ── Start & wait for IPv4 ─────────────────────────────────────────────────────
pct start "$CT_ID"

CT_IP=""
for i in $(seq 1 30); do
  CT_IP="$(
    pct exec "$CT_ID" -- sh -lc '
      ip -4 -o addr show scope global 2>/dev/null | awk "{print \$4}" | cut -d/ -f1 | head -n1
    ' 2>/dev/null || true
  )"
  [[ -n "$CT_IP" ]] && break
  sleep 1
done
[[ -n "$CT_IP" ]] || { echo "  ERROR: No IPv4 address acquired via DHCP within timeout." >&2; exit 1; }
echo "  CT $CT_ID is up — IP: $CT_IP"

# ── OS update ─────────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  export LANG=C.UTF-8
  export LC_ALL=C.UTF-8
  systemctl disable -q --now systemd-networkd-wait-online.service 2>/dev/null || true
  apt-get update -qq
  apt-get -o Dpkg::Options::="--force-confold" -y dist-upgrade
  apt-get -y autoremove
  apt-get -y clean
'

# ── Configure locale ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y locales
  sed -i "s/^# *en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
'

# ── Remove unnecessary services ───────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  systemctl disable --now ssh 2>/dev/null || true
  systemctl disable --now postfix 2>/dev/null || true
  apt-get purge -y openssh-server postfix 2>/dev/null || true
  apt-get -y autoremove
'

# ── Set timezone ──────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  ln -sf /usr/share/zoneinfo/${APP_TZ} /etc/localtime
  echo '${APP_TZ}' > /etc/timezone
"

# ── Extra packages ────────────────────────────────────────────────────────────
if [[ "${#EXTRA_PACKAGES[@]}" -gt 0 ]]; then
  pct exec "$CT_ID" -- bash -lc "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y ${EXTRA_PACKAGES[*]}
  "
fi

# ── Install Podman ────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y podman podman-compose fuse-overlayfs curl ca-certificates iproute2 python3
'

# ── Configure storage driver ──────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  mkdir -p /etc/containers
  cat > /etc/containers/storage.conf <<EOF
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
EOF
  podman system reset --force 2>/dev/null || true
'

# ── Configure extended registries ─────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  mkdir -p /etc/containers
  cat > /etc/containers/registries.conf <<EOF
unqualified-search-registries = [
  "docker.io",
  "quay.io",
  "ghcr.io",
  "registry.fedoraproject.org",
  "registry.access.redhat.com",
  "registry.redhat.io"
]
short-name-mode = "enforcing"
EOF
'

# ── Podman log rotation ───────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  mkdir -p /etc/containers
  cat > /etc/containers/containers.conf <<EOF
[containers]
log_size_max = 10485760
EOF
'

# ── Verify ────────────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- podman info >/dev/null 2>&1
pct exec "$CT_ID" -- podman --version
pct exec "$CT_ID" -- podman-compose --version

# ── Secrets ───────────────────────────────────────────────────────────────────
DB_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 63 || true)"
REDIS_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)"
[[ ${#DB_PASSWORD} -eq 63 && ${#REDIS_PASSWORD} -eq 32 ]] || { echo "  ERROR: Failed to generate secrets." >&2; exit 1; }

# ── Prepare persistent volumes (absolute paths) ───────────────────────────────
# Verified UIDs: postgres:18-alpine=70, redis:8-alpine=999:1000, synapse (pinned)=991
echo "  Preparing persistent volumes with correct UIDs..."
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  mkdir -p /opt/matrix/postgresdata /opt/matrix/redis /opt/matrix/synapse

  chown -R 70:70 /opt/matrix/postgresdata
  chmod 700 /opt/matrix/postgresdata

  chown -R 999:1000 /opt/matrix/redis

  chown -R 991:991 /opt/matrix/synapse

  echo "  ✅ Volumes pre-created (postgres=70, redis=999:1000, synapse=991)"
'

# ── Element nginx config (port >1024 — required for unprivileged Podman) ──────
pct exec "$CT_ID" -- bash -lc 'cat > /opt/matrix/element-nginx.conf <<EOF
server {
    listen 8080;
    server_name _;

    root /app;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF'

# ── Compose file ──────────────────────────────────────────────────────────────
# Note: no :Z volume flags (Debian LXC — no SELinux)
# Note: postgres data mounted at PGDATA default (/var/lib/postgresql/data)
pct exec "$CT_ID" -- bash -lc 'cat > /opt/matrix/docker-compose.yml' <<'YAML'
networks:
  matrix:
    driver: bridge

services:

  postgres_db:
    image: ${POSTGRES_IMAGE}
    container_name: postgres_db
    restart: unless-stopped
    shm_size: 512mb
    networks:
      - matrix
    environment:
      - POSTGRES_DB=synapse
      - POSTGRES_USER=synapse
      - POSTGRES_PASSWORD=${DB_PASSWORD}
      - POSTGRES_INITDB_ARGS=--encoding=UTF8 --lc-collate=C --lc-ctype=C
      - TZ=${APP_TZ}
    volumes:
      - /opt/matrix/postgresdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U synapse -d synapse"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

  redis:
    image: ${REDIS_IMAGE}
    container_name: redis
    restart: unless-stopped
    command: >
      redis-server
      --appendonly yes
      --maxmemory 256mb
      --maxmemory-policy allkeys-lru
      --requirepass ${REDIS_PASSWORD}
    networks:
      - matrix
    volumes:
      - /opt/matrix/redis:/data
    environment:
      - TZ=${APP_TZ}
      - REDIS_PASSWORD=${REDIS_PASSWORD}
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a \"$$REDIS_PASSWORD\" ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    depends_on:
      postgres_db:
        condition: service_healthy

  synapse:
    image: ${SYNAPSE_IMAGE}
    container_name: synapse
    restart: unless-stopped
    networks:
      - matrix
    ports:
      - "${SYNAPSE_PORT}:8008"
    environment:
      - SYNAPSE_CONFIG_PATH=/data/homeserver.yaml
      - TZ=${APP_TZ}
    volumes:
      - /opt/matrix/synapse:/data
    healthcheck:
      test: ["CMD", "curl", "-fSs", "http://localhost:8008/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
    depends_on:
      postgres_db:
        condition: service_healthy
      redis:
        condition: service_healthy

  element:
    image: ${ELEMENT_IMAGE}
    container_name: element-web
    restart: unless-stopped
    networks:
      - matrix
    ports:
      - "${ELEMENT_PORT}:8080"
    volumes:
      - /opt/matrix/element-config.json:/app/config.json:ro
      - /opt/matrix/element-nginx.conf:/etc/nginx/templates/default.conf.template:ro
    depends_on:
      synapse:
        condition: service_healthy
YAML

pct exec "$CT_ID" -- chmod 600 /opt/matrix/docker-compose.yml

# ── Element config ────────────────────────────────────────────────────────────
# MapTiler key is optional; when unset, the map_style_url field is omitted
# and Element's location-sharing map feature stays disabled.
if [[ -n "$MAPTILER_KEY" ]]; then
  pct exec "$CT_ID" -- bash -lc "cat > /opt/matrix/element-config.json <<EOF
{
    \"default_server_config\": {
        \"m.homeserver\": {
            \"base_url\": \"https://matrix.${MATRIX_DOMAIN}\",
            \"server_name\": \"matrix.${MATRIX_DOMAIN}\"
        },
        \"m.identity_server\": {
            \"base_url\": \"https://vector.im\"
        }
    },
    \"brand\": \"Element\",
    \"integrations_ui_url\": \"https://scalar.vector.im/\",
    \"integrations_rest_url\": \"https://scalar.vector.im/api\",
    \"integrations_widgets_urls\": [
        \"https://scalar.vector.im/_matrix/integrations/v1\",
        \"https://scalar.vector.im/api\",
        \"https://scalar-staging.vector.im/_matrix/integrations/v1\",
        \"https://scalar-staging.vector.im/api\"
    ],
    \"showLabsSettings\": true,
    \"roomDirectory\": {
        \"servers\": [\"matrix.org\"]
    },
    \"enable_presence_by_hs_url\": {
        \"https://matrix.org\": false,
        \"https://matrix-client.matrix.org\": false
    },
    \"features\": {},
    \"map_style_url\": \"https://api.maptiler.com/maps/streets/style.json?key=${MAPTILER_KEY}\"
}
EOF"
else
  pct exec "$CT_ID" -- bash -lc "cat > /opt/matrix/element-config.json <<EOF
{
    \"default_server_config\": {
        \"m.homeserver\": {
            \"base_url\": \"https://matrix.${MATRIX_DOMAIN}\",
            \"server_name\": \"matrix.${MATRIX_DOMAIN}\"
        },
        \"m.identity_server\": {
            \"base_url\": \"https://vector.im\"
        }
    },
    \"brand\": \"Element\",
    \"integrations_ui_url\": \"https://scalar.vector.im/\",
    \"integrations_rest_url\": \"https://scalar.vector.im/api\",
    \"integrations_widgets_urls\": [
        \"https://scalar.vector.im/_matrix/integrations/v1\",
        \"https://scalar.vector.im/api\",
        \"https://scalar-staging.vector.im/_matrix/integrations/v1\",
        \"https://scalar-staging.vector.im/api\"
    ],
    \"showLabsSettings\": true,
    \"roomDirectory\": {
        \"servers\": [\"matrix.org\"]
    },
    \"enable_presence_by_hs_url\": {
        \"https://matrix.org\": false,
        \"https://matrix-client.matrix.org\": false
    },
    \"features\": {}
}
EOF"
fi

# ── .env (runtime configuration) ──────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > /opt/matrix/.env <<EOF
COMPOSE_PROJECT_NAME=matrix
APP_TZ=${APP_TZ}
MATRIX_DOMAIN=${MATRIX_DOMAIN}
SYNAPSE_FQDN=${SYNAPSE_FQDN}
ELEMENT_FQDN=${ELEMENT_FQDN}
SYNAPSE_PORT=${SYNAPSE_PORT}
ELEMENT_PORT=${ELEMENT_PORT}
SYNAPSE_IMAGE_REPO=${SYNAPSE_IMAGE_REPO}
SYNAPSE_TAG=${SYNAPSE_TAG}
SYNAPSE_IMAGE=${SYNAPSE_IMAGE}
ELEMENT_IMAGE_REPO=${ELEMENT_IMAGE_REPO}
ELEMENT_TAG=${ELEMENT_TAG}
ELEMENT_IMAGE=${ELEMENT_IMAGE}
POSTGRES_IMAGE=${POSTGRES_IMAGE}
REDIS_IMAGE=${REDIS_IMAGE}
DB_PASSWORD=${DB_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
AUTO_UPDATE=${AUTO_UPDATE}
EOF
  chmod 600 /opt/matrix/.env /opt/matrix/docker-compose.yml
"

# ── Generate Synapse homeserver.yaml ──────────────────────────────────────────
echo "  Generating Synapse configuration..."

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman run --rm \
    -v /opt/matrix/synapse:/data \
    -e SYNAPSE_SERVER_NAME='matrix.${MATRIX_DOMAIN}' \
    -e SYNAPSE_REPORT_STATS=no \
    '${SYNAPSE_IMAGE}' generate \
  && chown -R 991:991 /opt/matrix/synapse
"

# Verify generation
pct exec "$CT_ID" -- test -f /opt/matrix/synapse/homeserver.yaml \
  || { echo "  ERROR: homeserver.yaml not generated." >&2; exit 1; }

# ── Patch homeserver.yaml ─────────────────────────────────────────────────────
echo "  Patching homeserver.yaml..."

# Remove SQLite database block — fail loudly if the expected pattern isn't present
pct exec "$CT_ID" -- python3 - /opt/matrix/synapse/homeserver.yaml <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()
new, n = re.subn(
    r'\ndatabase:\s*\n\s+name:\s*sqlite3\s*\n\s+args:\s*\n\s+database:\s*/data/homeserver\.db\s*\n',
    '\n',
    content
)
if n == 0:
    sys.exit("ERROR: SQLite database block not found in homeserver.yaml — upstream format may have changed.")
with open(path, 'w') as f:
    f.write(new)
PYEOF

# Build TURN guest flag as yaml literal
TURN_ALLOW_GUESTS_YAML="false"
[[ "$TURN_ALLOW_GUESTS" -eq 1 ]] && TURN_ALLOW_GUESTS_YAML="true"

# Append production configuration
pct exec "$CT_ID" -- bash -lc "cat >> /opt/matrix/synapse/homeserver.yaml <<EOF

# ── Production configuration (appended by setup) ──────────────────────────────

database:
  name: psycopg2
  txn_limit: 10000
  args:
    user: synapse
    password: \"${DB_PASSWORD}\"
    database: synapse
    host: postgres_db
    port: 5432
    cp_min: 5
    cp_max: 10

redis:
  enabled: true
  host: redis
  port: 6379
  password: \"${REDIS_PASSWORD}\"

public_baseurl: \"https://matrix.${MATRIX_DOMAIN}/\"

suppress_key_server_warning: true
max_upload_size: 200M
enable_registration: true
registration_requires_token: true

presence:
  enabled: true

media_retention:
  remote_media_lifetime: 90d

forgotten_room_retention_period: 7d

turn_uris:
  - \"turns:${TURN_HOST}:443?transport=tcp\"
  - \"turn:${TURN_HOST}:80?transport=udp\"
  - \"turn:${TURN_HOST}:443?transport=tcp\"
turn_shared_secret: \"${TURN_SHARED_SECRET}\"
turn_user_lifetime: ${TURN_USER_LIFETIME_MS}
turn_allow_guests: ${TURN_ALLOW_GUESTS_YAML}

url_preview_enabled: true
url_preview_ip_range_blacklist:
  - '127.0.0.0/8'
  - '10.0.0.0/8'
  - '172.16.0.0/12'
  - '192.168.0.0/16'
  - '100.64.0.0/10'
  - '192.0.0.0/24'
  - '169.254.0.0/16'
  - '198.51.100.0/24'
  - '203.0.113.0/24'
  - '224.0.0.0/4'
  - '::1/128'
  - 'fe80::/10'
  - 'fc00::/7'
  - '2001:db8::/32'
  - 'ff00::/8'
  - 'fec0::/10'
EOF"

# Validate patch
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cfg=/opt/matrix/synapse/homeserver.yaml
  grep -q "^  name: psycopg2"   "$cfg" || { echo "  ERROR: psycopg2 not found in homeserver.yaml" >&2; exit 1; }
  grep -q "^public_baseurl:"    "$cfg" || { echo "  ERROR: public_baseurl not found in homeserver.yaml" >&2; exit 1; }
  ! grep -q "name: sqlite3"     "$cfg" || { echo "  ERROR: sqlite3 still present in homeserver.yaml" >&2; exit 1; }
  grep -q "^turn_shared_secret:" "$cfg" || { echo "  ERROR: turn_shared_secret not found in homeserver.yaml" >&2; exit 1; }
  echo "  homeserver.yaml validated"
'

# ── Maintenance script ────────────────────────────────────────────────────────
# Scope: update | auto-update | version
# Backup/restore/list are intentionally absent — PBS covers CT-level backup and
# pre-update safety is the operator's PVE snapshot (reminder prompt below).
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/matrix-maint.sh && chmod 0755 /usr/local/bin/matrix-maint.sh' <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR="${APP_DIR:-/opt/matrix}"
SERVICE="matrix-stack.service"
ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"

need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }
log() { echo "  $*"; logger -t matrix-maint -- "$*" 2>/dev/null || true; }

usage() {
  cat <<EOF2
  Matrix Maintenance
  ──────────────────
  Usage:
    $0 update [synapse-tag] [element-tag]
    $0 auto-update
    $0 version

  Notes:
    - update accepts a concrete semver tag (e.g. v1.148.0) or 'latest'.
    - auto-update (when AUTO_UPDATE=1) pulls :latest for Synapse + Element and
      recreates the containers. It is only intended for non-production setups.
    - CT-level backup is handled by PBS; pre-update safety uses PVE snapshots.
      Interactive update runs will remind you to take a snapshot first.
EOF2
}

[[ -d "$APP_DIR" ]]                              || die "APP_DIR not found: $APP_DIR"
[[ -f "$ENV_FILE" ]]                             || die "Missing env file: $ENV_FILE"
[[ -f "$COMPOSE_FILE" ]]                         || die "Missing compose file: $COMPOSE_FILE"
[[ -f "$APP_DIR/element-config.json" ]]          || die "Missing Element config: $APP_DIR/element-config.json"
[[ -f "$APP_DIR/element-nginx.conf" ]]           || die "Missing Element nginx config: $APP_DIR/element-nginx.conf"
[[ -f "$APP_DIR/synapse/homeserver.yaml" ]]      || die "Missing Synapse config: $APP_DIR/synapse/homeserver.yaml"

env_value() {
  awk -F= -v key="$1" '$1==key{print $2}' "$ENV_FILE" | tail -n1
}

env_flag() {
  local raw
  raw="$(env_value "$1" | tr -d '[:space:]')"
  [[ "$raw" =~ ^[01]$ ]] && printf '%s' "$raw" || printf '0'
}

valid_tag() {
  # Accepts concrete semver or 'latest'. Install-time pinning is enforced
  # separately in the creator script; the maint script honours the new model
  # where AUTO_UPDATE=1 switches to :latest.
  [[ "$1" == "latest" || "$1" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]]
}

set_env() {
  python3 - "$ENV_FILE" "$1" "$2" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
lines = path.read_text().splitlines()
for i, line in enumerate(lines):
    if line.startswith(key + '='):
        lines[i] = f'{key}={value}'
        break
else:
    lines.append(f'{key}={value}')
path.write_text('\n'.join(lines) + '\n')
PY
}

update_cmd() {
  local synapse_repo element_repo current_synapse_tag current_element_tag \
        target_synapse_tag target_element_tag tmp_env synapse_port element_port health

  synapse_repo="$(env_value SYNAPSE_IMAGE_REPO)"
  element_repo="$(env_value ELEMENT_IMAGE_REPO)"
  current_synapse_tag="$(env_value SYNAPSE_TAG)"
  current_element_tag="$(env_value ELEMENT_TAG)"
  synapse_port="$(env_value SYNAPSE_PORT)"
  element_port="$(env_value ELEMENT_PORT)"

  [[ -n "$synapse_repo" && -n "$element_repo" ]]             || die "Could not read image repositories from .env"
  [[ -n "$current_synapse_tag" && -n "$current_element_tag" ]] || die "Could not read current tags from .env"
  [[ -n "$synapse_port" && -n "$element_port" ]]             || die "Could not read ports from .env"

  # No args: re-pull the current tags (idempotent for pinned tags, picks up new
  # digest for :latest). Operator can pass explicit tags to move to a new version.
  target_synapse_tag="${1:-$current_synapse_tag}"
  target_element_tag="${2:-$current_element_tag}"

  valid_tag "$target_synapse_tag" || die "Invalid Synapse tag: $target_synapse_tag (must be semver like v1.148.0, or 'latest')"
  valid_tag "$target_element_tag" || die "Invalid Element tag: $target_element_tag (must be semver like v1.12.11, or 'latest')"

  log "Current Synapse tag: $current_synapse_tag"
  log "Current Element tag: $current_element_tag"
  log "Target  Synapse tag: $target_synapse_tag"
  log "Target  Element tag: $target_element_tag"

  # Interactive snapshot reminder — timer-driven runs skip this.
  if [[ -t 0 ]]; then
    echo ""
    echo "  Reminder: take a PVE snapshot before continuing, e.g.:"
    echo "    pct snapshot <ctid> pre-matrix-$(date +%Y%m%d-%H%M)"
    echo ""
    read -r -p "  Continue with update? [y/N]: " r
    [[ "$r" =~ ^[yY]([eE][sS])?$ ]] || die "Aborted by operator."
  fi

  tmp_env="$(mktemp)"
  cp -a "$ENV_FILE" "$tmp_env"

  rollback() {
    echo "  !! Update failed — rolling back .env and app containers ..." >&2
    cp -a "$tmp_env" "$ENV_FILE"
    cd "$APP_DIR"
    /usr/bin/podman-compose up -d --force-recreate synapse element || true
  }
  trap rollback ERR

  set_env SYNAPSE_TAG   "$target_synapse_tag"
  set_env SYNAPSE_IMAGE "${synapse_repo}:$target_synapse_tag"
  set_env ELEMENT_TAG   "$target_element_tag"
  set_env ELEMENT_IMAGE "${element_repo}:$target_element_tag"

  log "Pulling target images ..."
  cd "$APP_DIR"
  /usr/bin/podman-compose pull synapse element

  log "Recreating Synapse and Element ..."
  /usr/bin/podman-compose up -d --force-recreate synapse element

  # Explicit rollback on health-check failure — the ERR trap does NOT fire through
  # `|| die` because the || branch catches the non-zero before ERR sees it.
  log "Waiting for Synapse health endpoint ..."
  health=0
  for _ in $(seq 1 45); do
    if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${synapse_port}/health"; then
      health=1
      break
    fi
    sleep 2
  done
  if [[ "$health" -ne 1 ]]; then
    trap - ERR
    rollback
    die "Synapse health endpoint did not return 200 after update."
  fi

  log "Waiting for Element ..."
  health=0
  for _ in $(seq 1 30); do
    if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${element_port}/"; then
      health=1
      break
    fi
    sleep 2
  done
  if [[ "$health" -ne 1 ]]; then
    trap - ERR
    rollback
    die "Element did not respond after update."
  fi

  trap - ERR
  rm -f "$tmp_env"
  log "OK: Matrix images updated (Synapse=${target_synapse_tag}, Element=${target_element_tag})."
}

auto_update_cmd() {
  if [[ "$(env_flag AUTO_UPDATE)" != "1" ]]; then
    log "Auto-update disabled in ${ENV_FILE}; nothing to do."
    return 0
  fi

  log "Auto-update: pulling :latest for Synapse and Element"
  update_cmd latest latest
}

version_cmd() {
  echo "SYNAPSE_IMAGE=$(env_value SYNAPSE_IMAGE)"
  echo "ELEMENT_IMAGE=$(env_value ELEMENT_IMAGE)"
  echo "POSTGRES_IMAGE=$(env_value POSTGRES_IMAGE)"
  echo "REDIS_IMAGE=$(env_value REDIS_IMAGE)"
  echo "AUTO_UPDATE=$(env_flag AUTO_UPDATE)"
}

need_root
cmd="${1:-}"
case "$cmd" in
  update)      shift; update_cmd "${1:-}" "${2:-}" ;;
  auto-update) auto_update_cmd ;;
  version)     version_cmd ;;
  ""|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
MAINT
echo "  Maintenance script deployed: /usr/local/bin/matrix-maint.sh"

# ── Auto-update timer ─────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/matrix-update.service <<EOF
[Unit]
Description=Matrix auto-update maintenance run
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/matrix-maint.sh auto-update
EOF

  cat > /etc/systemd/system/matrix-update.timer <<EOF
[Unit]
Description=Matrix auto-update timer

[Timer]
OnCalendar=*-*-01 05:30:00
OnCalendar=*-*-15 05:30:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
'
if [[ "$AUTO_UPDATE" -eq 1 ]]; then
  pct exec "$CT_ID" -- bash -lc 'systemctl enable --now matrix-update.timer'
  echo "  Auto-update timer enabled"
else
  pct exec "$CT_ID" -- bash -lc 'systemctl disable --now matrix-update.timer >/dev/null 2>&1 || true'
  echo "  Auto-update timer installed but disabled"
fi

# ── Pull container images ─────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc 'cd /opt/matrix && podman-compose pull'

# ── Auto-start on LXC boot (and start now) ────────────────────────────────────
# ExecStop uses `stop` (not `down`) so the named network and container identities
# survive a stop/start cycle — avoids transient inter-service DNS failures.
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/matrix-stack.service <<EOF
[Unit]
Description=Matrix Synapse (Podman) stack
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/matrix
ExecStart=/usr/bin/podman-compose up -d
ExecStop=/usr/bin/podman-compose stop
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now matrix-stack.service
'

# Wait until all containers are running (4: postgres, redis, synapse, element)
for i in $(seq 1 90); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc 'podman ps --format "{{.Names}}" 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge 4 ]] && break
  sleep 2
done
pct exec "$CT_ID" -- bash -lc 'cd /opt/matrix && podman-compose ps'

# Health check — verify Synapse is responding
SYNAPSE_HEALTHY=0
for i in $(seq 1 30); do
  if pct exec "$CT_ID" -- curl -sf -o /dev/null --max-time 3 "http://127.0.0.1:${SYNAPSE_PORT}/health"; then
    SYNAPSE_HEALTHY=1
    break
  fi
  sleep 2
done

if [[ "$SYNAPSE_HEALTHY" -eq 1 ]]; then
  echo "  Synapse is responding"
else
  echo "  WARNING: Synapse not responding yet — containers may still be initializing." >&2
  echo "  Check manually: pct enter $CT_ID -> curl -sf http://127.0.0.1:${SYNAPSE_PORT}/health" >&2
  pct exec "$CT_ID" -- bash -lc 'cd /opt/matrix && podman-compose logs --tail=80' >&2 || true
fi

# Health check — verify Element is responding
ELEMENT_HEALTHY=0
for i in $(seq 1 15); do
  if pct exec "$CT_ID" -- curl -sf -o /dev/null --max-time 3 "http://127.0.0.1:${ELEMENT_PORT}/"; then
    ELEMENT_HEALTHY=1
    break
  fi
  sleep 2
done

if [[ "$ELEMENT_HEALTHY" -eq 1 ]]; then
  echo "  Element is responding"
else
  echo "  WARNING: Element not responding yet — check: pct exec $CT_ID -- podman logs element-web" >&2
fi

# ── Unattended upgrades (do NOT overwrite Debian defaults) ────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y unattended-upgrades

  distro_codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

  cat > /etc/apt/apt.conf.d/52unattended-$(hostname).conf <<EOF
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security";
        "origin=Debian,codename=${distro_codename},label=Debian";
        "origin=Debian,codename=${distro_codename}-updates,label=Debian";
};
Unattended-Upgrade::Package-Blacklist {
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

  systemctl enable --now unattended-upgrades
'

# ── Sysctl hardening ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/sysctl.d/99-hardening.conf <<EOF
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOF
  sysctl --system >/dev/null 2>&1 || true
'

# ── Cleanup packages ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y man-db manpages 2>/dev/null || true
  apt-get -y autoremove
  apt-get -y clean
'

# ── MOTD (dynamic drop-ins, single pct exec) ──────────────────────────────────
# All drop-ins are single-quoted heredocs inside a `bash -s` outer heredoc so
# the inner $(...) expansions are preserved literally and evaluated at MOTD
# display time inside the CT, not at install time on the host.
pct exec "$CT_ID" -- bash -s <<'MOTDOUTER'
set -euo pipefail
> /etc/motd
chmod -x /etc/update-motd.d/* 2>/dev/null || true
rm -f /etc/update-motd.d/*

cat > /etc/update-motd.d/00-header <<'HDR'
#!/bin/sh
printf '\n  Matrix Synapse (Podman)\n'
printf '  ────────────────────────────────────\n'
HDR

cat > /etc/update-motd.d/10-sysinfo <<'SYS'
#!/bin/sh
ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
printf '  Hostname:  %s\n' "$(hostname)"
printf '  IP:        %s\n' "${ip:-n/a}"
printf '  Uptime:    %s\n' "$(uptime -p 2>/dev/null || uptime)"
printf '  Disk:      %s\n' "$(df -h / | awk 'NR==2{printf "%s/%s (%s used)", $3, $2, $5}')"
SYS

cat > /etc/update-motd.d/30-app <<'APP'
#!/bin/sh
running=$(podman ps --format '{{.Names}}' 2>/dev/null | wc -l)
service_active=$(systemctl is-active matrix-stack.service 2>/dev/null || echo 'unknown')
synapse_image=$(awk -F= '/^SYNAPSE_IMAGE=/{print $2}' /opt/matrix/.env 2>/dev/null | tail -n1)
element_image=$(awk -F= '/^ELEMENT_IMAGE=/{print $2}' /opt/matrix/.env 2>/dev/null | tail -n1)
synapse_port=$(awk -F= '/^SYNAPSE_PORT=/{print $2}' /opt/matrix/.env 2>/dev/null | tail -n1)
element_port=$(awk -F= '/^ELEMENT_PORT=/{print $2}' /opt/matrix/.env 2>/dev/null | tail -n1)
ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
printf '  Stack:     /opt/matrix (%s containers running)\n' "$running"
printf '  Service:   %s\n' "$service_active"
printf '  Synapse:   %s\n' "${synapse_image:-n/a}"
printf '  Element:   %s\n' "${element_image:-n/a}"
printf '  Compose:   cd /opt/matrix && podman-compose [up -d|stop|logs|ps]\n'
printf '  Maintain:  matrix-maint.sh [update|auto-update|version]\n'
printf '  Updates:   systemctl status matrix-update.timer\n'
printf '  Synapse:   http://%s:%s\n' "${ip:-n/a}" "${synapse_port:-8008}"
printf '  Element:   http://%s:%s\n' "${ip:-n/a}" "${element_port:-8080}"
cat <<EOF
  Admin ops:
    Create admin user (answer "y" to the admin prompt):
      podman exec -it synapse register_new_matrix_user \\
        -c /data/homeserver.yaml http://localhost:8008

    Get admin token:
      Element -> avatar -> All settings -> Help & About -> Advanced -> Access Token
      or via login API:
        curl -X POST http://${ip:-n/a}:${synapse_port:-8008}/_matrix/client/v3/login \\
          -H "Content-Type: application/json" \\
          -d '{"type":"m.login.password","identifier":{"type":"m.id.user","user":"USER"},"password":"PASS"}'

    Create registration token (requires admin token):
      curl -H "Authorization: Bearer <ADMIN_TOKEN>" \\
        -X POST http://${ip:-n/a}:${synapse_port:-8008}/_synapse/admin/v1/registration_tokens/new \\
        -d '{"uses_allowed": 1}'
EOF
APP

cat > /etc/update-motd.d/99-footer <<'FTR'
#!/bin/sh
printf '  ────────────────────────────────────\n\n'
FTR

chmod +x /etc/update-motd.d/*
MOTDOUTER

# ── Bashrc tweaks ─────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
  grep -q "/usr/local/bin" /root/.bashrc 2>/dev/null || echo "export PATH=\"/usr/local/bin:\$PATH\"" >> /root/.bashrc
'

# ── Proxmox UI description ───────────────────────────────────────────────────
LINK_STYLE="text-decoration: none; color: #00617f;"
MATRIX_DESC="Public: <a href='https://${ELEMENT_FQDN}/' target='_blank' rel='noopener noreferrer' style='${LINK_STYLE}'>Element Web</a> · <a href='https://${SYNAPSE_FQDN}/' target='_blank' rel='noopener noreferrer' style='${LINK_STYLE}'>Synapse</a>
Local: <a href='http://${CT_IP}:${ELEMENT_PORT}/' target='_blank' rel='noopener noreferrer' style='${LINK_STYLE}'>Element Web</a> · <a href='http://${CT_IP}:${SYNAPSE_PORT}/' target='_blank' rel='noopener noreferrer' style='${LINK_STYLE}'>Synapse</a>"
pct set "$CT_ID" --description "$MATRIX_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
cat <<EOF

  CT: $CT_ID | IP: ${CT_IP} | Login: password set
  Synapse: http://${CT_IP}:${SYNAPSE_PORT}
  Element: http://${CT_IP}:${ELEMENT_PORT}

  Maintenance:
    matrix-maint.sh [update|auto-update|version]
    Backup/restore: handled by PBS (CT-level) + PVE snapshots (pre-update)

  Runtime config:
    ${APP_DIR}/.env
    ${APP_DIR}/synapse/homeserver.yaml

  Create admin user (interactive):
    pct exec $CT_ID -- podman exec -it synapse \\
      register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008

  Create registration token (requires admin access token):
    curl -H "Authorization: Bearer <ADMIN_TOKEN>" \\
      -X POST http://${CT_IP}:${SYNAPSE_PORT}/_synapse/admin/v1/registration_tokens/new \\
      -d '{"uses_allowed": 1}'

  NPM proxy hosts:
    matrix.${MATRIX_DOMAIN} -> http://${CT_IP}:${SYNAPSE_PORT}
      SSL tab: enable SSL, Force SSL
      Custom Nginx Configuration (Proxy host > Settings):

client_max_body_size 200M;
proxy_read_timeout 600s;
proxy_send_timeout 600s;

location ^~ /_synapse/admin {
    return 403;
}

location /.well-known/matrix/server {
    default_type application/json;
    add_header Access-Control-Allow-Origin *;
    return 200 '{"m.server": "matrix.${MATRIX_DOMAIN}:443"}';
}
location /.well-known/matrix/client {
    default_type application/json;
    add_header Access-Control-Allow-Origin *;
    return 200 '{"m.homeserver": {"base_url": "https://matrix.${MATRIX_DOMAIN}"}, "m.identity_server": {"base_url": "https://vector.im"}, "org.matrix.msc3575.proxy": {"url": "https://matrix.${MATRIX_DOMAIN}"}}';
}

    chat.${MATRIX_DOMAIN} -> http://${CT_IP}:${ELEMENT_PORT}
      SSL tab: enable SSL, Force SSL

  TURN (VoIP relay):
    Host:            ${TURN_HOST}
    Shared secret:   (set in homeserver.yaml)
    Free tier note:  openrelay free tier is 500 MB/month relay traffic.
                     Replace TURN_HOST + TURN_SHARED_SECRET with your own
                     coturn for production voice/video.

  Federation test:
    https://federationtester.matrix.org/#matrix.${MATRIX_DOMAIN}

EOF

echo ""
