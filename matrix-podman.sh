#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID="$(pvesh get /cluster/nextid)"
HN="matrix"
CPU=4
RAM=4096
DISK=16
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Matrix / Podman
MATRIX_DOMAIN="example.com"
MATRIX_TZ="Europe/Berlin"
SYNAPSE_PORT=8008
ELEMENT_PORT=8080
TAGS="matrix;podman;lxc"

# Images (pin here if you want)
SYNAPSE_IMAGE="ghcr.io/element-hq/synapse:latest"
POSTGRES_IMAGE="docker.io/library/postgres:18-alpine"
ELEMENT_IMAGE="docker.io/vectorim/element-web:latest"
REDIS_IMAGE="docker.io/library/redis:8-alpine"
DEBIAN_VERSION=13

# Behavior
CLEANUP_ON_FAIL=1  # 1 = destroy CT on error, 0 = keep for debugging

# ── Custom configs created by this script ─────────────────────────────────────
#   /opt/matrix/docker-compose.yml
#   /opt/matrix/.env
#   /opt/matrix/element-config.json
#   /opt/matrix/element-nginx.conf
#   /opt/matrix/synapse/homeserver.yaml        (generated + patched)
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/systemd/system/container-getty@1.service.d/override.conf
#   /etc/systemd/system/matrix-stack.service
#   /etc/systemd/system/matrix-update.service
#   /etc/systemd/system/matrix-update.timer
#   /etc/apt/apt.conf.d/52unattended-matrix.conf
#   /etc/sysctl.d/99-hardening.conf

# ── Trap cleanup ──────────────────────────────────────────────────────────────
trap 'trap - ERR; rc=$?;
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

# ── Preflight (root) ─────────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pvesh pveam pct pvesm; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

[[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }

# ── Show defaults & confirm ──────────────────────────────────────────────────
cat <<EOF

  Matrix-Podman LXC Creator — Configuration
  ────────────────────────────────────────
  CT ID:             $CT_ID
  Hostname:          $HN
  CPU:               $CPU core(s)
  RAM:               $RAM MiB
  Disk:              $DISK GB
  Bridge:            $BRIDGE
  Template Storage:  $TEMPLATE_STORAGE
  Container Storage: $CONTAINER_STORAGE
  Domain:            $MATRIX_DOMAIN
  Synapse URL:       matrix.${MATRIX_DOMAIN}
  Element URL:       chat.${MATRIX_DOMAIN}
  Synapse Port:      $SYNAPSE_PORT
  Element Port:      $ELEMENT_PORT
  Debian Version:    $DEBIAN_VERSION
  Timezone:          $MATRIX_TZ
  Tags:              $TAGS
  Synapse Image:     $SYNAPSE_IMAGE
  Postgres Image:    $POSTGRES_IMAGE
  Element Image:     $ELEMENT_IMAGE
  Redis Image:       $REDIS_IMAGE
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF
read -r -p "  Continue with these settings? [y/N]: " response
case "$response" in
  [yY][eE][sS]|[yY]) ;;
  *) echo "  Cancelled."; exit 0 ;;
esac
echo ""

# ── Preflight (environment) ──────────────────────────────────────────────────
pvesm status | awk -v s="$TEMPLATE_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Template storage not found: $TEMPLATE_STORAGE" >&2; exit 1; }

pvesm status | awk -v s="$CONTAINER_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Container storage not found: $CONTAINER_STORAGE" >&2; exit 1; }

ip link show "$BRIDGE" >/dev/null 2>&1 || { echo "  ERROR: Bridge not found: $BRIDGE" >&2; exit 1; }

