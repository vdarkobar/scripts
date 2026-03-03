#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID="$(pvesh get /cluster/nextid)"
HN="immich"
CPU=4
RAM=8192
DISK=32  # rootfs only — mount host storage for /photos in production
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"
PHOTO_STORAGE="rootfs"    # rootfs | <zfs-pool-name> (e.g. rpool) | /host/path

# Immich / Podman
APP_PORT=2283
APP_TZ="Europe/Berlin"
TAGS="immich;podman;lxc"

# Images (pin here if you want)
IMMICH_IMAGE="ghcr.io/imagegenius/immich:latest"
POSTGRES_IMAGE="ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0"
REDIS_IMAGE="docker.io/valkey/valkey:8"
DEBIAN_VERSION=13

# Behavior
CLEANUP_ON_FAIL=1  # 1 = destroy CT on error, 0 = keep for debugging

# ── Custom configs created by this script ─────────────────────────────────────
#   /opt/immich/docker-compose.yml
#   /opt/immich/.env
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/systemd/system/container-getty@1.service.d/override.conf
#   /etc/systemd/system/immich-stack.service
#   /etc/systemd/system/immich-update.service
#   /etc/systemd/system/immich-update.timer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
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

# ── Preflight — root & commands ───────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pvesh pveam pct pvesm; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

[[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }

# ── Discover available resources ──────────────────────────────────────────────
AVAIL_BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | sort | paste -sd',' | sed 's/,/, /g' || echo "n/a")"
AVAIL_TMPL_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'vztmpl' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_CT_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_ZFS_POOLS="$(zpool list -H -o name 2>/dev/null | sort | paste -sd',' | sed 's/,/, /g' || echo "n/a")"

# ── Show defaults & confirm ───────────────────────────────────────────────────
cat <<EOF

  Immich-Podman LXC Creator — Configuration
  ────────────────────────────────────────
  CT ID:              $CT_ID
  Hostname:           $HN
  CPU:                $CPU core(s)
  RAM:                $RAM MiB
  Disk:               $DISK GB
  Bridge:             $BRIDGE ($AVAIL_BRIDGES)
  Template Storage:   $TEMPLATE_STORAGE ($AVAIL_TMPL_STORES)
  Container Storage:  $CONTAINER_STORAGE ($AVAIL_CT_STORES)
  App Port:           $APP_PORT
  Debian Version:     $DEBIAN_VERSION
  Timezone:           $APP_TZ
  Tags:               $TAGS
  Immich Image:       $IMMICH_IMAGE
  Postgres Image:     $POSTGRES_IMAGE
  Redis/Valkey Image: $REDIS_IMAGE
  Cleanup on fail:    $CLEANUP_ON_FAIL
  Photo Storage:      $PHOTO_STORAGE  (available ZFS pools: $AVAIL_ZFS_POOLS)
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/immich-podman.sh"
SCRIPT_LOCAL="/root/immich-podman.sh"

read -r -p "  Continue with these settings? [y/N]: " response
case "$response" in
  [yY][eE][sS]|[yY]) ;;
  *)
    echo ""
    echo "  Downloading script to ${SCRIPT_LOCAL} for editing..."
    if curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_LOCAL"; then
      chmod +x "$SCRIPT_LOCAL"
      echo "  Edit:  nano ${SCRIPT_LOCAL}"
      echo "  Run:   bash ${SCRIPT_LOCAL}"
      echo ""
    else
      echo "  ERROR: Failed to download script." >&2
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

# ── Template discovery & download ─────────────────────────────────────────────
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

echo "lxc.apparmor.profile: unconfined" >> "/etc/pve/lxc/${CT_ID}.conf"

# ── Photos storage — ZFS dataset + LXC mount point ───────────────────────────
if [[ "$PHOTO_STORAGE" == "rootfs" ]]; then
  echo "  WARNING: No photos storage configured — uploads will use rootfs (${DISK} GB)." >&2
  pct mount "$CT_ID"
  mkdir -p "/var/lib/lxc/${CT_ID}/rootfs/opt/immich"
  chown 100000:100000 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich"
  mkdir -p \
    "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/postgresdata" \
    "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/redis" \
    "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/library" \
    "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/config"
  chown 100070:100070 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/postgresdata"
  chmod 700          "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/postgresdata"
  chown 100999:101000 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/redis"
  chown 101000:101000 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/library"
  chown 101000:101000 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/config"
  pct unmount "$CT_ID"
