#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID=""                             # empty = auto-assign via pvesh; set e.g. CT_ID=120 to pin
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
HN="nextcloud"
CPU=4
RAM=6144
DISK=40
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Nextcloud AIO / Docker
AIO_APACHE_PORT=11000
APP_TZ="Europe/Berlin"
TAGS="nextcloud;aio;docker;lxc"
DEBIAN_VERSION=13

# AIO mastercontainer image
# AIO uses :latest as the normal release track; the mastercontainer manages
# all downstream Nextcloud service containers internally.
AIO_IMAGE_REPO="ghcr.io/nextcloud-releases/all-in-one"
AIO_TAG="latest"

# Data storage for NEXTCLOUD_DATADIR — choose one mode:
#   rootfs          — data lives inside the LXC rootfs (default; warn-only)
#   /host/path      — absolute host path, bind-mounted into the CT
#   <zfs-pool-name> — ZFS pool; script creates or reuses <pool>/nextcloud-data dataset
# NEXTCLOUD_DATADIR is the CT-internal path AIO always sees. Do not change it.
NCDATA_STORAGE="rootfs"
NEXTCLOUD_DATADIR="/opt/nextcloud-aio/data"

# Domain validation — AIO's domain validation is known not to work behind
# Cloudflare Tunnel. Leave at 1 for this topology (matches official AIO guidance).
# Only set to 0 if you are NOT using Cloudflare Tunnel and need AIO to verify
# the domain is reachable before completing setup.
SKIP_DOMAIN_VALIDATION=1

# NPM host private IP — used by the maint script to configure trusted_proxies
# after the initial AIO setup is complete. Leave empty to configure manually later.
# Example: NPM_HOST_IP="10.10.10.5"
NPM_HOST_IP=""

# Extra packages to install (space-separated or array)
EXTRA_PACKAGES=(
  qemu-guest-agent
)

# Behavior
CLEANUP_ON_FAIL=1

# Derived
APP_DIR="/opt/nextcloud-aio"
AIO_IMAGE="${AIO_IMAGE_REPO}:${AIO_TAG}"

# ── Custom configs created by this script ─────────────────────────────────────
#   /opt/nextcloud-aio/docker-compose.yml        (AIO compose stack)
#   /opt/nextcloud-aio/.env                      (runtime configuration)
#   /opt/nextcloud-aio/data/                     (Nextcloud data dir — rootfs default;
#                                                 or bind-mounted from NCDATA_STORAGE)
#   /usr/local/bin/nextcloud-aio-maint.sh        (maintenance helper)
#   /etc/systemd/system/nextcloud-aio.service
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/sysctl.d/99-hardening.conf