# ── Root password ─────────────────────────────────────────────────────────────
PASSWORD=""
while true; do
  read -r -s -p "  Set root password (blank = auto-login): " PW1; echo
  [[ -z "$PW1" ]] && break
  if [[ "$PW1" == *" "* ]]; then echo "  Password cannot contain spaces."; continue; fi
  if [[ ${#PW1} -lt 5 ]]; then echo "  Password must be at least 5 characters."; continue; fi
  read -r -s -p "  Verify root password: " PW2; echo
  if [[ "$PW1" == "$PW2" ]]; then PASSWORD="$PW1"; break; fi
  echo "  Passwords do not match. Try again."
done
echo ""

if [[ -z "$PASSWORD" ]]; then
  echo "  WARNING: Blank password enables root auto-login on the Proxmox console."
  echo ""
fi

# ── Template ─────────────────────────────────────────────────────────────────
pveam update
echo ""
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }

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
)
[[ -n "$PASSWORD" ]] && PCT_OPTIONS+=(-password "$PASSWORD")

pct create "$CT_ID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" "${PCT_OPTIONS[@]}"
CREATED=1

# ── Start & wait for IPv4 ────────────────────────────────────────────────────
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

# ── Auto-login if no password ────────────────────────────────────────────────
if [[ -z "$PASSWORD" ]]; then
  pct exec "$CT_ID" -- bash -lc '
    mkdir -p /etc/systemd/system/container-getty@1.service.d
    cat > /etc/systemd/system/container-getty@1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 \$TERM
EOF
    systemctl daemon-reload
    systemctl restart container-getty@1.service
  '
fi

# ── OS update ─────────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  export DEBIAN_FRONTEND=noninteractive
  export LANG=C.UTF-8
  export LC_ALL=C.UTF-8
  systemctl disable -q --now systemd-networkd-wait-online.service 2>/dev/null || true
  apt-get update -qq
  apt-get -o Dpkg::Options::="--force-confold" -y dist-upgrade
  apt-get -y autoremove
  apt-get -y clean
'

# ── Configure locale ─────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y locales
  sed -i "s/^# *en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
'

# ── Remove unnecessary services ──────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  export DEBIAN_FRONTEND=noninteractive
  systemctl disable --now ssh 2>/dev/null || true
  systemctl disable --now postfix 2>/dev/null || true
  apt-get purge -y openssh-server postfix 2>/dev/null || true
  apt-get -y autoremove
'

# ── Set timezone ─────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  ln -sf /usr/share/zoneinfo/${MATRIX_TZ} /etc/localtime
  echo '${MATRIX_TZ}' > /etc/timezone
"

# ── Install Podman ────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y podman podman-compose fuse-overlayfs curl ca-certificates iproute2 python3
'

# ── Configure storage driver ─────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
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

# ── Configure extended registries ────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
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

# ── Podman log rotation ──────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
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

# ── Secrets ──────────────────────────────────────────────────────────────────
set +o pipefail
DB_PASSWORD="$(head -c 4096 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 63)"
REDIS_PASSWORD="$(head -c 4096 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32)"
set -o pipefail
[[ ${#DB_PASSWORD} -eq 63 && ${#REDIS_PASSWORD} -eq 32 ]] || { echo "  ERROR: Failed to generate secrets." >&2; exit 1; }

pct exec "$CT_ID" -- bash -lc "
  mkdir -p /opt/matrix/synapse
"

# ── Element nginx config (port >1024 — required for unprivileged Podman) ────
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

# ── Compose file ─────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc 'cat > /opt/matrix/docker-compose.yml <<YAML
networks:
  matrix:
    driver: bridge

services:

  postgres_db:
    image: __POSTGRES_IMAGE__
    container_name: postgres_db
    restart: unless-stopped
    networks:
      - matrix
    environment:
      - POSTGRES_DB=synapse
      - POSTGRES_USER=synapse
      - POSTGRES_PASSWORD=__DB_PASSWORD__
      - POSTGRES_INITDB_ARGS=--encoding=UTF8 --lc-collate=C --lc-ctype=C
      - TZ=__TZ__
    volumes:
      - ./postgresdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U synapse -d synapse"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

  redis:
    image: __REDIS_IMAGE__
    container_name: redis
    restart: unless-stopped
    command: >
      redis-server
      --appendonly yes
      --maxmemory 256mb
      --maxmemory-policy allkeys-lru
      --requirepass __REDIS_PASSWORD__
    networks:
      - matrix
    volumes:
      - ./redis:/data
    environment:
      - TZ=__TZ__
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "__REDIS_PASSWORD__", "ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    depends_on:
      postgres_db:
        condition: service_healthy

  synapse:
    image: __SYNAPSE_IMAGE__
    container_name: synapse
    restart: unless-stopped
    networks:
      - matrix
    ports:
      - "__SYNAPSE_PORT__:8008"
    environment:
      - SYNAPSE_CONFIG_PATH=/data/homeserver.yaml
      - TZ=__TZ__
    volumes:
      - ./synapse:/data
    healthcheck:
      test: ["CMD", "curl", "-fSs", "http://localhost:8008/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    depends_on:
      postgres_db:
        condition: service_healthy
      redis:
        condition: service_healthy

  element:
    image: __ELEMENT_IMAGE__
    container_name: element-web
    restart: unless-stopped
    networks:
      - matrix
    ports:
      - "__ELEMENT_PORT__:8080"
    volumes:
      - ./element-config.json:/app/config.json:ro
      - ./element-nginx.conf:/etc/nginx/templates/default.conf.template:ro
    depends_on:
      synapse:
        condition: service_healthy
YAML
'

pct exec "$CT_ID" -- sed -i \
  -e "s|__SYNAPSE_IMAGE__|${SYNAPSE_IMAGE}|g" \
  -e "s|__POSTGRES_IMAGE__|${POSTGRES_IMAGE}|g" \
  -e "s|__ELEMENT_IMAGE__|${ELEMENT_IMAGE}|g" \
  -e "s|__REDIS_IMAGE__|${REDIS_IMAGE}|g" \
  -e "s|__SYNAPSE_PORT__|${SYNAPSE_PORT}|g" \
  -e "s|__ELEMENT_PORT__|${ELEMENT_PORT}|g" \
  -e "s|__TZ__|${MATRIX_TZ}|g" \
  -e "s|__DB_PASSWORD__|${DB_PASSWORD}|g" \
  -e "s|__REDIS_PASSWORD__|${REDIS_PASSWORD}|g" \
  /opt/matrix/docker-compose.yml

# ── Element config ───────────────────────────────────────────────────────────
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
    \"map_style_url\": \"https://api.maptiler.com/maps/streets/style.json?key=fU3vlMsMn4Jb6dnEIFsx\"
}
EOF"

# ── .env (reference only) ────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  cat > /opt/matrix/.env <<EOF
# Reference only — values are baked into docker-compose.yml at creation time.
# To change, edit docker-compose.yml directly and run: podman-compose up -d
COMPOSE_PROJECT_NAME=matrix
MATRIX_TZ=${MATRIX_TZ}
MATRIX_DOMAIN=${MATRIX_DOMAIN}
SYNAPSE_PORT=${SYNAPSE_PORT}
ELEMENT_PORT=${ELEMENT_PORT}
EOF
  chmod 600 /opt/matrix/.env
"

# ── Generate Synapse homeserver.yaml ─────────────────────────────────────────
echo "  Generating Synapse configuration..."

pct exec "$CT_ID" -- bash -lc "
  podman run --rm \
    -v /opt/matrix/synapse:/data:Z \
    -e SYNAPSE_SERVER_NAME='matrix.${MATRIX_DOMAIN}' \
    -e SYNAPSE_REPORT_STATS=no \
    '${SYNAPSE_IMAGE}' generate
"

# Verify generation
pct exec "$CT_ID" -- test -f /opt/matrix/synapse/homeserver.yaml \
  || { echo "  ERROR: homeserver.yaml not generated." >&2; exit 1; }

# ── Patch homeserver.yaml ────────────────────────────────────────────────────
echo "  Patching homeserver.yaml..."

# Remove SQLite database block
pct exec "$CT_ID" -- python3 - /opt/matrix/synapse/homeserver.yaml <<'PYEOF'
import sys, re
with open(sys.argv[1], 'r') as f:
    content = f.read()
content = re.sub(
    r'\ndatabase:\s*\n\s+name:\s*sqlite3\s*\n\s+args:\s*\n\s+database:\s*/data/homeserver\.db\s*\n',
    '\n',
    content
)
with open(sys.argv[1], 'w') as f:
    f.write(content)
PYEOF

# Append production configuration
pct exec "$CT_ID" -- bash -lc "cat >> /opt/matrix/synapse/homeserver.yaml <<EOF

# ── Production configuration (appended by setup) ────────────────────────────

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

public_baseurl: "https://matrix.${MATRIX_DOMAIN}/"

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
  - "turns:staticauth.openrelay.metered.ca:443?transport=tcp"
  - "turn:staticauth.openrelay.metered.ca:80?transport=udp"
  - "turn:staticauth.openrelay.metered.ca:443?transport=tcp"
turn_shared_secret: "openrelayprojectsecret"
turn_user_lifetime: 86400000
turn_allow_guests: false

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
  cfg=/opt/matrix/synapse/homeserver.yaml
  grep -q "psycopg2" "$cfg"    || { echo "  ERROR: psycopg2 not found in homeserver.yaml" >&2; exit 1; }
  grep -q "public_baseurl" "$cfg" || { echo "  ERROR: public_baseurl not found in homeserver.yaml" >&2; exit 1; }
  ! grep -q "sqlite3" "$cfg"   || { echo "  ERROR: sqlite3 still present in homeserver.yaml" >&2; exit 1; }
  echo "  homeserver.yaml validated"
'

# ── Auto-update timer ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  cat > /etc/systemd/system/matrix-update.service <<EOF
[Unit]
Description=Pull and update Matrix Podman containers
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=/opt/matrix
ExecStart=/bin/bash -c "/usr/bin/podman-compose pull && /usr/bin/podman-compose up -d"
EOF

  cat > /etc/systemd/system/matrix-update.timer <<EOF
[Unit]
Description=Auto-update Matrix containers biweekly

[Timer]
OnCalendar=*-*-01 05:30:00
OnCalendar=*-*-15 05:30:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now matrix-update.timer
'

# ── Pull container images ────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc 'cd /opt/matrix && podman-compose pull'

# ── Auto-start on LXC boot (and start now) ───────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
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
ExecStop=/usr/bin/podman-compose down
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

# ── Unattended upgrades (do NOT overwrite Debian defaults) ───────────────────
pct exec "$CT_ID" -- bash -lc '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y unattended-upgrades

  distro_codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

  cat > /etc/apt/apt.conf.d/52unattended-matrix.conf <<EOF
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

# ── Sysctl hardening ─────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
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
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  sysctl --system >/dev/null 2>&1 || true
'

# ── Cleanup unnecessary packages ─────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y man-db manpages 2>/dev/null || true
  apt-get -y autoremove
  apt-get -y clean
'

# ── MOTD (dynamic drop-ins) ──────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  > /etc/motd
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
  rm -f /etc/update-motd.d/*

  cat > /etc/update-motd.d/00-header <<'MOTD'
#!/bin/sh
printf '\n  Matrix Synapse (Podman)\n'
printf '  ────────────────────────────────────\n'
MOTD

  cat > /etc/update-motd.d/10-sysinfo <<'MOTD'
#!/bin/sh
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '  Hostname:  %s\n' \"\$(hostname)\"
printf '  IP:        %s\n' \"\${ip:-n/a}\"
printf '  Uptime:    %s\n' \"\$(uptime -p 2>/dev/null || uptime)\"
printf '  Disk:      %s\n' \"\$(df -h / | awk 'NR==2{printf \"%s/%s (%s used)\", \$3, \$2, \$5}')\"
MOTD

  cat > /etc/update-motd.d/30-app <<'MOTD'
#!/bin/sh
running=\$(podman ps --format '{{.Names}}' 2>/dev/null | wc -l)
printf '  Stack:     /opt/matrix (%s containers running)\n' \"\$running\"
printf '  Domain:    matrix.${MATRIX_DOMAIN}\n'
printf '  Compose:   cd /opt/matrix && podman-compose [up -d|down|logs|ps]\n'
printf '  Updates:   systemctl status matrix-update.timer\n'
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '  Synapse:   http://%s:${SYNAPSE_PORT}\n' \"\${ip:-n/a}\"
printf '  Element:   http://%s:${ELEMENT_PORT}\n' \"\${ip:-n/a}\"
MOTD

  cat > /etc/update-motd.d/99-footer <<'MOTD'
#!/bin/sh
printf '  ────────────────────────────────────\n\n'
MOTD

  chmod +x /etc/update-motd.d/*
"

pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Proxmox UI description ───────────────────────────────────────────────────
MATRIX_DESC="<a href='http://${CT_IP}:${ELEMENT_PORT}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Element Web</a> · <a href='http://${CT_IP}:${SYNAPSE_PORT}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Synapse</a>
<details><summary>Details</summary>Matrix Synapse (Podman) on Debian 13 LXC
Domain: matrix.${MATRIX_DOMAIN}
Created by matrix-lxc-podman.sh</details>"
pct set "$CT_ID" --description "$MATRIX_DESC"

# ── Protect container ────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ──────────────────────────────────────────────────────────────────
cat <<EOF

  CT: $CT_ID | IP: ${CT_IP} | Login: $([ -n "$PASSWORD" ] && echo 'password set' || echo 'auto-login')
  Synapse: http://${CT_IP}:${SYNAPSE_PORT}
  Element: http://${CT_IP}:${ELEMENT_PORT}

  NPM proxy hosts:
    matrix.${MATRIX_DOMAIN} -> http://${CT_IP}:${SYNAPSE_PORT}
      SSL tab: enable SSL, Force SSL
      Custom Nginx Configuration (Proxy host > Settings):

client_max_body_size 200M;
proxy_read_timeout 600s;
proxy_send_timeout 600s;
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

  Create admin user:
    pct exec $CT_ID -- podman exec -it synapse register_new_matrix_user \\
      http://localhost:8008 -c /data/homeserver.yaml

  Federation test:
    https://federationtester.matrix.org/#matrix.${MATRIX_DOMAIN}

EOF

# ── Reboot CT so all settings take effect cleanly ────────────────────────────
echo "  Rebooting container..."
pct reboot "$CT_ID"

# Wait for stack to come back (4 containers: postgres, redis, synapse, element)
RUNNING=0
for i in $(seq 1 90); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc 'podman ps --format "{{.Names}}" 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge 4 ]] && break
  sleep 2
done
[[ "$RUNNING" -ge 4 ]] && echo "  Stack came up after reboot" \
  || echo "  WARNING: Stack not fully up after reboot — check matrix-stack.service" >&2

echo "  Done."
echo ""
