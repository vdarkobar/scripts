#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID="$(pvesh get /cluster/nextid)"
HN="immich"
CPU=4
RAM=8192
DISK=32
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"
PHOTO_STORAGE="rootfs"              # rootfs | <zfs-pool-name> | /host/path

# Immich / Podman
APP_PORT=2283
APP_TZ="Europe/Berlin"
PUBLIC_FQDN=""                      # e.g. photos.example.com ; blank = local IP mode
TAGS="immich;podman;lxc"

# Images / versions
IMMICH_IMAGE_REPO="ghcr.io/imagegenius/immich"
IMMICH_TAG="v2.5.6-ig446"            # pin concrete ImageGenius tag by default; use TRACK_LATEST=1 only if you intentionally want floating latest
IMMICH_IMAGE="${IMMICH_IMAGE_REPO}:${IMMICH_TAG}"
POSTGRES_IMAGE="ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0"
REDIS_IMAGE="docker.io/valkey/valkey:8"
DEBIAN_VERSION=13

# Optional features
AUTO_UPDATE=0                        # 1 = enable timer-driven maintenance/update runs
TRACK_LATEST=0                       # 1 = auto-update follows ${IMMICH_IMAGE_REPO}:latest
ENABLE_CONSOLE_AUTOLOGIN=0           # 1 = enable root console autologin when password blank
KEEP_BACKUPS=7

# Behavior
CLEANUP_ON_FAIL=1

# Derived
APP_DIR="/opt/immich"
BACKUP_DIR="/opt/immich-backups"
APP_URL=""
[[ -n "$PUBLIC_FQDN" ]] && APP_URL="https://${PUBLIC_FQDN}"

# ── Custom configs created by this script ─────────────────────────────────────
#   /opt/immich/docker-compose.yml         (Podman compose stack)
#   /opt/immich/.env                       (runtime configuration)
#   /opt/immich/postgresdata/              (PostgreSQL data)
#   /opt/immich/redis/                     (Valkey data)
#   /opt/immich/config/                    (Immich config state)
#   /opt/immich/library/                   (photo library)
#   /opt/immich-backups/                   (scoped maintenance backups: .env, compose, config)
#   /usr/local/bin/immich-maint.sh         (maintenance helper)
#   /etc/systemd/system/immich-stack.service
#   /etc/systemd/system/immich-update.service
#   /etc/systemd/system/immich-update.timer
#   /etc/systemd/system/container-getty@1.service.d/override.conf  (optional)
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/sysctl.d/99-hardening.conf