# ── Config validation ─────────────────────────────────────────────────────────
[[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }
[[ "$AIO_APACHE_PORT" =~ ^[0-9]+$ ]] || { echo "  ERROR: AIO_APACHE_PORT must be numeric." >&2; exit 1; }
(( AIO_APACHE_PORT >= 1 && AIO_APACHE_PORT <= 65535 )) || { echo "  ERROR: AIO_APACHE_PORT out of range." >&2; exit 1; }
[[ "$SKIP_DOMAIN_VALIDATION" =~ ^[01]$ ]] || { echo "  ERROR: SKIP_DOMAIN_VALIDATION must be 0 or 1." >&2; exit 1; }
[[ -e "/usr/share/zoneinfo/${APP_TZ}" ]] || { echo "  ERROR: APP_TZ not found: $APP_TZ" >&2; exit 1; }
[[ -z "$NPM_HOST_IP" ]] || [[ "$NPM_HOST_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "  ERROR: NPM_HOST_IP must be an IPv4 address or empty." >&2; exit 1
}
if [[ "$NCDATA_STORAGE" != "rootfs" && "$NCDATA_STORAGE" != /* && \
    ! "$NCDATA_STORAGE" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
  echo "  ERROR: NCDATA_STORAGE must be 'rootfs', an absolute host path, or a ZFS pool name." >&2
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

for cmd in pvesh pveam pct pvesm curl python3 ip awk sort paste readlink cp chmod; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

if [[ "$NCDATA_STORAGE" != "rootfs" && "$NCDATA_STORAGE" != /* ]]; then
  command -v zfs >/dev/null 2>&1 \
    || { echo "  ERROR: zfs command required when NCDATA_STORAGE is a ZFS pool name." >&2; exit 1; }
fi

# ── Discover available resources ──────────────────────────────────────────────
AVAIL_TMPL_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'vztmpl' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_CT_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^vmbr' | sort | paste -sd, | sed 's/,/, /g' || echo "n/a")"
AVAIL_ZFS_POOLS="$(zpool list -H -o name 2>/dev/null | sort | paste -sd, - | sed 's/,/, /g' || echo "n/a")"

# ── Show defaults & confirm ───────────────────────────────────────────────────
cat <<EOF2

  Nextcloud AIO (Docker) — LXC Creator — Configuration
  ─────────────────────────────────────────────────────
  CT ID:             $CT_ID
  Hostname:          $HN
  CPU cores:         $CPU
  RAM (MB):          $RAM
  Disk (GB):         $DISK
  Bridge:            $BRIDGE  ($AVAIL_BRIDGES)
  Template storage:  $TEMPLATE_STORAGE  ($AVAIL_TMPL_STORES)
  Container storage: $CONTAINER_STORAGE  ($AVAIL_CT_STORES)
  Debian:            $DEBIAN_VERSION
  AIO image:         $AIO_IMAGE
  Admin UI port:     8080 (fixed — AIO does not support remapping this port)
  Apache port:       $AIO_APACHE_PORT  (NPM backend target)
  Data dir:          $NEXTCLOUD_DATADIR
  Domain validation: $([ "$SKIP_DOMAIN_VALIDATION" -eq 1 ] && echo "skipped (correct for Cloudflare Tunnel)" || echo "enabled (only if not using Cloudflare Tunnel)")
  NPM host IP:       ${NPM_HOST_IP:-"(not set — configure after AIO setup)"}
  Data storage:      ${NCDATA_STORAGE}  (ZFS pools: ${AVAIL_ZFS_POOLS})
  Timezone:          $APP_TZ
  Tags:              $TAGS
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ─────────────────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/nextcloud-aio-docker.sh"
SCRIPT_LOCAL="/root/nextcloud-aio-docker.sh"
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
TEMPLATE="$(pveam available -section system \
  | awk -v p="debian-${DEBIAN_VERSION}" '$2 ~ ("^" p) {print $2}' \
  | sort -V | tail -n1)"
if [[ -z "$TEMPLATE" ]]; then
  echo "  WARNING: No Debian ${DEBIAN_VERSION} template found, trying any Debian..." >&2
  TEMPLATE="$(pveam available -section system \
    | awk '$2 ~ /^debian-/ {print $2}' | sort -V | tail -n1)"
fi
[[ -n "$TEMPLATE" ]] || { echo "  ERROR: No Debian template found via pveam." >&2; exit 1; }
echo "  Template: $TEMPLATE"

if [[ "$TEMPLATE_STORAGE" == "local" && -f "/var/lib/vz/template/cache/$TEMPLATE" ]]; then
  echo "  Template already present."
else
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

# ── Create LXC ────────────────────────────────────────────────────────────────
# nesting=1  — required for Docker inside the LXC
# keyctl=1   — required for Docker daemon in unprivileged LXC
# fuse=1     — required for overlay filesystem (fuse-overlayfs fallback)
PCT_OPTIONS=(
  -hostname   "$HN"
  -cores      "$CPU"
  -memory     "$RAM"
  -rootfs     "${CONTAINER_STORAGE}:${DISK}"
  -onboot     1
  -ostype     debian
  -unprivileged 1
  -features   "nesting=1,keyctl=1,fuse=1"
  -tags       "$TAGS"
  -net0       "name=eth0,bridge=${BRIDGE},ip=dhcp,ip6=manual"
  -password   "$PASSWORD"
)

echo "  Creating LXC ${CT_ID} (${HN})..."
pct create "$CT_ID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" "${PCT_OPTIONS[@]}"
CREATED=1

# ── Data storage — setup and LXC bind mount ───────────────────────────────────
NCDATA_EXISTING=0    # 1 = existing data confirmed; skip chmod inside CT

if [[ "$NCDATA_STORAGE" == "rootfs" ]]; then
  echo "  WARNING: No external data storage configured — Nextcloud data will use" >&2
  echo "           rootfs (${DISK} GB). Consider NCDATA_STORAGE for production use." >&2

elif [[ "$NCDATA_STORAGE" == /* ]]; then
  if [[ -d "$NCDATA_STORAGE" ]] && [[ -n "$(ls -A "$NCDATA_STORAGE" 2>/dev/null)" ]]; then
    echo ""
    echo "  !! EXISTING DATA DETECTED — host path: ${NCDATA_STORAGE}"
    echo "  This directory is non-empty and will be mounted as NEXTCLOUD_DATADIR"
    echo "  on the new instance. Existing user files will be preserved."
    echo "  Host-side ownership is NOT changed — it must already be 100033:100033"
    echo "  (www-data inside the CT) from the previous deployment."
    echo "  After AIO setup completes, run:"
    echo "    nextcloud-aio-maint.sh files-scan --all"
    echo "  to rebuild the file index. Re-create users with identical usernames"
    echo "  before scanning, or files will not be reattached correctly."
    echo ""
    read -r -p "  Attach existing data to new instance? [y/N]: " _dr
    case "$_dr" in
      [yY][eE][sS]|[yY]) NCDATA_EXISTING=1 ;;
      *) echo "  Aborted." >&2; exit 1 ;;
    esac
  else
    mkdir -p "$NCDATA_STORAGE"
    # Unprivileged LXC idmap: container UID 33 (www-data, AIO Nextcloud runtime user)
    # maps to host UID 100033. The bind mount must be owned by 100033:100033 on the
    # host so AIO can chown NEXTCLOUD_DATADIR to www-data from inside the container.
    chown 100033:100033 "$NCDATA_STORAGE"
  fi
  pct set "$CT_ID" --mp0 "${NCDATA_STORAGE},mp=${NEXTCLOUD_DATADIR}"
  echo "  Data mount: ${NCDATA_STORAGE} -> ${NEXTCLOUD_DATADIR} (CT ${CT_ID})"

else
  NCDATA_DATASET="${NCDATA_STORAGE}/nextcloud-data"
  NCDATA_HOST_PATH="$(zfs get -H -o value mountpoint "${NCDATA_DATASET}" 2>/dev/null || true)"
  if [[ -z "$NCDATA_HOST_PATH" || "$NCDATA_HOST_PATH" == "-" ]]; then
    echo "  Creating ZFS dataset: ${NCDATA_DATASET}"
    zfs create -o compression=lz4 "${NCDATA_DATASET}"
    NCDATA_HOST_PATH="$(zfs get -H -o value mountpoint "${NCDATA_DATASET}")"
    # Unprivileged LXC idmap: container UID 33 (www-data, AIO Nextcloud runtime user)
    # maps to host UID 100033. The dataset mountpoint must be owned by 100033:100033
    # on the host so AIO can chown NEXTCLOUD_DATADIR to www-data from inside the CT.
    chown 100033:100033 "$NCDATA_HOST_PATH"
  else
    _ncdata_empty=1
    [[ -n "$(ls -A "$NCDATA_HOST_PATH" 2>/dev/null)" ]] && _ncdata_empty=0
    echo ""
    echo "  !! EXISTING ZFS DATASET DETECTED"
    echo "  Dataset:  ${NCDATA_DATASET}"
    echo "  Path:     ${NCDATA_HOST_PATH}"
    if [[ "$_ncdata_empty" -eq 0 ]]; then
      echo "  Content:  non-empty — existing Nextcloud user data found"
      echo "  This dataset will be mounted as NEXTCLOUD_DATADIR on the new instance."
      echo "  Existing user files will be preserved."
      echo "  Host-side ownership is NOT changed — it must already be 100033:100033"
      echo "  (www-data inside the CT) from the previous deployment."
      echo "  After AIO setup completes, run:"
      echo "    nextcloud-aio-maint.sh files-scan --all"
      echo "  to rebuild the file index. Re-create users with identical usernames"
      echo "  before scanning, or files will not be reattached correctly."
    else
      echo "  Content:  empty dataset — no existing data"
    fi
    echo ""
    read -r -p "  Attach this dataset to new instance? [y/N]: " _dr
    case "$_dr" in
      [yY][eE][sS]|[yY])
        [[ "$_ncdata_empty" -eq 0 ]] && NCDATA_EXISTING=1
        ;;
      *) echo "  Aborted." >&2; exit 1 ;;
    esac
  fi
  pct set "$CT_ID" --mp0 "${NCDATA_HOST_PATH},mp=${NEXTCLOUD_DATADIR}"
  echo "  Data mount: ${NCDATA_HOST_PATH} -> ${NEXTCLOUD_DATADIR} (CT ${CT_ID})"
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
  apt-get install -y locales curl ca-certificates gnupg iproute2 tar gzip
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

# ── Docker Engine — install from official Debian repository ───────────────────
# AIO requires Docker Engine; Podman is not supported by Nextcloud AIO.
echo "  Installing Docker Engine (official Debian repository)..."
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive

  # Remove any conflicting system packages
  apt-get remove -y docker.io docker-compose docker-doc podman-docker containerd runc 2>/dev/null || true

  # Add Docker GPG key
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  # Add Docker repository
  distro_codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  cat > /etc/apt/sources.list.d/docker.sources <<EOF_DOCKER
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${distro_codename}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF_DOCKER

  apt-get update -qq
  apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  systemctl enable --now docker
'

# Quick sanity check — Docker must be functional before proceeding
pct exec "$CT_ID" -- docker info >/dev/null 2>&1 \
  || { echo "  ERROR: Docker daemon not responding after install." >&2; exit 1; }
pct exec "$CT_ID" -- docker --version

# ── Directory and data dir setup ──────────────────────────────────────────────
echo "  Setting up directory structure..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  mkdir -p '${APP_DIR}'
  chmod 0750 '${APP_DIR}'
"
# rootfs mode: create and seed the data dir.
# External modes: bind mount is in place; AIO manages NEXTCLOUD_DATADIR permissions.
if [[ "$NCDATA_STORAGE" == "rootfs" ]]; then
  pct exec "$CT_ID" -- bash -lc "
    set -euo pipefail
    mkdir -p '${NEXTCLOUD_DATADIR}'
    chmod 0755 '${NEXTCLOUD_DATADIR}'
  "
fi

# ── AIO .env ──────────────────────────────────────────────────────────────────
# docker compose reads .env from the project directory automatically.
# Runtime-editable fields only — compose-time values live in docker-compose.yml.
SKIP_VAL_STR="$([ "$SKIP_DOMAIN_VALIDATION" -eq 1 ] && echo 'true' || echo 'false')"
pct exec "$CT_ID" -- bash -lc 'cat > /opt/nextcloud-aio/.env && chmod 0600 /opt/nextcloud-aio/.env' <<EOF_ENV
# Nextcloud AIO — runtime configuration
# Generated by nextcloud-aio-docker.sh
# Edit here to change image or policy; then run: nextcloud-aio-maint.sh update

AIO_IMAGE_REPO=${AIO_IMAGE_REPO}
AIO_TAG=${AIO_TAG}
AIO_IMAGE=${AIO_IMAGE}

NEXTCLOUD_DATADIR=${NEXTCLOUD_DATADIR}
NCDATA_STORAGE=${NCDATA_STORAGE}
APACHE_PORT=${AIO_APACHE_PORT}
APACHE_IP_BINDING=0.0.0.0
SKIP_DOMAIN_VALIDATION=${SKIP_VAL_STR}

# NPM host IP for trusted_proxies — used by: nextcloud-aio-maint.sh set-trusted-proxies
NPM_HOST_IP=${NPM_HOST_IP}
EOF_ENV

# ── AIO docker-compose.yml ────────────────────────────────────────────────────
# Variables like ${AIO_IMAGE} are Docker Compose substitutions resolved from .env.
# Do not quote the EOF delimiter — host shell must not expand these at write time.
echo "  Writing docker-compose.yml..."
pct exec "$CT_ID" -- bash -lc 'cat > /opt/nextcloud-aio/docker-compose.yml && chmod 0600 /opt/nextcloud-aio/docker-compose.yml' <<'EOF_COMPOSE'
services:
  nextcloud-aio-mastercontainer:
    image: ${AIO_IMAGE:-ghcr.io/nextcloud-releases/all-in-one:latest}
    container_name: nextcloud-aio-mastercontainer
    init: true
    restart: always
    ports:
      - "8080:8080"
    environment:
      APACHE_PORT: ${APACHE_PORT:-11000}
      APACHE_IP_BINDING: ${APACHE_IP_BINDING:-0.0.0.0}
      SKIP_DOMAIN_VALIDATION: ${SKIP_DOMAIN_VALIDATION:-false}
      NEXTCLOUD_DATADIR: ${NEXTCLOUD_DATADIR:-/opt/nextcloud-aio/data}
    volumes:
      - nextcloud_aio_mastercontainer:/mnt/docker-aio-config
      - /var/run/docker.sock:/var/run/docker.sock:ro
    network_mode: bridge # Matches upstream compose.yaml — places container on the default bridge, same as docker run.

volumes:
  nextcloud_aio_mastercontainer:
    name: nextcloud_aio_mastercontainer
EOF_COMPOSE

# ── Systemd service for AIO stack ─────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/nextcloud-aio.service <<EOF
[Unit]
Description=Nextcloud AIO (Docker)
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/nextcloud-aio
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
StandardOutput=journal
StandardError=journal
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable nextcloud-aio
'

# ── Start AIO stack ───────────────────────────────────────────────────────────
echo "  Pulling and starting Nextcloud AIO mastercontainer..."
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cd /opt/nextcloud-aio
  docker compose pull
  docker compose up -d
'

# ── Verification ──────────────────────────────────────────────────────────────
# AIO admin UI uses HTTPS with a self-signed cert; -sk skips cert verification.
echo "  Waiting for AIO admin UI (https://localhost:8080)..."
AIO_HEALTHY=0
for i in $(seq 1 36); do
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc \
    "curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8080/ 2>/dev/null" \
    2>/dev/null || echo "000")"
  if [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]]; then
    AIO_HEALTHY=1
    break
  fi
  sleep 5
done

if [[ "$AIO_HEALTHY" -eq 1 ]]; then
  echo "  AIO admin UI health check passed (port 8080 — HTTP ${HTTP_CODE})"
else
  echo "  WARNING: AIO admin UI not responding on port 8080 after 3 minutes" >&2
  echo "  Check: pct exec $CT_ID -- docker logs nextcloud-aio-mastercontainer" >&2
  echo "  Check: pct exec $CT_ID -- docker ps -a" >&2
fi

# ── Maintenance helper ────────────────────────────────────────────────────────
echo "  Installing maintenance helper..."
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/nextcloud-aio-maint.sh && chmod 0755 /usr/local/bin/nextcloud-aio-maint.sh' <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR="/opt/nextcloud-aio"
ENV_FILE="${APP_DIR}/.env"

# Load runtime configuration
# shellcheck source=/dev/null
[[ -f "$ENV_FILE" ]] && . "$ENV_FILE"

cmd="${1:-}"
case "$cmd" in

  check)
    # Runs diagnostic checks on Collabora/Nextcloud Office configuration.
    echo "  Checking Collabora configuration..."
    docker exec --user www-data nextcloud-aio-nextcloud \
      php occ richdocuments:setup
    ;;

  repair)
    # Runs the full maintenance repair including expensive checks.
    # Use this to clear warnings shown in Nextcloud Admin > Overview.
    echo "  Running maintenance:repair --include-expensive..."
    docker exec --user www-data nextcloud-aio-nextcloud \
      php occ maintenance:repair --include-expensive
    echo "  Done."
    ;;

  configure)
    # Run this AFTER the AIO wizard has fully completed and Nextcloud is up.
    # Sets files as the default app, disables the first-run welcome screen,
    # sets the default phone region, sets overwriteprotocol for HTTPS callbacks,
    # and configures the Collabora WOPI allowlist for Cloudflare IP ranges.
    echo "  Disabling skeleton files for new users..."
    docker exec --user www-data nextcloud-aio-nextcloud \
      php occ config:system:set skeletondirectory --value=""
    echo "  Disabling Deck..."
    docker exec --user www-data nextcloud-aio-nextcloud \
      php occ app:disable deck 2>/dev/null || true
    echo "  Disabling Talk..."
    docker exec --user www-data nextcloud-aio-nextcloud \
      php occ app:disable spreed 2>/dev/null || true
    echo "  Disabling Tasks..."
    docker exec --user www-data nextcloud-aio-nextcloud \
      php occ app:disable tasks 2>/dev/null || true
    echo "  Disabling Nextcloud announcements splash..."
    docker exec --user www-data nextcloud-aio-nextcloud \
      php occ app:disable nextcloud_announcements 2>/dev/null || true
    echo "  Disabling dashboard..."
    docker exec --user www-data nextcloud-aio-nextcloud \
      php occ app:disable dashboard 2>/dev/null || true
    echo "  Disabling first-run wizard..."
    docker exec --user www-data nextcloud-aio-nextcloud \
      php occ app:disable firstrunwizard 2>/dev/null || true
    echo "  Disabling recommendations..."
    docker exec --user www-data nextcloud-aio-nextcloud \
      php occ app:disable recommendations 2>/dev/null || true
    echo "  Setting default app to files..."
    docker exec --user www-data nextcloud-aio-nextcloud \
      php occ config:system:set defaultapp --value=files
    echo "  Setting default phone region to DE..."
    docker exec --user www-data nextcloud-aio-nextcloud \
      php occ config:system:set default_phone_region --value=DE
    echo "  Setting overwriteprotocol to https (required behind reverse proxy)..."
    docker exec --user www-data nextcloud-aio-nextcloud \
      php occ config:system:set overwriteprotocol --value=https
    echo "  Allowing local remote servers (required for Collabora internal callbacks)..."
    docker exec --user www-data nextcloud-aio-nextcloud \
      php occ config:system:set allow_local_remote_servers --value=true --type=boolean
    echo "  Fetching current Cloudflare IP ranges..."
    CF_IPS_V4="$(curl -fsSL https://www.cloudflare.com/ips-v4/ 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
    CF_IPS_V6="$(curl -fsSL https://www.cloudflare.com/ips-v6/ 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
    [[ -n "$CF_IPS_V4" ]] || { echo "  ERROR: Failed to fetch Cloudflare IPv4 ranges." >&2; exit 1; }
    [[ -n "$CF_IPS_V6" ]] || { echo "  ERROR: Failed to fetch Cloudflare IPv6 ranges." >&2; exit 1; }
    WOPI_ALLOWLIST="172.16.0.0/12,${CF_IPS_V4},${CF_IPS_V6}"
    echo "  Setting Collabora WOPI allowlist (Docker network + current Cloudflare IP ranges)..."
    docker exec --user www-data nextcloud-aio-nextcloud \
      php occ config:app:set richdocuments wopi_allowlist --value="${WOPI_ALLOWLIST}"
    echo "  Restarting Nextcloud container to apply config changes..."
    docker restart nextcloud-aio-nextcloud
    echo "  Waiting for Nextcloud to come back up..."
    sleep 30
    if [[ -n "${NPM_HOST_IP:-}" ]]; then
      echo "  Setting trusted_proxies to: ${NPM_HOST_IP}..."
      docker exec --user www-data nextcloud-aio-nextcloud \
        php occ config:system:set trusted_proxies 2 --value="${NPM_HOST_IP}"
    else
      echo "  NPM_HOST_IP not set — skipping trusted_proxies."
      echo "  Run: nextcloud-aio-maint.sh set-trusted-proxies <NPM_HOST_IP>"
    fi
    echo "  Running maintenance:repair --include-expensive..."
    docker exec --user www-data nextcloud-aio-nextcloud \
      php occ maintenance:repair --include-expensive
    echo "  Done."
    ;;

  set-trusted-proxies)
    # Run this AFTER the initial AIO setup is complete (Nextcloud must be fully installed).
    # Adds the NPM host IP to Nextcloud's trusted_proxies list so X-Forwarded-For headers
    # are accepted when NPM sits on a different host from the Nextcloud LXC.
    PROXY_IP="${2:-${NPM_HOST_IP:-}}"
    [[ -n "$PROXY_IP" ]] || {
      echo "  ERROR: Provide NPM host IP as argument or set NPM_HOST_IP in ${ENV_FILE}" >&2
      echo "  Usage: $0 set-trusted-proxies <NPM_HOST_IP>" >&2
      exit 1
    }
    echo "  Setting trusted_proxies[2] to: ${PROXY_IP}"
    docker exec --user www-data nextcloud-aio-nextcloud \
      php occ config:system:set trusted_proxies 2 --value="${PROXY_IP}"
    echo "  Done. Verify in Nextcloud Admin > Overview > Security & setup warnings."
    ;;

  status)
    echo "  AIO containers:"
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' \
      | grep -i nextcloud || echo "  No AIO containers running."
    ;;

  update)
    # The full Nextcloud stack (apps, databases, etc.) is updated via the AIO
    # admin UI — do not attempt to update those containers manually. This command
    # only pulls a new mastercontainer image when AIO_TAG is changed in .env.
    echo "  Pulling mastercontainer image (${AIO_IMAGE:-ghcr.io/nextcloud-releases/all-in-one:latest})..."
    cd "$APP_DIR"
    docker compose pull
    docker compose up -d --remove-orphans
    echo "  Mastercontainer updated."
    echo "  To update the full Nextcloud stack (apps, DB, etc.), use the AIO admin UI:"
    SELF_IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    echo "    https://${SELF_IP:-<LXC_IP>}:8080"
    ;;

  logs)
    docker logs nextcloud-aio-mastercontainer "${@:2}"
    ;;

  files-scan)
    # Rebuilds the Nextcloud file index from the contents of NEXTCLOUD_DATADIR.
    # Use after attaching an existing data directory to a new instance.
    # Prerequisite: re-create all user accounts with identical usernames first,
    # otherwise files cannot be reattached to their owners.
    # Nextcloud must be fully up (AIO wizard complete, all containers running).
    _scan_target="${2:---all}"
    # Safety trap: ensure maintenance mode is always disabled on exit or error,
    # so a failed scan does not leave the instance permanently inaccessible.
    trap 'echo "  Disabling maintenance mode (cleanup after failure)..." >&2
          docker exec --user www-data nextcloud-aio-nextcloud \
            php occ maintenance:mode --off 2>/dev/null || true' ERR EXIT
    echo "  Enabling maintenance mode..."
    docker exec --user www-data nextcloud-aio-nextcloud \
      php occ maintenance:mode --on
    echo "  Scanning files (${_scan_target})..."
    docker exec --user www-data nextcloud-aio-nextcloud \
      php occ files:scan "${_scan_target}"
    echo "  Cleaning up orphaned file cache entries..."
    docker exec --user www-data nextcloud-aio-nextcloud \
      php occ files:cleanup
    echo "  Disabling maintenance mode..."
    docker exec --user www-data nextcloud-aio-nextcloud \
      php occ maintenance:mode --off
    trap - ERR EXIT
    echo "  Done. Verify files in the Nextcloud web UI."
    ;;

  ''|-h|--help)
    cat <<USAGE
  Usage: $0 <command> [args]

  Commands:
    check                          Check Collabora configuration and connectivity
    repair                         Run maintenance:repair --include-expensive
    configure                      Post-install configuration (run once after AIO wizard)
    set-trusted-proxies [IP]       Add NPM host as a trusted proxy in Nextcloud
    status                         Show running AIO containers
    update                         Pull updated mastercontainer image
    logs [--tail=N ...]            Show mastercontainer logs
    files-scan [--all | <user>]    Rebuild file index from data dir (recovery use)

  Note: Full Nextcloud stack updates are done via the AIO admin UI.
  Note: Container and data backups are handled by Proxmox Backup Server (PBS).
USAGE
    ;;

  *)
    echo "  ERROR: Unknown command: $cmd" >&2
    exit 1
    ;;
esac
MAINT

# ── Unattended upgrades (OS packages — not Docker images) ─────────────────────
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
Unattended-Upgrade::Package-Blacklist {};
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

# ── Extra packages ────────────────────────────────────────────────────────────
if [[ "${#EXTRA_PACKAGES[@]}" -gt 0 ]]; then
  pct exec "$CT_ID" -- bash -lc "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y ${EXTRA_PACKAGES[*]}
  "
fi

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
  apt-get clean
'

# ── MOTD (dynamic drop-ins) ───────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  > /etc/motd
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
  rm -f /etc/update-motd.d/*
'

pct exec "$CT_ID" -- bash -lc 'cat > /etc/update-motd.d/00-header && chmod +x /etc/update-motd.d/00-header' <<'MOTD'
#!/bin/sh
printf '\n  Nextcloud AIO (Docker)\n'
printf '  ────────────────────────────────────\n'
MOTD

pct exec "$CT_ID" -- bash -lc 'cat > /etc/update-motd.d/10-sysinfo && chmod +x /etc/update-motd.d/10-sysinfo' <<'MOTD'
#!/bin/sh
ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
printf '  Hostname:  %s\n' "$(hostname)"
printf '  IP:        %s\n' "${ip:-n/a}"
printf '  Uptime:    %s\n' "$(uptime -p 2>/dev/null || uptime)"
printf '  Disk:      %s\n' "$(df -h / | awk 'NR==2{printf "%s/%s (%s used)", $3, $2, $5}')"
MOTD

pct exec "$CT_ID" -- bash -lc 'cat > /etc/update-motd.d/30-app && chmod +x /etc/update-motd.d/30-app' <<'MOTD'
#!/bin/sh
ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c nextcloud || echo 0)
ncdata_dir=$(awk -F= '/^NEXTCLOUD_DATADIR=/{print $2}' /opt/nextcloud-aio/.env 2>/dev/null | tail -n1)
ncdata_storage=$(awk -F= '/^NCDATA_STORAGE=/{print $2}' /opt/nextcloud-aio/.env 2>/dev/null | tail -n1)
ncdata_disk=$(df -h "${ncdata_dir:-/opt/nextcloud-aio/data}" 2>/dev/null | awk 'NR==2{printf "%s/%s (%s used)", $3, $2, $5}')
printf '\n'
printf '  Nextcloud AIO:\n'
printf '    App dir:     /opt/nextcloud-aio\n'
printf '    Data dir:    %s\n' "${ncdata_dir:-n/a}"
printf '    Storage:     %s\n' "${ncdata_storage:-rootfs}"
printf '    Data disk:   %s\n' "${ncdata_disk:-n/a}"
printf '    Containers:  %s nextcloud container(s) running\n' "$running"
printf '    Admin UI:    https://%s:8080\n' "${ip:-<IP>}"
printf '    Backend:     http://%s:11000  (NPM forward target)\n' "${ip:-<IP>}"
printf '\n'
printf '  Maintenance:\n'
printf '    nextcloud-aio-maint.sh configure\n'
printf '    nextcloud-aio-maint.sh check\n'
printf '    nextcloud-aio-maint.sh status\n'
MOTD

pct exec "$CT_ID" -- bash -lc 'cat > /etc/update-motd.d/99-footer && chmod +x /etc/update-motd.d/99-footer' <<'MOTD'
#!/bin/sh
printf '  ────────────────────────────────────\n\n'
MOTD

# ── Proxmox UI description ────────────────────────────────────────────────────
AIO_DESC="<a href='https://${CT_IP}:8080/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>AIO Admin</a>
<details><summary>Details</summary>Nextcloud AIO (Docker) on Debian ${DEBIAN_VERSION} LXC
Apache backend port: ${AIO_APACHE_PORT}
Data dir: ${NEXTCLOUD_DATADIR}
Created by nextcloud-aio-docker.sh</details>"
pct set "$CT_ID" --description "$AIO_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── TERM fix ──────────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  CT: $CT_ID | IP: ${CT_IP} | Login: password set"
echo ""
echo "  Data storage: ${NCDATA_STORAGE}"
echo "  Data dir:     ${NEXTCLOUD_DATADIR}"
if [[ "$NCDATA_EXISTING" -eq 1 ]]; then
  echo ""
  echo "  !! Existing data was attached. After AIO setup and user re-creation, run:"
  echo "       pct exec $CT_ID -- /usr/local/bin/nextcloud-aio-maint.sh files-scan --all"
fi
echo ""
echo "  ── Next steps (required — manual) ──────────────────────────────────────"
echo ""
echo "  1. Open AIO admin UI using the LXC IP (not the public domain):"
echo "       https://${CT_IP}:8080"
echo ""
echo "  2. Enter your public domain (e.g. cloud.example.com) and complete"
echo "     setup. AIO will pull and start all service containers."
echo ""
echo "     SKIP_DOMAIN_VALIDATION is enabled, which is correct for Cloudflare"
echo "     Tunnel deployments. AIO's domain validation does not work behind"
echo "     Cloudflare Tunnel — this matches the official AIO guidance."
echo ""
echo "  3. In Nginx Proxy Manager, create a Proxy Host:"
echo "       Domain:   cloud.example.com"
echo "       Scheme:   http"
echo "       Forward:  ${CT_IP}:${AIO_APACHE_PORT}"
echo "       WebSockets Support: on"
echo "     Advanced:"
echo "       proxy_set_header Upgrade \$http_upgrade;"
echo "       proxy_set_header Connection \"upgrade\";"
echo "       client_body_buffer_size 512k;"
echo "       proxy_read_timeout 86400s;"
echo "       client_max_body_size 0;"
echo ""
if [[ -n "$NPM_HOST_IP" ]]; then
  echo "  4. trusted_proxies will be set to ${NPM_HOST_IP} automatically by the configure command in step 5."
else
  echo "  4. NPM_HOST_IP was not set. After step 5, run:"
  echo "       pct exec $CT_ID -- /usr/local/bin/nextcloud-aio-maint.sh set-trusted-proxies <NPM_HOST_IP>"
fi
echo ""
echo "  5. Once Nextcloud is fully up, run the post-install configuration:"
echo "       pct exec $CT_ID -- /usr/local/bin/nextcloud-aio-maint.sh configure"
echo "     This sets the default app, phone region, overwriteprotocol, Collabora"
echo "     WOPI allowlist, local server trust, and runs maintenance repair."
echo ""
echo "  ── Local LAN access ─────────────────────────────────────────────────────"
echo ""
echo "    Cloudflare Tunnel alone does not provide LAN access to Nextcloud."
echo "    To reach cloud.example.com from inside your network:"
echo "      - NPM must serve cloud.example.com locally on HTTPS/443 with TLS"
echo "      - Your local DNS must resolve cloud.example.com → NPM private IP"
echo "    Without split DNS + local TLS on NPM:443, LAN access is not possible."
echo ""
echo "  ── Cloudflare Tunnel — known operational caveats ────────────────────────"
echo ""
echo "    - Domain validation: SKIP_DOMAIN_VALIDATION is already enabled,"
echo "      which is the correct setting for Cloudflare Tunnel deployments."
echo ""
echo "    - Rocket Loader: disable it in Cloudflare for cloud.example.com."
echo "      It breaks Nextcloud's JavaScript. (Speed > Optimization > Rocket Loader)"
echo ""
echo "    - Upload timeouts: Cloudflare enforces a 100-second request timeout."
echo "      Large file uploads may time out or fail depending on chunking behavior."
echo ""
echo "    - Nextcloud Office / Collabora: Cloudflare IP ranges are added to the"
echo "      WOPI allowlist automatically by the configure command. If you see"
echo "      WOPI errors, re-run configure to refresh the list."
echo "      See: https://www.cloudflare.com/ips/"
echo ""
echo "  ── Maintenance ──────────────────────────────────────────────────────────"
echo ""
echo "    pct exec $CT_ID -- /usr/local/bin/nextcloud-aio-maint.sh check"
echo "    pct exec $CT_ID -- /usr/local/bin/nextcloud-aio-maint.sh configure"
echo "    pct exec $CT_ID -- /usr/local/bin/nextcloud-aio-maint.sh set-trusted-proxies <NPM_HOST_IP>"
echo "    pct exec $CT_ID -- /usr/local/bin/nextcloud-aio-maint.sh status"
echo "    pct exec $CT_ID -- /usr/local/bin/nextcloud-aio-maint.sh logs [--tail=50]"
echo "    pct exec $CT_ID -- /usr/local/bin/nextcloud-aio-maint.sh files-scan [--all | <username>]"
echo "      (recovery: rebuilds file index after attaching existing NEXTCLOUD_DATADIR to a new instance)"
echo ""
echo "  To update Nextcloud, log in at https://cloud.example.com"
echo "  then go to: Avatar → Administration settings → Nextcloud AIO"
echo ""
echo "  Done."