elif [[ "$PHOTO_STORAGE" == /* ]]; then
  # Plain host path
  mkdir -p "$PHOTO_STORAGE"
  chown 101000:101000 "$PHOTO_STORAGE"
  pct mount "$CT_ID"
  mkdir -p "/var/lib/lxc/${CT_ID}/rootfs/opt/immich"
  chown 100000:100000 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich"
  mkdir -p \
    "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/postgresdata" \
    "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/redis" \
    "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/library" \
    "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/config"
  chown 100070:100070 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/postgresdata"
  chmod 700          "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/postgresdata"
  chown 100999:101000 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/redis"
  chown 101000:101000 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/library"
  chown 101000:101000 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/config"
  pct unmount "$CT_ID"
  pct set "$CT_ID" --mp0 "${PHOTO_STORAGE},mp=/opt/immich/library"
  echo "  Photos mount: ${PHOTO_STORAGE} -> /opt/immich/library (CT ${CT_ID})"
else
  # ZFS pool name
  PHOTOS_DATASET="${PHOTO_STORAGE}/immich-photos"
  PHOTOS_HOST_PATH="$(zfs get -H -o value mountpoint "${PHOTOS_DATASET}" 2>/dev/null || true)"
  if [[ -z "$PHOTOS_HOST_PATH" || "$PHOTOS_HOST_PATH" == "-" ]]; then
    echo "  Creating ZFS dataset: ${PHOTOS_DATASET}"
    zfs create -o compression=lz4 "${PHOTOS_DATASET}"
    PHOTOS_HOST_PATH="$(zfs get -H -o value mountpoint "${PHOTOS_DATASET}")"
  else
    echo "  ZFS dataset already exists: ${PHOTOS_DATASET} -> ${PHOTOS_HOST_PATH}"
  fi
  chown 101000:101000 "$PHOTOS_HOST_PATH"
  pct mount "$CT_ID"
  mkdir -p "/var/lib/lxc/${CT_ID}/rootfs/opt/immich"
  chown 100000:100000 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich"
  mkdir -p \
    "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/postgresdata" \
    "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/redis" \
    "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/library" \
    "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/config"
  chown 100070:100070 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/postgresdata"
  chmod 700          "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/postgresdata"
  chown 100999:101000 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/redis"
  chown 101000:101000 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/library"
  chown 101000:101000 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/config"
  pct unmount "$CT_ID"
  pct set "$CT_ID" --mp0 "${PHOTOS_HOST_PATH},mp=/opt/immich/library"
  echo "  Photos mount: ${PHOTOS_HOST_PATH} -> /opt/immich/library (CT ${CT_ID})"
fi

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

# ── Auto-login (if no password) ───────────────────────────────────────────────
if [[ -z "$PASSWORD" ]]; then
  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
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
DB_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 35 || true)"
[[ ${#DB_PASSWORD} -eq 35 ]] || { echo "  ERROR: Failed to generate secrets." >&2; exit 1; }

# ── Prepare persistent volumes (absolute paths) ───────────────────────────────
# Dirs and UIDs pre-set on host during pct mount phase (offset +100000):
#   postgres=100070, valkey=100999:101000, immich=101000:101000
echo "  Verifying persistent volume ownership..."
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  ls -ld /opt/immich/postgresdata /opt/immich/redis /opt/immich/library /opt/immich/config
  echo "  Volumes OK"
'

# ── Compose file ──────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc 'cat > /opt/immich/docker-compose.yml <<YAML
networks:
  immich:
    driver: bridge

services:
  postgres:
    image: __POSTGRES_IMAGE__
    container_name: immich_postgres
    restart: unless-stopped
    networks:
      - immich
    environment:
      - POSTGRES_USER=immich
      - POSTGRES_PASSWORD=__DB_PASSWORD__
      - POSTGRES_DB=immich
      - POSTGRES_INITDB_ARGS=--data-checksums
      - TZ=__TZ__
    volumes:
      - /opt/immich/postgresdata:/var/lib/postgresql/data:Z
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U immich -d immich"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

  valkey:
    image: __REDIS_IMAGE__
    container_name: immich_valkey
    restart: unless-stopped
    networks:
      - immich
    environment:
      - TZ=__TZ__
    volumes:
      - /opt/immich/redis:/data:Z
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

  immich:
    image: __IMMICH_IMAGE__
    container_name: immich
    restart: unless-stopped
    networks:
      - immich
    ports:
      - "__APP_PORT__:8080"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=__TZ__
      - DB_HOSTNAME=postgres
      - DB_USERNAME=immich
      - DB_PASSWORD=__DB_PASSWORD__
      - DB_DATABASE_NAME=immich
      - REDIS_HOSTNAME=valkey
    volumes:
      - /opt/immich/library:/photos:Z
      - /opt/immich/config:/config:Z
    depends_on:
      postgres:
        condition: service_healthy
      valkey:
        condition: service_healthy
YAML
'

pct exec "$CT_ID" -- sed -i \
  -e "s|__IMMICH_IMAGE__|${IMMICH_IMAGE}|g" \
  -e "s|__POSTGRES_IMAGE__|${POSTGRES_IMAGE}|g" \
  -e "s|__REDIS_IMAGE__|${REDIS_IMAGE}|g" \
  -e "s|__APP_PORT__|${APP_PORT}|g" \
  -e "s|__TZ__|${APP_TZ}|g" \
  -e "s|__DB_PASSWORD__|${DB_PASSWORD}|g" \
  /opt/immich/docker-compose.yml
pct exec "$CT_ID" -- chmod 600 /opt/immich/docker-compose.yml

# ── .env (reference only — values are baked into compose via sed) ─────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > /opt/immich/.env <<EOF
# Reference only — these values are baked into docker-compose.yml at creation time.
# To change ports/TZ, edit docker-compose.yml directly and run: podman-compose up -d
COMPOSE_PROJECT_NAME=immich
APP_TZ=${APP_TZ}
APP_PORT=${APP_PORT}
EOF
  chmod 600 /opt/immich/.env
"

# ── Auto-update timer ─────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/immich-update.service <<EOF
[Unit]
Description=Pull and update Immich Podman containers
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=/opt/immich
ExecStart=/bin/bash -c "/usr/bin/podman-compose pull && /usr/bin/podman-compose up -d"
EOF

  cat > /etc/systemd/system/immich-update.timer <<EOF
[Unit]
Description=Auto-update Immich containers biweekly

[Timer]
OnCalendar=*-*-01 05:30:00
OnCalendar=*-*-15 05:30:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now immich-update.timer
'

# ── Pull container images ─────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc 'cd /opt/immich && podman-compose pull'

# ── Auto-start on LXC boot (and start now) ────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/immich-stack.service <<EOF
[Unit]
Description=Immich (Podman) stack
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/immich
ExecStart=/usr/bin/podman-compose up -d
ExecStop=/usr/bin/podman-compose down
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now immich-stack.service
'

# Wait until all three containers are running (postgres, valkey, immich)
EXPECTED=3
for i in $(seq 1 90); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc 'podman ps --format "{{.Names}}" 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge $EXPECTED ]] && break
  sleep 2
done
pct exec "$CT_ID" -- bash -lc 'cd /opt/immich && podman-compose ps'

# Health check — verify Immich web UI is responding
IMMICH_HEALTHY=0
for i in $(seq 1 30); do
  if pct exec "$CT_ID" -- curl -sf -o /dev/null --max-time 3 "http://127.0.0.1:${APP_PORT}/api/server/ping"; then
    IMMICH_HEALTHY=1
    break
  fi
  sleep 2
done

if [[ "$IMMICH_HEALTHY" -eq 1 ]]; then
  echo "  Immich is responding"
else
  echo "  WARNING: Immich not responding yet — containers are running but app may still be initializing." >&2
  echo "  Check manually: pct enter $CT_ID -> curl -sf http://127.0.0.1:${APP_PORT}/api/server/ping" >&2
  pct exec "$CT_ID" -- bash -lc 'cd /opt/immich && podman-compose logs --tail=80' >&2 || true
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
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
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

# ── MOTD (dynamic drop-ins) ───────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  > /etc/motd
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
  rm -f /etc/update-motd.d/*

  cat > /etc/update-motd.d/00-header <<'MOTD'
#!/bin/sh
printf '\n  Immich (Podman)\n'
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
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '  Stack:     /opt/immich (%s containers running)\n' \"\$running\"
printf '  Web UI:    http://%s:${APP_PORT}\n' \"\${ip:-n/a}\"
printf '  Compose:   cd /opt/immich && podman-compose [up -d|down|logs|ps]\n'
printf '  Updates:   systemctl status immich-update.timer\n'
printf '  Backup:    /opt/immich + podman exec immich_postgres pg_dumpall -U immich\n'
printf '\n'
printf '  Post-setup:\n'
printf '    1. Open Web UI -- first registered user becomes admin\n'
printf '       Note: ML models load on first use -- cold start takes 3-5 min\n'
printf '    2. Admin -> Settings -> Server -> Public URL\n'
printf '       set to: https://<your-domain>\n'
printf '    3. NPM proxy host -> Advanced -> Custom Nginx Configuration:\n'
printf '         client_max_body_size 0;\n'
printf '         proxy_read_timeout 600s;\n'
printf '         proxy_send_timeout 600s;\n'
printf '         proxy_buffering off;\n'
printf '    4. NPM proxy host -> enable Websockets Support\n'
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

# ── Proxmox UI description ────────────────────────────────────────────────────
IMMICH_DESC="<a href='http://${CT_IP}:${APP_PORT}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Immich Web UI</a>
<details><summary>Details</summary>Immich (Podman, imagegenius monolith) on Debian 13 LXC
Created by immich-podman.sh</details>"
pct set "$CT_ID" --description "$IMMICH_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "CT: $CT_ID | IP: ${CT_IP} | Web UI: http://${CT_IP}:${APP_PORT} | Login: $([ -n "$PASSWORD" ] && echo 'password set' || echo 'auto-login')"
echo ""
if [[ "$PHOTO_STORAGE" == "rootfs" ]]; then
  echo "  Photos:   rootfs (${DISK} GB) — consider external storage for production"
elif [[ "$PHOTO_STORAGE" == /* ]]; then
  echo "  Photos:   ${PHOTO_STORAGE} (host path) -> /opt/immich/library"
else
  echo "  Photos:   ${PHOTOS_HOST_PATH} (${PHOTO_STORAGE}/immich-photos) -> /opt/immich/library"
fi
echo ""
echo "  Post-setup:"
echo "    1. Open http://${CT_IP}:${APP_PORT} — first registered user becomes admin"
echo "       Note: ML models load on first use — cold start takes 3-5 min"
echo "    2. Admin → Settings → Server → Public URL → https://<your-domain>"
echo "    3. NPM proxy host → enable Websockets Support"
echo "    4. NPM proxy host → Advanced → Custom Nginx Configuration:"
echo "         client_max_body_size 0;"
echo "         proxy_read_timeout 600s;"
echo "         proxy_send_timeout 600s;"
echo "         proxy_buffering off;"
echo ""

# ── Reboot ────────────────────────────────────────────────────────────────────
echo "  Rebooting container..."
pct reboot "$CT_ID"

# Wait for stack to come back (3 containers: postgres, valkey, immich)
RUNNING=0
for i in $(seq 1 90); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc 'podman ps --format "{{.Names}}" 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge 3 ]] && break
  sleep 2
done
[[ "$RUNNING" -ge 3 ]] && echo "  Stack came up after reboot" \
  || echo "  WARNING: Stack not fully up after reboot — check immich-stack.service" >&2

echo "  Done."
echo ""