# ── Config validation ─────────────────────────────────────────────────────────
[[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }
[[ "$APP_PORT" =~ ^[0-9]+$ ]] || { echo "  ERROR: APP_PORT must be numeric." >&2; exit 1; }
(( APP_PORT >= 1 && APP_PORT <= 65535 )) || { echo "  ERROR: APP_PORT must be between 1 and 65535." >&2; exit 1; }
[[ "$KEEP_BACKUPS" =~ ^[0-9]+$ ]] || { echo "  ERROR: KEEP_BACKUPS must be numeric." >&2; exit 1; }
[[ -n "$IMMICH_IMAGE_REPO" && ! "$IMMICH_IMAGE_REPO" =~ [[:space:]] ]] || { echo "  ERROR: IMMICH_IMAGE_REPO must be non-empty and contain no spaces." >&2; exit 1; }
[[ -n "$IMMICH_TAG" && "$IMMICH_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "  ERROR: IMMICH_TAG must contain only tag-safe characters." >&2; exit 1; }
[[ "$AUTO_UPDATE" =~ ^[01]$ ]] || { echo "  ERROR: AUTO_UPDATE must be 0 or 1." >&2; exit 1; }
[[ "$TRACK_LATEST" =~ ^[01]$ ]] || { echo "  ERROR: TRACK_LATEST must be 0 or 1." >&2; exit 1; }
if [[ "$TRACK_LATEST" -eq 0 && "$IMMICH_TAG" == "latest" ]]; then
  echo "  ERROR: IMMICH_TAG must be a concrete tag when TRACK_LATEST=0." >&2
  exit 1
fi
[[ "$ENABLE_CONSOLE_AUTOLOGIN" =~ ^[01]$ ]] || { echo "  ERROR: ENABLE_CONSOLE_AUTOLOGIN must be 0 or 1." >&2; exit 1; }
if [[ -n "$PUBLIC_FQDN" && ! "$PUBLIC_FQDN" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "  ERROR: PUBLIC_FQDN contains invalid characters: $PUBLIC_FQDN" >&2
  exit 1
fi
if [[ "$PHOTO_STORAGE" != "rootfs" && "$PHOTO_STORAGE" != /* && ! "$PHOTO_STORAGE" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
  echo "  ERROR: PHOTO_STORAGE must be rootfs, an absolute host path, or a ZFS pool name." >&2
  exit 1
fi

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

for cmd in pvesh pveam pct pvesm curl python3 ip awk sort paste; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

if [[ "$PHOTO_STORAGE" != "rootfs" && "$PHOTO_STORAGE" != /* ]]; then
  command -v zfs >/dev/null 2>&1 || { echo "  ERROR: zfs command is required when PHOTO_STORAGE is a ZFS pool name." >&2; exit 1; }
fi

# ── Discover available resources ──────────────────────────────────────────────
AVAIL_TMPL_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'vztmpl' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_CT_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content','') or 'images' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^vmbr' | sort -u | paste -sd, - | sed 's/,/, /g' || echo "n/a")"
AVAIL_ZFS_POOLS="$(zpool list -H -o name 2>/dev/null | sort | paste -sd, - | sed 's/,/, /g' || echo "n/a")"

# ── Show defaults & confirm ───────────────────────────────────────────────────
cat <<EOF2

  Immich-Podman LXC Creator — Configuration
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
  Immich repo:       $IMMICH_IMAGE_REPO
  Immich tag:        $IMMICH_TAG
  Immich image:      $IMMICH_IMAGE
  Postgres image:    $POSTGRES_IMAGE
  Redis image:       $REDIS_IMAGE
  App port:          $APP_PORT
  Public FQDN:       ${PUBLIC_FQDN:-"(not set — local IP mode)"}
  Photo storage:     $PHOTO_STORAGE (available ZFS pools: $AVAIL_ZFS_POOLS)
  Timezone:          $APP_TZ
  Tags:              $TAGS
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled" || echo "disabled")
  Track latest:      $([ "$TRACK_LATEST" -eq 1 ] && echo "enabled" || echo "disabled")
  Console autologin: $([ "$ENABLE_CONSOLE_AUTOLOGIN" -eq 1 ] && echo "allowed if password blank" || echo "disabled")
  Keep backups:      $KEEP_BACKUPS
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/immich-podman.sh"
SCRIPT_LOCAL="/root/immich-podman.sh"
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
ip link show "$BRIDGE" >/dev/null 2>&1 \
  || { echo "  ERROR: Bridge not found: $BRIDGE" >&2; exit 1; }

# ── Root password ─────────────────────────────────────────────────────────────
PASSWORD=""
while true; do
  read -r -s -p "  Set root password (blank allowed): " PW1; echo
  [[ -z "$PW1" ]] && break
  if [[ "$PW1" == *" "* ]]; then echo "  Password cannot contain spaces."; continue; fi
  if [[ ${#PW1} -lt 8 ]]; then echo "  Password must be at least 8 characters."; continue; fi
  read -r -s -p "  Verify root password: " PW2; echo
  if [[ "$PW1" == "$PW2" ]]; then PASSWORD="$PW1"; break; fi
  echo "  Passwords do not match. Try again."
done

echo ""
if [[ -z "$PASSWORD" ]]; then
  echo "  WARNING: No root password was set."
  if [[ "$ENABLE_CONSOLE_AUTOLOGIN" -eq 1 ]]; then
    echo "  WARNING: Console auto-login is enabled by configuration."
  fi
  echo ""
fi

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
)
[[ -n "$PASSWORD" ]] && PCT_OPTIONS+=(-password "$PASSWORD")

pct create "$CT_ID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" "${PCT_OPTIONS[@]}"
CREATED=1

# ── Photos storage — ZFS dataset + LXC mount point ───────────────────────────
if [[ "$PHOTO_STORAGE" == "rootfs" ]]; then
  echo "  WARNING: No external photos storage configured — uploads will use rootfs (${DISK} GB)." >&2
  pct mount "$CT_ID"
  mkdir -p "/var/lib/lxc/${CT_ID}/rootfs/opt/immich" \
           "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/postgresdata" \
           "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/redis" \
           "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/library" \
           "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/config"
  chown 100000:100000 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich"
  chown 100070:100070 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/postgresdata"
  chmod 700          "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/postgresdata"
  chown 100999:101000 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/redis"
  chown 101000:101000 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/library"
  chown 101000:101000 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/config"
  pct unmount "$CT_ID"
elif [[ "$PHOTO_STORAGE" == /* ]]; then
  mkdir -p "$PHOTO_STORAGE"
  chown 101000:101000 "$PHOTO_STORAGE"
  pct mount "$CT_ID"
  mkdir -p "/var/lib/lxc/${CT_ID}/rootfs/opt/immich" \
           "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/postgresdata" \
           "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/redis" \
           "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/library" \
           "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/config"
  chown 100000:100000 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich"
  chown 100070:100070 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/postgresdata"
  chmod 700          "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/postgresdata"
  chown 100999:101000 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/redis"
  chown 101000:101000 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/library"
  chown 101000:101000 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/config"
  pct unmount "$CT_ID"
  pct set "$CT_ID" --mp0 "${PHOTO_STORAGE},mp=/opt/immich/library"
  echo "  Photos mount: ${PHOTO_STORAGE} -> /opt/immich/library (CT ${CT_ID})"
else
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
  mkdir -p "/var/lib/lxc/${CT_ID}/rootfs/opt/immich" \
           "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/postgresdata" \
           "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/redis" \
           "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/library" \
           "/var/lib/lxc/${CT_ID}/rootfs/opt/immich/config"
  chown 100000:100000 "/var/lib/lxc/${CT_ID}/rootfs/opt/immich"
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
  CT_IP="$(pct exec "$CT_ID" -- sh -lc '
    ip -4 -o addr show scope global 2>/dev/null | awk "{print \$4}" | cut -d/ -f1 | head -n1
  ' 2>/dev/null || true)"
  [[ -n "$CT_IP" ]] && break
  sleep 1
done
[[ -n "$CT_IP" ]] || { echo "  ERROR: No IPv4 address acquired via DHCP within timeout." >&2; exit 1; }
echo "  CT $CT_ID is up — IP: $CT_IP"

if [[ -z "$APP_URL" ]]; then
  APP_URL="http://${CT_IP}:${APP_PORT}"
fi

# ── Console auto-login (optional) ───────────────────────────────────────────
if [[ -z "$PASSWORD" && "$ENABLE_CONSOLE_AUTOLOGIN" -eq 1 ]]; then
  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    mkdir -p /etc/systemd/system/container-getty@1.service.d
    cat > /etc/systemd/system/container-getty@1.service.d/override.conf <<EOF2
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 \$TERM
EOF2
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
  apt-get clean
'

# ── Base packages, locale, timezone ───────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y locales curl ca-certificates iproute2 jq podman podman-compose fuse-overlayfs rsync tar gzip
  sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
  ln -sf /usr/share/zoneinfo/${APP_TZ} /etc/localtime
  echo '${APP_TZ}' > /etc/timezone
"

# ── Remove unnecessary services ───────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  systemctl disable --now ssh 2>/dev/null || true
  systemctl disable --now postfix 2>/dev/null || true
  apt-get purge -y openssh-server postfix 2>/dev/null || true
  apt-get -y autoremove
'

# ── Podman configuration ──────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  mkdir -p /etc/containers

  cat > /etc/containers/storage.conf <<EOF2
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
EOF2

  cat > /etc/containers/containers.conf <<EOF2
[containers]
log_size_max = 10485760
EOF2
'

pct exec "$CT_ID" -- podman info >/dev/null 2>&1
pct exec "$CT_ID" -- podman --version
pct exec "$CT_ID" -- podman-compose --version

# ── Secrets ───────────────────────────────────────────────────────────────────
DB_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40 || true)"
[[ ${#DB_PASSWORD} -eq 40 ]] || { echo "  ERROR: Failed to generate DB password." >&2; exit 1; }

# ── Prepare persistent volumes (absolute paths) ───────────────────────────────
echo "  Verifying persistent volume ownership..."
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  ls -ld /opt/immich/postgresdata /opt/immich/redis /opt/immich/library /opt/immich/config
  echo "  Volumes OK"
'

# ── Compose file ──────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "cat > '${APP_DIR}/docker-compose.yml' <<'EOF2'
networks:
  immich:
    driver: bridge

services:
  postgres:
    image: \${POSTGRES_IMAGE}
    container_name: immich_postgres
    restart: unless-stopped
    networks:
      - immich
    environment:
      POSTGRES_USER: immich
      POSTGRES_PASSWORD: \${DB_PASSWORD}
      POSTGRES_DB: immich
      POSTGRES_INITDB_ARGS: --data-checksums
      TZ: \${APP_TZ}
    volumes:
      - /opt/immich/postgresdata:/var/lib/postgresql/data:Z
    healthcheck:
      test: [\"CMD-SHELL\", \"pg_isready -U immich -d immich\"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

  valkey:
    image: \${REDIS_IMAGE}
    container_name: immich_valkey
    restart: unless-stopped
    networks:
      - immich
    environment:
      TZ: \${APP_TZ}
    volumes:
      - /opt/immich/redis:/data:Z
    healthcheck:
      test: [\"CMD\", \"valkey-cli\", \"ping\"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

  immich:
    image: \${IMMICH_IMAGE}
    container_name: immich
    restart: unless-stopped
    networks:
      - immich
    ports:
      - \"\${APP_PORT}:8080\"
    environment:
      PUID: 1000
      PGID: 1000
      TZ: \${APP_TZ}
      DB_HOSTNAME: postgres
      DB_USERNAME: immich
      DB_PASSWORD: \${DB_PASSWORD}
      DB_DATABASE_NAME: immich
      REDIS_HOSTNAME: valkey
    volumes:
      - /opt/immich/library:/photos:Z
      - /opt/immich/config:/config:Z
    depends_on:
      postgres:
        condition: service_healthy
      valkey:
        condition: service_healthy
EOF2"

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > '${APP_DIR}/.env' <<EOF2
COMPOSE_PROJECT_NAME=immich
IMMICH_IMAGE_REPO=${IMMICH_IMAGE_REPO}
IMMICH_TAG=${IMMICH_TAG}
IMMICH_IMAGE=${IMMICH_IMAGE}
POSTGRES_IMAGE=${POSTGRES_IMAGE}
REDIS_IMAGE=${REDIS_IMAGE}
APP_PORT=${APP_PORT}
APP_TZ=${APP_TZ}
PUBLIC_FQDN=${PUBLIC_FQDN}
APP_URL=${APP_URL}
DB_PASSWORD=${DB_PASSWORD}
KEEP_BACKUPS=${KEEP_BACKUPS}
AUTO_UPDATE=${AUTO_UPDATE}
TRACK_LATEST=${TRACK_LATEST}
EOF2
  chmod 0600 '${APP_DIR}/.env' '${APP_DIR}/docker-compose.yml'
  install -d -m 0755 '${BACKUP_DIR}'
"

# ── Maintenance script ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/immich-maint.sh && chmod 0755 /usr/local/bin/immich-maint.sh' <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR="${APP_DIR:-/opt/immich}"
BACKUP_DIR="${BACKUP_DIR:-/opt/immich-backups}"
SERVICE="immich-stack.service"
ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
KEEP_BACKUPS="${KEEP_BACKUPS:-7}"
APP_PORT="${APP_PORT:-2283}"

need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF2
  Immich Maintenance
  ──────────────────
  Usage:
    $0 backup
    $0 list
    $0 restore <backup.tar.gz>
    $0 update <immich-tag|latest>
    $0 auto-update
    $0 version

  Notes:
    - backup stops the stack for a consistent snapshot, then starts it again
    - backup is intentionally scoped to .env, compose, and /opt/immich/config
    - backup does NOT include photo library, PostgreSQL, or Valkey data
    - update backs up first, then changes only the Immich app image tag
    - latest is only accepted when TRACK_LATEST=1 is intentionally enabled
    - auto-update obeys AUTO_UPDATE and TRACK_LATEST from ${ENV_FILE}
    - PostgreSQL and Valkey image changes are intentionally manual
EOF2
}

[[ -d "$APP_DIR" ]] || die "APP_DIR not found: $APP_DIR"
[[ -f "$ENV_FILE" ]] || die "Missing env file: $ENV_FILE"
[[ -f "$COMPOSE_FILE" ]] || die "Missing compose file: $COMPOSE_FILE"

env_keep_backups="$(awk -F= '/^KEEP_BACKUPS=/{print $2}' "$ENV_FILE" | tail -n1)"
if [[ "$env_keep_backups" =~ ^[0-9]+$ ]]; then
  KEEP_BACKUPS="$env_keep_backups"
fi

env_app_port="$(awk -F= '/^APP_PORT=/{print $2}' "$ENV_FILE" | tail -n1)"
if [[ "$env_app_port" =~ ^[0-9]+$ ]]; then
  APP_PORT="$env_app_port"
fi

current_repo() {
  awk -F= '/^IMMICH_IMAGE_REPO=/{print $2}' "$ENV_FILE" | tail -n1
}

current_tag() {
  local tag
  tag="$(awk -F= '/^IMMICH_TAG=/{print $2}' "$ENV_FILE" | tail -n1)"
  if [[ -n "$tag" ]]; then
    printf '%s\n' "$tag"
    return 0
  fi
  local img
  img="$(current_image)"
  printf '%s\n' "${img##*:}"
}

current_image() {
  awk -F= '/^IMMICH_IMAGE=/{print $2}' "$ENV_FILE" | tail -n1
}

current_postgres_image() {
  awk -F= '/^POSTGRES_IMAGE=/{print $2}' "$ENV_FILE" | tail -n1
}

current_redis_image() {
  awk -F= '/^REDIS_IMAGE=/{print $2}' "$ENV_FILE" | tail -n1
}

env_flag() {
  local key="$1" raw
  raw="$(awk -F= -v key="$key" '$1==key{print $2}' "$ENV_FILE" | tail -n1 | tr -d '[:space:]')"
  [[ "$raw" =~ ^[01]$ ]] && printf '%s' "$raw" || printf '0'
}

auto_update_enabled() {
  [[ "$(env_flag AUTO_UPDATE)" == "1" ]]
}

track_latest_enabled() {
  [[ "$(env_flag TRACK_LATEST)" == "1" ]]
}

resolve_auto_tag() {
  if track_latest_enabled; then
    printf '%s\n' latest
  else
    current_tag
  fi
}

backup_stack() {
  local ts out started=0
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$BACKUP_DIR/immich-backup-$ts.tar.gz"

  mkdir -p "$BACKUP_DIR"

  if systemctl is-active --quiet "$SERVICE"; then
    started=1
    echo "  Stopping Immich stack for consistent backup ..."
    systemctl stop "$SERVICE"
  fi

  trap 'if [[ $started -eq 1 ]]; then systemctl start "$SERVICE" || true; fi' RETURN

  echo "  Creating scoped backup: $out"
  tar -C / -czf "$out" \
    opt/immich/.env \
    opt/immich/docker-compose.yml \
    opt/immich/config

  if [[ "$KEEP_BACKUPS" =~ ^[0-9]+$ ]] && (( KEEP_BACKUPS > 0 )); then
    ls -1t "$BACKUP_DIR"/immich-backup-*.tar.gz 2>/dev/null | awk -v keep="$KEEP_BACKUPS" 'NR>keep' | xargs -r rm -f --
  fi

  echo "  OK: $out"
}

restore_stack() {
  local backup="$1"
  [[ -n "$backup" ]] || die "Usage: immich-maint.sh restore <backup.tar.gz>"
  [[ -f "$backup" ]] || die "Backup not found: $backup"

  echo "  Stopping Immich stack ..."
  systemctl stop "$SERVICE" 2>/dev/null || true

  echo "  Removing current scoped maintenance state ..."
  rm -rf \
    "$APP_DIR/.env" \
    "$APP_DIR/docker-compose.yml" \
    "$APP_DIR/config"

  echo "  Restoring backup ..."
  tar -C / -xzf "$backup"

  echo "  Starting Immich stack ..."
  systemctl start "$SERVICE"
  echo "  OK: restore completed."
}

update_immich() {
  local new_tag="$1" old_image old_tag old_repo new_image tmp_env health=0
  [[ -n "$new_tag" ]] || die "Usage: immich-maint.sh update <immich-tag|latest>"
  [[ "$new_tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid Immich tag: $new_tag"
  if [[ "$new_tag" == "latest" && "$(env_flag TRACK_LATEST)" != "1" ]]; then
    die "Refusing to set IMMICH_TAG=latest while TRACK_LATEST=0; use a concrete tag or enable TRACK_LATEST=1 intentionally."
  fi

  old_image="$(current_image)"
  old_tag="$(current_tag)"
  old_repo="$(current_repo)"
  [[ -n "$old_image" ]] || die "Could not read current IMMICH_IMAGE from .env"
  [[ -n "$old_repo" ]] || die "Could not read current IMMICH_IMAGE_REPO from .env"
  new_image="${old_repo}:${new_tag}"
  tmp_env="$(mktemp)"

  echo "  Current Immich tag:   $old_tag"
  echo "  Current Immich image: $old_image"
  echo "  Target  Immich tag:   $new_tag"
  echo "  Target  Immich image: $new_image"

  backup_stack
  cp -a "$ENV_FILE" "$tmp_env"

  cleanup() { rm -f "$tmp_env"; }
  rollback() {
    echo "  !! Update failed — rolling back .env and container ..." >&2
    cp -a "$tmp_env" "$ENV_FILE"
    cd "$APP_DIR"
    /usr/bin/podman-compose up -d --force-recreate immich || true
  }
  trap rollback ERR

  echo "  Pulling target image ..."
  podman pull "$new_image"

  sed -i \
    -e "s|^IMMICH_TAG=.*|IMMICH_TAG=$new_tag|" \
    -e "s|^IMMICH_IMAGE=.*|IMMICH_IMAGE=$new_image|" \
    "$ENV_FILE"

  echo "  Recreating Immich container ..."
  cd "$APP_DIR"
  /usr/bin/podman-compose up -d --force-recreate immich

  echo "  Waiting for health endpoint ..."
  for i in $(seq 1 45); do
    if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${APP_PORT}/api/server/ping"; then
      health=1
      break
    fi
    sleep 2
  done
  [[ "$health" -eq 1 ]] || die "Immich health endpoint did not return success after update."

  trap - ERR
  cleanup
  echo "  OK: Immich updated to $new_tag"
}

auto_update_immich() {
  local target_tag

  if ! auto_update_enabled; then
    echo "  Auto-update disabled in ${ENV_FILE}; nothing to do."
    return 0
  fi

  target_tag="$(resolve_auto_tag)"
  if track_latest_enabled; then
    echo "  Auto-update policy: TRACK_LATEST=1 -> following latest"
  else
    echo "  Auto-update policy: TRACK_LATEST=0 -> reapplying configured tag $(current_tag)"
  fi

  update_immich "$target_tag"
}

need_root
cmd="${1:-}"
case "$cmd" in
  backup) backup_stack ;;
  list) ls -1t "$BACKUP_DIR"/immich-backup-*.tar.gz 2>/dev/null || true ;;
  restore) shift; restore_stack "${1:-}" ;;
  update) shift; update_immich "${1:-}" ;;
  auto-update) auto_update_immich ;;
  version)
    echo "Immich repo:     $(current_repo)"
    echo "Immich tag:      $(current_tag)"
    echo "Immich image:    $(current_image)"
    echo "Postgres image:  $(current_postgres_image)"
    echo "Redis image:     $(current_redis_image)"
    echo "AUTO_UPDATE=$(env_flag AUTO_UPDATE)"
    echo "TRACK_LATEST=$(env_flag TRACK_LATEST)"
    ;;
  ""|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
MAINT
echo "  Maintenance script deployed: /usr/local/bin/immich-maint.sh"

# ── Pull images ───────────────────────────────────────────────────────────────
echo "  Pulling Immich images ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman pull '${IMMICH_IMAGE}'
  podman pull '${POSTGRES_IMAGE}'
  podman pull '${REDIS_IMAGE}'
"

# ── Systemd stack unit ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/immich-stack.service <<EOF2
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
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF2

  systemctl daemon-reload
  systemctl enable --now immich-stack.service
'

# ── Verification ──────────────────────────────────────────────────────────────
sleep 3
if pct exec "$CT_ID" -- systemctl is-active --quiet immich-stack.service 2>/dev/null; then
  echo "  Immich stack service is active"
else
  echo "  WARNING: immich-stack.service may not be active — check: pct exec $CT_ID -- journalctl -u immich-stack --no-pager -n 50" >&2
fi

RUNNING=0
for i in $(seq 1 90); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc 'podman ps --format "{{.Names}}" 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge 3 ]] && break
  sleep 2
done
pct exec "$CT_ID" -- bash -lc 'cd /opt/immich && podman-compose ps' || true

IMMICH_HEALTHY=0
for i in $(seq 1 45); do
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${APP_PORT}/api/server/ping 2>/dev/null" 2>/dev/null || echo 000)"
  if [[ "$HTTP_CODE" =~ ^(200|204)$ ]]; then
    IMMICH_HEALTHY=1
    break
  fi
  sleep 2
done

if [[ "$IMMICH_HEALTHY" -eq 1 ]]; then
  echo "  Immich health check passed"
else
  echo "  WARNING: Immich health endpoint did not return success yet" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u immich-stack.service --no-pager -n 80" >&2
  echo "  Check: pct exec $CT_ID -- bash -lc 'cd /opt/immich && podman-compose logs --tail=80'" >&2
fi

# ── Auto-update timer (policy-driven) ─────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/immich-update.service <<EOF2
[Unit]
Description=Immich auto-update maintenance run
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/immich-maint.sh auto-update
EOF2

  cat > /etc/systemd/system/immich-update.timer <<EOF2
[Unit]
Description=Immich auto-update timer

[Timer]
OnCalendar=*-*-01 05:30:00
OnCalendar=*-*-15 05:30:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF2

  systemctl daemon-reload
'

if [[ "$AUTO_UPDATE" -eq 1 ]]; then
  pct exec "$CT_ID" -- bash -lc 'systemctl enable --now immich-update.timer'
  echo "  Auto-update timer enabled"
else
  pct exec "$CT_ID" -- bash -lc 'systemctl disable --now immich-update.timer >/dev/null 2>&1 || true'
  echo "  Auto-update timer installed but disabled"
fi

# ── Unattended upgrades ───────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y unattended-upgrades
  distro_codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  cat > /etc/apt/apt.conf.d/52unattended-$(hostname).conf <<EOF2
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security";
        "origin=Debian,codename=${distro_codename},label=Debian";
        "origin=Debian,codename=${distro_codename}-updates,label=Debian";
};
Unattended-Upgrade::Package-Blacklist {};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF2
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF2
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF2
  systemctl enable --now unattended-upgrades
'

# ── Sysctl hardening ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/sysctl.d/99-hardening.conf <<EOF2
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
EOF2
  sysctl --system >/dev/null 2>&1 || true
'

# ── Cleanup packages ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y man-db manpages 2>/dev/null || true
  apt-get -y autoremove
  apt-get clean
'

# ── MOTD (dynamic drop-ins) ───────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  > /etc/motd
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
  rm -f /etc/update-motd.d/*

  cat > /etc/update-motd.d/00-header <<'EOF2'
#!/bin/sh
printf '\n  Immich (Podman)\n'
printf '  ────────────────────────────────────\n'
EOF2

  cat > /etc/update-motd.d/10-sysinfo <<'EOF2'
#!/bin/sh
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '  Hostname:  %s\n' \"\$(hostname)\"
printf '  IP:        %s\n' \"\${ip:-n/a}\"
printf '  Uptime:    %s\n' \"\$(uptime -p 2>/dev/null || uptime)\"
printf '  Disk:      %s\n' \"\$(df -h / | awk 'NR==2{printf \"%s/%s (%s used)\", \$3, \$2, \$5}')\"
EOF2

  cat > /etc/update-motd.d/30-app <<'EOF2'
#!/bin/sh
running=\$(podman ps --format '{{.Names}}' 2>/dev/null | wc -l)
service_active=\$(systemctl is-active immich-stack.service 2>/dev/null || echo 'unknown')
configured_image=\$(awk -F= '/^IMMICH_IMAGE=/{print \$2}' /opt/immich/.env 2>/dev/null | tail -n1)
configured_tag=\$(awk -F= '/^IMMICH_TAG=/{print \$2}' /opt/immich/.env 2>/dev/null | tail -n1)
auto_update=\$(awk -F= '/^AUTO_UPDATE=/{print \$2}' /opt/immich/.env 2>/dev/null | tail -n1)
track_latest=\$(awk -F= '/^TRACK_LATEST=/{print \$2}' /opt/immich/.env 2>/dev/null | tail -n1)
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '  Stack:     /opt/immich (%s containers running)\n' \"\$running\"
printf '  Service:   %s\n' \"\$service_active\"
printf '  Image:     %s\n' \"\${configured_image:-n/a}\"
printf '  Backup:    /opt/immich-backups (scoped: .env, compose, config)\n'
printf '  Compose:   cd /opt/immich && podman-compose [up -d|down|logs|ps]\n'
printf '  Maintain:  immich-maint.sh [backup|list|restore|update|auto-update|version]\n'
printf '  Web UI:    http://%s:${APP_PORT}\n' \"\${ip:-n/a}\"
printf '  Health:    http://%s:${APP_PORT}/api/server/ping\n' \"\${ip:-n/a}\"
[ -n '${PUBLIC_FQDN}' ] && printf '  Public:    https://${PUBLIC_FQDN}\n' || true
printf '\n'
printf '  Post-setup:\n'
printf '    1. Open Web UI — first registered user becomes admin\n'
printf '       Note: ML models load on first use — cold start can take a few minutes\n'
printf '    2. Admin -> Settings -> Server -> Public URL\n'
printf '       set to: https://<your-domain>\n'
printf '    3. NPM proxy host -> enable WebSockets Support\n'
printf '    4. NPM proxy host -> Advanced -> Custom Nginx Configuration:\n'
printf '         client_max_body_size 0;\n'
printf '         proxy_read_timeout 600s;\n'
printf '         proxy_send_timeout 600s;\n'
printf '         proxy_buffering off;\n'
EOF2

  cat > /etc/update-motd.d/99-footer <<'EOF2'
#!/bin/sh
printf '  ────────────────────────────────────\n\n'
EOF2

  chmod +x /etc/update-motd.d/*
"
# Set TERM for console
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Proxmox UI description ────────────────────────────────────────────────────
if [[ -n "$PUBLIC_FQDN" ]]; then
  IMMICH_LINK="https://${PUBLIC_FQDN}/"
else
  IMMICH_LINK="http://${CT_IP}:${APP_PORT}/"
fi
IMMICH_DESC="<a href='${IMMICH_LINK}' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Immich Web UI</a>
<details><summary>Details</summary>Immich (Podman, imagegenius monolith) on Debian ${DEBIAN_VERSION} LXC
Created by immich-podman.sh</details>"
pct set "$CT_ID" --description "$IMMICH_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  CT: $CT_ID | IP: ${CT_IP} | Login: $([ -n "$PASSWORD" ] && echo 'password set' || echo 'no password set')"
echo ""
echo "  Access (local):"
echo "    Main: http://${CT_IP}:${APP_PORT}/"
echo "    Health: http://${CT_IP}:${APP_PORT}/api/server/ping"
if [[ -n "$PUBLIC_FQDN" ]]; then
  echo ""
  echo "  Access (public):"
  echo "    Main: https://${PUBLIC_FQDN}/"
fi
echo ""
echo "  Config files:"
echo "    ${APP_DIR}/docker-compose.yml"
echo "    ${APP_DIR}/.env"
echo ""
echo "  Persistent paths:"
echo "    ${APP_DIR}/postgresdata"
echo "    ${APP_DIR}/redis"
echo "    ${APP_DIR}/config"
if [[ "$PHOTO_STORAGE" == "rootfs" ]]; then
  echo "    ${APP_DIR}/library (rootfs — consider external storage for production)"
elif [[ "$PHOTO_STORAGE" == /* ]]; then
  echo "    ${APP_DIR}/library <- ${PHOTO_STORAGE}"
else
  echo "    ${APP_DIR}/library <- ${PHOTOS_HOST_PATH} (${PHOTO_STORAGE}/immich-photos)"
fi
echo ""
echo "  Maintenance:"
echo "    pct exec $CT_ID -- immich-maint.sh backup"
echo "    pct exec $CT_ID -- immich-maint.sh list"
echo "    Policy: AUTO_UPDATE=${AUTO_UPDATE} TRACK_LATEST=${TRACK_LATEST}"
echo "    pct exec $CT_ID -- immich-maint.sh update <immich-tag|latest>"
echo "    Backup scope: .env, compose, config only (no library/DB/redis)"
echo "    pct exec $CT_ID -- immich-maint.sh auto-update"
echo "    pct exec $CT_ID -- immich-maint.sh restore /opt/immich-backups/<backup.tar.gz>"
echo ""
echo "  Reverse proxy (NPM):"
echo "    Enable WebSockets Support"
echo "    Advanced -> Custom Nginx Configuration:"
echo "      client_max_body_size 0;"
echo "      proxy_read_timeout 600s;"
echo "      proxy_send_timeout 600s;"
echo "      proxy_buffering off;"
echo ""
echo "  Done."
