#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID="$(pvesh get /cluster/nextid)"
HN="kavita-books"
CPU=2
RAM=2048
DISK=16
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"
BOOKS_STORAGE="rootfs"              # rootfs | /host/path | <zfs-pool-name>

# Kavita + Filebrowser / Podman
KAVITA_PORT=5000
FB_PORT=8080
APP_TZ="Europe/Berlin"
PUBLIC_FQDN=""                      # e.g. books.example.com ; blank = local IP mode
TAGS="kavita;filebrowser;podman;lxc"

# Images / versions
# jvmilazz0/kavita publishes exactly two tag families:
#   latest       — current stable release  (the only pinnable stable tag)
#   nightly-*    — nightly builds (e.g. nightly-0.8.9.1)
# There are no bare version tags (0.8.9.1 does NOT exist on this registry).
# Use "latest" for stable or a specific "nightly-X.Y.Z" tag for nightlies.
# The actual running digest is recorded in .env at install time for auditability.
# Config path inside the container is /kavita/config and must not be changed.
KAVITA_IMAGE_REPO="docker.io/jvmilazz0/kavita"
KAVITA_TAG="latest"
KAVITA_IMAGE="${KAVITA_IMAGE_REPO}:${KAVITA_TAG}"
# Filebrowser — fully qualified repo per Podman convention
# Default process user inside the container is UID 1000:GID 1000
FB_IMAGE_REPO="docker.io/filebrowser/filebrowser"
FB_TAG="v2.31.2"
FB_IMAGE="${FB_IMAGE_REPO}:${FB_TAG}"
DEBIAN_VERSION=13

# Shared media group
# Neither container supports PUID/PGID remapping, so a shared supplemental
# group is used instead. Both compose services get group_add: ["MEDIA_GID"]
# and books/ is owned KAVITA_UID:MEDIA_GID with SGID 2775.
# This gives both apps write access regardless of their internal UIDs.
MEDIA_GID=2000

# Optional features
AUTO_UPDATE=0                        # 1 = enable timer-driven maintenance/update runs
TRACK_LATEST=1                       # jvmilazz0/kavita only publishes latest/nightly-*; no pinned stable tags exist
KEEP_BACKUPS=7

# Behavior
CLEANUP_ON_FAIL=1

# Derived
APP_DIR="/opt/kavita-books"
BACKUP_DIR="/opt/kavita-books-backups"
APP_URL=""
[[ -n "$PUBLIC_FQDN" ]] && APP_URL="https://${PUBLIC_FQDN}"

# ── Custom configs created by this script ─────────────────────────────────────
#   /opt/kavita-books/docker-compose.yml              (Podman compose stack)
#   /opt/kavita-books/.env                            (runtime configuration)
#   /opt/kavita-books/kavita-config/                  (Kavita app config — mounted at /kavita/config)
#   /opt/kavita-books/filebrowser/filebrowser.db      (Filebrowser database)
#   /opt/kavita-books/filebrowser/settings.json       (Filebrowser config file)
#   /opt/kavita-books/books/                          (shared books dir; mediagroup SGID 2775)
#   /opt/kavita-books-backups/                        (compressed config backups)
#   /usr/local/bin/kavita-books-maint.sh              (maintenance helper)
#   /etc/systemd/system/kavita-books-stack.service
#   /etc/systemd/system/kavita-books-update.service
#   /etc/systemd/system/kavita-books-update.timer
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/sysctl.d/99-hardening.conf

# ── Config validation ─────────────────────────────────────────────────────────
[[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }
[[ "$KAVITA_PORT" =~ ^[0-9]+$ ]] || { echo "  ERROR: KAVITA_PORT must be numeric." >&2; exit 1; }
(( KAVITA_PORT >= 1 && KAVITA_PORT <= 65535 )) || { echo "  ERROR: KAVITA_PORT must be between 1 and 65535." >&2; exit 1; }
[[ "$FB_PORT" =~ ^[0-9]+$ ]] || { echo "  ERROR: FB_PORT must be numeric." >&2; exit 1; }
(( FB_PORT >= 1 && FB_PORT <= 65535 )) || { echo "  ERROR: FB_PORT must be between 1 and 65535." >&2; exit 1; }
[[ "$KAVITA_PORT" -ne "$FB_PORT" ]] || { echo "  ERROR: KAVITA_PORT and FB_PORT must be different." >&2; exit 1; }
[[ "$MEDIA_GID" =~ ^[0-9]+$ ]] || { echo "  ERROR: MEDIA_GID must be numeric." >&2; exit 1; }
[[ "$KEEP_BACKUPS" =~ ^[0-9]+$ ]] || { echo "  ERROR: KEEP_BACKUPS must be numeric." >&2; exit 1; }
[[ -n "$KAVITA_IMAGE_REPO" && ! "$KAVITA_IMAGE_REPO" =~ [[:space:]] ]] || { echo "  ERROR: KAVITA_IMAGE_REPO must be non-empty and contain no spaces." >&2; exit 1; }
[[ -n "$KAVITA_TAG" && "$KAVITA_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "  ERROR: KAVITA_TAG must contain only tag-safe characters." >&2; exit 1; }
[[ -n "$FB_IMAGE_REPO" && ! "$FB_IMAGE_REPO" =~ [[:space:]] ]] || { echo "  ERROR: FB_IMAGE_REPO must be non-empty and contain no spaces." >&2; exit 1; }
[[ -n "$FB_TAG" && "$FB_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "  ERROR: FB_TAG must contain only tag-safe characters." >&2; exit 1; }
[[ "$AUTO_UPDATE" =~ ^[01]$ ]] || { echo "  ERROR: AUTO_UPDATE must be 0 or 1." >&2; exit 1; }
[[ "$TRACK_LATEST" =~ ^[01]$ ]] || { echo "  ERROR: TRACK_LATEST must be 0 or 1." >&2; exit 1; }
# jvmilazz0/kavita only publishes latest and nightly-* — KAVITA_TAG=latest is always valid.
# FB_TAG=latest requires TRACK_LATEST=1 since filebrowser does publish pinned tags.
if [[ "$TRACK_LATEST" -eq 0 && "$FB_TAG" == "latest" ]]; then
  echo "  ERROR: FB_TAG must be a concrete tag when TRACK_LATEST=0 (filebrowser publishes pinned tags)." >&2
  exit 1
fi
if [[ -n "$PUBLIC_FQDN" && ! "$PUBLIC_FQDN" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "  ERROR: PUBLIC_FQDN contains invalid characters: $PUBLIC_FQDN" >&2
  exit 1
fi
if [[ "$BOOKS_STORAGE" != "rootfs" && "$BOOKS_STORAGE" != /* && ! "$BOOKS_STORAGE" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
  echo "  ERROR: BOOKS_STORAGE must be rootfs, an absolute host path, or a ZFS pool name." >&2
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

for cmd in pvesh pveam pct pvesm curl python3 ip awk sort paste; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

if [[ "$BOOKS_STORAGE" != "rootfs" && "$BOOKS_STORAGE" != /* ]]; then
  command -v zfs >/dev/null 2>&1 || { echo "  ERROR: zfs command is required when BOOKS_STORAGE is a ZFS pool name." >&2; exit 1; }
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

  Kavita + Filebrowser (Podman) LXC Creator — Configuration
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
  Kavita image:      $KAVITA_IMAGE
  Kavita port:       $KAVITA_PORT
  Filebrowser image: $FB_IMAGE
  Filebrowser port:  $FB_PORT
  Media GID:         $MEDIA_GID  (shared supplemental group for books/ access)
  Books storage:     $BOOKS_STORAGE (available ZFS pools: $AVAIL_ZFS_POOLS)
  Public FQDN:       ${PUBLIC_FQDN:-"(not set — local IP mode)"}
  Timezone:          $APP_TZ
  Tags:              $TAGS
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled" || echo "disabled")
  Track latest:      $([ "$TRACK_LATEST" -eq 1 ] && echo "enabled" || echo "disabled")
  Keep backups:      $KEEP_BACKUPS
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/kavita-books-podman.sh"
SCRIPT_LOCAL="/root/kavita-books-podman.sh"
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

# ── Books storage — host dir or ZFS dataset + LXC mount point ────────────────
# Pre-start: directories are owned by CT root (100000 on host for unprivileged CTs).
# Post-pull: once the Kavita UID is known, books/ is re-chowned inside the CT
# to KAVITA_UID:MEDIA_GID with SGID 2775 — that mapping is reflected on the host.
if [[ "$BOOKS_STORAGE" == "rootfs" ]]; then
  echo "  WARNING: No external books storage configured — uploads will use rootfs (${DISK} GB)." >&2
  pct mount "$CT_ID"
  mkdir -p \
    "/var/lib/lxc/${CT_ID}/rootfs/opt/kavita-books" \
    "/var/lib/lxc/${CT_ID}/rootfs/opt/kavita-books/books"
  # CT root (100000) owns both; final ownership is fixed post-pull inside the CT
  chown 100000:100000 \
    "/var/lib/lxc/${CT_ID}/rootfs/opt/kavita-books" \
    "/var/lib/lxc/${CT_ID}/rootfs/opt/kavita-books/books"
  pct unmount "$CT_ID"
elif [[ "$BOOKS_STORAGE" == /* ]]; then
  mkdir -p "$BOOKS_STORAGE"
  chown 100000:100000 "$BOOKS_STORAGE"
  pct mount "$CT_ID"
  mkdir -p "/var/lib/lxc/${CT_ID}/rootfs/opt/kavita-books"
  chown 100000:100000 "/var/lib/lxc/${CT_ID}/rootfs/opt/kavita-books"
  pct unmount "$CT_ID"
  pct set "$CT_ID" --mp0 "${BOOKS_STORAGE},mp=/opt/kavita-books/books"
  echo "  Books mount: ${BOOKS_STORAGE} -> /opt/kavita-books/books (CT ${CT_ID})"
else
  BOOKS_DATASET="${BOOKS_STORAGE}/kavita-books"
  BOOKS_HOST_PATH="$(zfs get -H -o value mountpoint "${BOOKS_DATASET}" 2>/dev/null || true)"
  if [[ -z "$BOOKS_HOST_PATH" || "$BOOKS_HOST_PATH" == "-" ]]; then
    echo "  Creating ZFS dataset: ${BOOKS_DATASET}"
    zfs create -o compression=lz4 "${BOOKS_DATASET}"
    BOOKS_HOST_PATH="$(zfs get -H -o value mountpoint "${BOOKS_DATASET}")"
  else
    echo "  ZFS dataset already exists: ${BOOKS_DATASET} -> ${BOOKS_HOST_PATH}"
  fi
  chown 100000:100000 "$BOOKS_HOST_PATH"
  pct mount "$CT_ID"
  mkdir -p "/var/lib/lxc/${CT_ID}/rootfs/opt/kavita-books"
  chown 100000:100000 "/var/lib/lxc/${CT_ID}/rootfs/opt/kavita-books"
  pct unmount "$CT_ID"
  pct set "$CT_ID" --mp0 "${BOOKS_HOST_PATH},mp=/opt/kavita-books/books"
  echo "  Books mount: ${BOOKS_HOST_PATH} -> /opt/kavita-books/books (CT ${CT_ID})"
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
  APP_URL="http://${CT_IP}:${KAVITA_PORT}"
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

# ── Pull images ───────────────────────────────────────────────────────────────
echo "  Pulling images ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman pull '${KAVITA_IMAGE}'
  podman pull '${FB_IMAGE}'
"

# Record the resolved digest for auditability.
# jvmilazz0/kavita only has floating tags (latest/nightly-*) — the digest is
# the only way to know exactly which build is running.
KAVITA_DIGEST="$(pct exec "$CT_ID" -- bash -lc \
  "podman inspect --format '{{index .RepoDigests 0}}' '${KAVITA_IMAGE}' 2>/dev/null | head -n1" \
  2>/dev/null | tr -d '\r' || echo "unknown")"
FB_DIGEST="$(pct exec "$CT_ID" -- bash -lc \
  "podman inspect --format '{{index .RepoDigests 0}}' '${FB_IMAGE}' 2>/dev/null | head -n1" \
  2>/dev/null | tr -d '\r' || echo "unknown")"
echo "  Kavita digest: ${KAVITA_DIGEST}"
echo "  FB digest:     ${FB_DIGEST}"

# ── Detect container UIDs/GIDs for bind-mount ownership ──────────────────────
# The official jvmilazz0/kavita image does not support PUID/PGID remapping.
# We detect its real internal UID so bind-mount ownership is always correct,
# even if a future image release changes the process user.
KAVITA_UID="$(pct exec "$CT_ID" -- bash -lc "podman run --rm --entrypoint sh '${KAVITA_IMAGE}' -lc 'id -u'" 2>/dev/null | tr -d '\r')"
KAVITA_GID="$(pct exec "$CT_ID" -- bash -lc "podman run --rm --entrypoint sh '${KAVITA_IMAGE}' -lc 'id -g'" 2>/dev/null | tr -d '\r')"
# Filebrowser documents its default process user as 1000:1000 — verify rather than assume
FB_UID="$(pct exec "$CT_ID" -- bash -lc "podman run --rm --entrypoint sh '${FB_IMAGE}' -lc 'id -u'" 2>/dev/null | tr -d '\r')"
FB_GID="$(pct exec "$CT_ID" -- bash -lc "podman run --rm --entrypoint sh '${FB_IMAGE}' -lc 'id -g'" 2>/dev/null | tr -d '\r')"

for v in KAVITA_UID KAVITA_GID FB_UID FB_GID; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "  ERROR: Failed to detect numeric $v from container images." >&2; exit 1; }
done

echo "  Detected UIDs — kavita=${KAVITA_UID}:${KAVITA_GID}  filebrowser=${FB_UID}:${FB_GID}"

# ── Prepare persistent paths ──────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  install -d -m 0755 '${BACKUP_DIR}'
  install -d -m 0750 '${APP_DIR}/kavita-config'
  install -d -m 0750 '${APP_DIR}/filebrowser'
  chown ${KAVITA_UID}:${KAVITA_GID} '${APP_DIR}/kavita-config'
  chown ${FB_UID}:${FB_GID}         '${APP_DIR}/filebrowser'

  # Create the shared media group inside the CT.
  # Both compose services get group_add: [\"${MEDIA_GID}\"] so their processes
  # acquire this GID as a supplemental group and can write to books/.
  groupadd --gid ${MEDIA_GID} mediagroup 2>/dev/null || true

  # Set books/ to KAVITA_UID:MEDIA_GID with SGID 2775.
  # SGID ensures every new file written by either container inherits mediagroup,
  # so there are no future ownership conflicts.
  chown ${KAVITA_UID}:${MEDIA_GID} '${APP_DIR}/books'
  chmod 2775                        '${APP_DIR}/books'
"

# ── Recursive ownership fix for pre-populated external libraries ──────────────
# The chown/chmod above only touches the mount root.  If BOOKS_STORAGE points
# at an existing library, deeper files may have mismatched ownership, causing
# inconsistent write/upload behaviour even when read access works fine.
# This block detects a non-empty external tree and offers a recursive repair.
# It runs on the Proxmox host because BOOKS_HOST_PATH is a host-side path and
# the unprivileged UID mapping (host UID = 100000 + container UID) applies here.
_books_host_path=""
if [[ "$BOOKS_STORAGE" == /* ]]; then
  _books_host_path="$BOOKS_STORAGE"
elif [[ "$BOOKS_STORAGE" != "rootfs" ]]; then
  _books_host_path="${BOOKS_HOST_PATH:-}"
fi

if [[ -n "$_books_host_path" && -d "$_books_host_path" ]]; then
  _file_count="$(find "$_books_host_path" -mindepth 1 -maxdepth 3 2>/dev/null | wc -l || echo 0)"
  if (( _file_count > 0 )); then
    # Map container UID/GID to their host equivalents for an unprivileged CT
    # (Proxmox default id-map: container 0 -> host 100000, so UID N -> 100000+N)
    _host_kavita_uid=$(( 100000 + KAVITA_UID ))
    _host_media_gid=$(( 100000 + MEDIA_GID ))
    echo ""
    echo "  ── Existing books library detected ────────────────────────────"
    echo "  Path:       ${_books_host_path}"
    echo "  Items:      ${_file_count} (up to depth 3; actual count may be higher)"
    echo "  Will apply: chown -R ${_host_kavita_uid}:${_host_media_gid}  (host UIDs)"
    echo "              find    dirs  -> chmod 2775"
    echo "              find    files -> chmod 664"
    echo "  This ensures both Kavita and Filebrowser can read and write all"
    echo "  existing files.  Skip if your permissions are already correct."
    echo "  ───────────────────────────────────────────────────────────────"
    echo ""
    read -r -p "  Fix ownership/permissions recursively? [y/N]: " _fix_response
    case "$_fix_response" in
      [yY][eE][sS]|[yY])
        echo "  Applying recursive ownership fix (this may take a moment) ..."
        chown -R "${_host_kavita_uid}:${_host_media_gid}" "$_books_host_path"
        find "$_books_host_path" -type d -exec chmod 2775 {} +
        find "$_books_host_path" -type f -exec chmod 664 {} +
        echo "  Done."
        ;;
      *)
        echo "  Skipped. If uploads or edits fail, run manually on the Proxmox host:"
        echo "    chown -R ${_host_kavita_uid}:${_host_media_gid} ${_books_host_path}"
        echo "    find ${_books_host_path} -type d -exec chmod 2775 {} +"
        echo "    find ${_books_host_path} -type f -exec chmod 664 {} +"
        ;;
    esac
    echo ""
  fi
fi

# ── Resume persistent paths (FB seeds) ───────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  touch '${APP_DIR}/filebrowser/filebrowser.db'
  cat > '${APP_DIR}/filebrowser/settings.json' <<'FBJSON'
{
  \"port\": 80,
  \"baseURL\": \"\",
  \"address\": \"\",
  \"log\": \"stdout\",
  \"database\": \"/database/filebrowser.db\",
  \"root\": \"/srv\"
}
FBJSON
  chown ${FB_UID}:${FB_GID} \
    '${APP_DIR}/filebrowser/filebrowser.db' \
    '${APP_DIR}/filebrowser/settings.json'
"

# ── Compose file ──────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "cat > '${APP_DIR}/docker-compose.yml' <<'EOF2'
# ── Kavita + Filebrowser — shared books stack ──────────────────────────────
# Permissions — shared media group approach:
#   Neither image supports PUID/PGID remapping.
#   Both services get group_add: [\"MEDIA_GID\"] so their processes acquire
#   the mediagroup GID as a supplemental group.
#   books/ is owned KAVITA_UID:MEDIA_GID with SGID 2775 — both apps can write.
#   New files created by either container inherit mediagroup (SGID).
#
# Kavita config path is /kavita/config and must not be changed.
# Upload books via Filebrowser (/srv = books/ on host).
# Point Kavita Library at /books in the Kavita admin UI.
#
# Filebrowser persistent state (three required paths):
#   /srv                        — served directory  (= books/)
#   /database/filebrowser.db    — SQLite database   (seeded as empty file)
#   /config/settings.json       — JSON config file  (seeded with defaults)

services:

  kavita:
    image: \${KAVITA_IMAGE}
    container_name: kavita
    restart: unless-stopped
    group_add:
      - \"\${MEDIA_GID}\"
    environment:
      - TZ=\${APP_TZ}
    volumes:
      - /opt/kavita-books/kavita-config:/kavita/config:Z
      - /opt/kavita-books/books:/books:Z
    ports:
      - "\${KAVITA_PORT}:5000"

  filebrowser:
    image: \${FB_IMAGE}
    container_name: filebrowser
    restart: unless-stopped
    group_add:
      - \"\${MEDIA_GID}\"
    environment:
      - TZ=\${APP_TZ}
    volumes:
      - /opt/kavita-books/books:/srv:Z
      - /opt/kavita-books/filebrowser/filebrowser.db:/database/filebrowser.db:Z
      - /opt/kavita-books/filebrowser/settings.json:/config/settings.json:Z
    ports:
      - "\${FB_PORT}:80"
EOF2"

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > '${APP_DIR}/.env' <<EOF2
COMPOSE_PROJECT_NAME=kavita-books
KAVITA_IMAGE_REPO=${KAVITA_IMAGE_REPO}
KAVITA_TAG=${KAVITA_TAG}
KAVITA_IMAGE=${KAVITA_IMAGE}
KAVITA_DIGEST=${KAVITA_DIGEST}
KAVITA_UID=${KAVITA_UID}
KAVITA_GID=${KAVITA_GID}
FB_IMAGE_REPO=${FB_IMAGE_REPO}
FB_TAG=${FB_TAG}
FB_IMAGE=${FB_IMAGE}
FB_DIGEST=${FB_DIGEST}
FB_UID=${FB_UID}
FB_GID=${FB_GID}
MEDIA_GID=${MEDIA_GID}
KAVITA_PORT=${KAVITA_PORT}
FB_PORT=${FB_PORT}
APP_TZ=${APP_TZ}
PUBLIC_FQDN=${PUBLIC_FQDN}
APP_URL=${APP_URL}
KEEP_BACKUPS=${KEEP_BACKUPS}
AUTO_UPDATE=${AUTO_UPDATE}
TRACK_LATEST=${TRACK_LATEST}
EOF2
  chmod 0600 '${APP_DIR}/.env' '${APP_DIR}/docker-compose.yml'
"

# ── Maintenance script ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/kavita-books-maint.sh && chmod 0755 /usr/local/bin/kavita-books-maint.sh' <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR="${APP_DIR:-/opt/kavita-books}"
BACKUP_DIR="${BACKUP_DIR:-/opt/kavita-books-backups}"
SERVICE="kavita-books-stack.service"
ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
KEEP_BACKUPS="${KEEP_BACKUPS:-7}"

need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF2
  Kavita + Filebrowser Maintenance
  ─────────────────────────────────────
  Usage:
    $0 backup
    $0 list
    $0 restore <backup.tar.gz>
    $0 update kavita <tag>
    $0 update filebrowser <tag>
    $0 auto-update
    $0 start-fb
    $0 stop-fb
    $0 fb-status
    $0 version

  Notes:
    - backup stops the stack for a consistent snapshot, then restarts it
    - update backs up first, then re-pulls and recreates only that container
    - auto-update obeys AUTO_UPDATE and TRACK_LATEST from ${ENV_FILE}
    - books/ (media) is excluded from script-level backup; use PBS or external tool
    - Backup scope: .env, compose, kavita-config/, filebrowser.db, settings.json
    - start-fb/stop-fb control Filebrowser independently; Kavita is unaffected
    - Filebrowser exposes full write access to books/ — stop it when not in use
EOF2
}

[[ -d "$APP_DIR" ]] || die "APP_DIR not found: $APP_DIR"
[[ -f "$ENV_FILE" ]] || die "Missing env file: $ENV_FILE"
[[ -f "$COMPOSE_FILE" ]] || die "Missing compose file: $COMPOSE_FILE"

env_keep_backups="$(awk -F= '/^KEEP_BACKUPS=/{print $2}' "$ENV_FILE" | tail -n1)"
if [[ "$env_keep_backups" =~ ^[0-9]+$ ]]; then
  KEEP_BACKUPS="$env_keep_backups"
fi

current_kavita_image() { awk -F= '/^KAVITA_IMAGE=/{print $2}' "$ENV_FILE" | tail -n1; }
current_kavita_tag()   { local img; img="$(current_kavita_image)"; echo "${img##*:}"; }
current_kavita_repo()  { awk -F= '/^KAVITA_IMAGE_REPO=/{print $2}' "$ENV_FILE" | tail -n1; }
current_fb_image()     { awk -F= '/^FB_IMAGE=/{print $2}' "$ENV_FILE" | tail -n1; }
current_fb_tag()       { local img; img="$(current_fb_image)"; echo "${img##*:}"; }
current_fb_repo()      { awk -F= '/^FB_IMAGE_REPO=/{print $2}' "$ENV_FILE" | tail -n1; }

env_flag() {
  local key="$1" raw
  raw="$(awk -F= -v key="$key" '$1==key{print $2}' "$ENV_FILE" | tail -n1 | tr -d '[:space:]')"
  [[ "$raw" =~ ^[01]$ ]] && printf '%s' "$raw" || printf '0'
}

auto_update_enabled()  { [[ "$(env_flag AUTO_UPDATE)"  == "1" ]]; }
track_latest_enabled() { [[ "$(env_flag TRACK_LATEST)" == "1" ]]; }

backup_stack() {
  local ts out started=0
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$BACKUP_DIR/kavita-books-backup-$ts.tar.gz"

  mkdir -p "$BACKUP_DIR"

  if systemctl is-active --quiet "$SERVICE"; then
    started=1
    echo "  Stopping stack for consistent backup ..."
    systemctl stop "$SERVICE"
  fi

  trap 'if [[ $started -eq 1 ]]; then systemctl start "$SERVICE" || true; fi' RETURN

  echo "  Creating backup: $out"
  # books/ (media library) is intentionally excluded — back it up via PBS or external tool.
  # This archive covers all operational metadata needed to fully restore the stack.
  tar -C / -czf "$out" \
    opt/kavita-books/.env \
    opt/kavita-books/docker-compose.yml \
    opt/kavita-books/kavita-config \
    opt/kavita-books/filebrowser/filebrowser.db \
    opt/kavita-books/filebrowser/settings.json

  if [[ "$KEEP_BACKUPS" =~ ^[0-9]+$ ]] && (( KEEP_BACKUPS > 0 )); then
    ls -1t "$BACKUP_DIR"/kavita-books-backup-*.tar.gz 2>/dev/null | awk -v keep="$KEEP_BACKUPS" 'NR>keep' | xargs -r rm -f --
  fi

  echo "  OK: $out"
}

restore_stack() {
  local backup="$1"
  [[ -n "$backup" ]] || die "Usage: kavita-books-maint.sh restore <backup.tar.gz>"
  [[ -f "$backup" ]] || die "Backup not found: $backup"

  echo "  Stopping stack ..."
  systemctl stop "$SERVICE" 2>/dev/null || true

  echo "  Removing current config state ..."
  rm -rf \
    "$APP_DIR/kavita-config" \
    "$APP_DIR/filebrowser/filebrowser.db" \
    "$APP_DIR/filebrowser/settings.json"

  echo "  Restoring backup ..."
  tar -C / -xzf "$backup"

  echo "  Starting stack ..."
  systemctl start "$SERVICE"
  echo "  OK: restore completed."
}

update_kavita() {
  local new_tag="$1" old_image old_tag old_repo new_image tmp_env health=0 new_digest old_digest
  [[ -n "$new_tag" ]] || die "Usage: kavita-books-maint.sh update kavita <tag>"
  [[ "$new_tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid Kavita tag: $new_tag"
  # jvmilazz0/kavita only publishes latest/nightly-* — latest is always acceptable

  old_image="$(current_kavita_image)"
  old_tag="$(current_kavita_tag)"
  old_repo="$(current_kavita_repo)"
  [[ -n "$old_image" ]] || die "Could not read current KAVITA_IMAGE from .env"
  new_image="${old_repo}:${new_tag}"
  tmp_env="$(mktemp)"

  echo "  Current Kavita tag: $old_tag"
  echo "  Target  Kavita tag: $new_tag"

  backup_stack
  cp -a "$ENV_FILE" "$tmp_env"

  rollback() {
    echo "  !! Update failed — rolling back .env and container ..." >&2
    cp -a "$tmp_env" "$ENV_FILE"
    cd "$APP_DIR"
    /usr/bin/podman-compose up -d --force-recreate kavita || true
  }
  trap rollback ERR

  echo "  Pulling target image ..."
  podman pull "$new_image"

  # Capture digest — for latest tags this is the only way to detect whether
  # the upstream image actually changed since the last pull.
  new_digest="$(podman inspect --format '{{index .RepoDigests 0}}' "$new_image" 2>/dev/null | head -n1 | tr -d '\r' || echo "unknown")"
  old_digest="$(awk -F= '/^KAVITA_DIGEST=/{print $2}' "$ENV_FILE" | tail -n1)"
  if [[ "$new_digest" == "$old_digest" && "$new_digest" != "unknown" ]]; then
    echo "  Image digest unchanged ($new_digest) — already up to date, no container restart needed."
    rm -f "$tmp_env"
    trap - ERR
    return 0
  fi
  echo "  New digest: $new_digest"

  # Re-detect UID in case the new image changed its process user
  new_kavita_uid="$(podman run --rm --entrypoint sh "$new_image" -lc 'id -u' 2>/dev/null | tr -d '\r')"
  new_kavita_gid="$(podman run --rm --entrypoint sh "$new_image" -lc 'id -g' 2>/dev/null | tr -d '\r')"
  if [[ "$new_kavita_uid" =~ ^[0-9]+$ && "$new_kavita_gid" =~ ^[0-9]+$ ]]; then
    old_kavita_uid="$(awk -F= '/^KAVITA_UID=/{print $2}' "$ENV_FILE" | tail -n1)"
    if [[ "$new_kavita_uid" != "$old_kavita_uid" ]]; then
      echo "  NOTE: Kavita UID changed from ${old_kavita_uid} to ${new_kavita_uid} — fixing kavita-config ownership ..."
      chown -R "${new_kavita_uid}:${new_kavita_gid}" "${APP_DIR}/kavita-config"
    fi
    sed -i \
      -e "s|^KAVITA_UID=.*|KAVITA_UID=$new_kavita_uid|" \
      -e "s|^KAVITA_GID=.*|KAVITA_GID=$new_kavita_gid|" \
      "$ENV_FILE"
  fi

  sed -i \
    -e "s|^KAVITA_TAG=.*|KAVITA_TAG=$new_tag|" \
    -e "s|^KAVITA_IMAGE=.*|KAVITA_IMAGE=$new_image|" \
    -e "s|^KAVITA_DIGEST=.*|KAVITA_DIGEST=$new_digest|" \
    "$ENV_FILE"

  echo "  Recreating Kavita container ..."
  cd "$APP_DIR"
  /usr/bin/podman-compose up -d --force-recreate kavita

  echo "  Waiting for Kavita health endpoint ..."
  for i in $(seq 1 45); do
    if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:5000/api/health"; then
      health=1; break
    fi
    sleep 2
  done
  [[ "$health" -eq 1 ]] || die "Kavita health endpoint did not return 200 after update."

  trap - ERR
  rm -f "$tmp_env"
  echo "  OK: Kavita updated to $new_tag"
}

update_filebrowser() {
  local new_tag="$1" old_image old_tag old_repo new_image tmp_env health=0
  [[ -n "$new_tag" ]] || die "Usage: kavita-books-maint.sh update filebrowser <tag>"
  [[ "$new_tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid Filebrowser tag: $new_tag"
  if [[ "$new_tag" == "latest" && "$(env_flag TRACK_LATEST)" != "1" ]]; then
    die "Refusing to set FB_TAG=latest while TRACK_LATEST=0; use a concrete tag or enable TRACK_LATEST=1."
  fi

  old_image="$(current_fb_image)"
  old_tag="$(current_fb_tag)"
  old_repo="$(current_fb_repo)"
  [[ -n "$old_image" ]] || die "Could not read current FB_IMAGE from .env"
  new_image="${old_repo}:${new_tag}"
  tmp_env="$(mktemp)"

  echo "  Current Filebrowser tag: $old_tag"
  echo "  Target  Filebrowser tag: $new_tag"

  backup_stack
  cp -a "$ENV_FILE" "$tmp_env"

  rollback() {
    echo "  !! Update failed — rolling back .env and container ..." >&2
    cp -a "$tmp_env" "$ENV_FILE"
    cd "$APP_DIR"
    /usr/bin/podman-compose up -d --force-recreate filebrowser || true
  }
  trap rollback ERR

  echo "  Pulling target image ..."
  podman pull "$new_image"

  new_fb_digest="$(podman inspect --format '{{index .RepoDigests 0}}' "$new_image" 2>/dev/null | head -n1 | tr -d '\r' || echo "unknown")"
  old_fb_digest="$(awk -F= '/^FB_DIGEST=/{print $2}' "$ENV_FILE" | tail -n1)"
  if [[ "$new_fb_digest" == "$old_fb_digest" && "$new_fb_digest" != "unknown" ]]; then
    echo "  Image digest unchanged ($new_fb_digest) — already up to date, no container restart needed."
    rm -f "$tmp_env"
    trap - ERR
    return 0
  fi
  echo "  New digest: $new_fb_digest"

  sed -i \
    -e "s|^FB_TAG=.*|FB_TAG=$new_tag|" \
    -e "s|^FB_IMAGE=.*|FB_IMAGE=$new_image|" \
    -e "s|^FB_DIGEST=.*|FB_DIGEST=$new_fb_digest|" \
    "$ENV_FILE"

  echo "  Recreating Filebrowser container ..."
  cd "$APP_DIR"
  /usr/bin/podman-compose up -d --force-recreate filebrowser

  echo "  Waiting for Filebrowser to accept connections ..."
  local fb_up=0 fb_code
  for i in $(seq 1 30); do
    # Accept any HTTP response — connection refused is the only failure we care about.
    fb_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:8080/" 2>/dev/null || echo 000)"
    if [[ "$fb_code" =~ ^[1-9][0-9]{2}$ && "$fb_code" != "000" ]]; then
      fb_up=1; break
    fi
    sleep 2
  done
  if [[ "$fb_up" -eq 0 ]]; then
    echo "  WARNING: Filebrowser port 8080 not responding after update — check logs:" >&2
    echo "    podman logs filebrowser" >&2
    echo "  Update committed; container is running. Verify manually before assuming failure." >&2
  fi

  trap - ERR
  rm -f "$tmp_env"
  echo "  OK: Filebrowser updated to $new_tag"
}

start_fb() {
  if podman ps --format '{{.Names}}' 2>/dev/null | grep -q '^filebrowser$'; then
    echo "  Filebrowser is already running."
    return 0
  fi
  echo "  Starting Filebrowser ..."
  cd "$APP_DIR"
  /usr/bin/podman-compose up -d filebrowser
  local fb_port fb_up=0 fb_code
  fb_port="$(awk -F= '/^FB_PORT=/{print $2}' "$ENV_FILE" | tail -n1)"
  fb_port="${fb_port:-8080}"
  for i in $(seq 1 20); do
    fb_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${fb_port}/" 2>/dev/null || echo 000)"
    if [[ "$fb_code" =~ ^[1-9][0-9]{2}$ && "$fb_code" != "000" ]]; then
      fb_up=1; break
    fi
    sleep 2
  done
  if [[ "$fb_up" -eq 1 ]]; then
    local ip
    ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    echo "  Filebrowser is up: http://${ip:-127.0.0.1}:${fb_port}/"
    echo "  Remember to stop it when you are done: kavita-books-maint.sh stop-fb"
  else
    echo "  WARNING: Filebrowser may still be starting — check: podman logs filebrowser" >&2
  fi
}

stop_fb() {
  if ! podman ps --format '{{.Names}}' 2>/dev/null | grep -q '^filebrowser$'; then
    echo "  Filebrowser is not running."
    return 0
  fi
  echo "  Stopping Filebrowser ..."
  cd "$APP_DIR"
  /usr/bin/podman-compose stop filebrowser
  echo "  Filebrowser stopped. Kavita is unaffected."
}

fb_status() {
  local fb_port state
  fb_port="$(awk -F= '/^FB_PORT=/{print $2}' "$ENV_FILE" | tail -n1)"
  fb_port="${fb_port:-8080}"
  if podman ps --format '{{.Names}}' 2>/dev/null | grep -q '^filebrowser$'; then
    state="running"
    local ip fb_code
    ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    fb_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${fb_port}/" 2>/dev/null || echo 000)"
    echo "  Filebrowser: ${state} (HTTP ${fb_code}) — http://${ip:-127.0.0.1}:${fb_port}/"
  else
    state="stopped"
    echo "  Filebrowser: ${state}"
    echo "  Start with: kavita-books-maint.sh start-fb"
  fi
  echo "  Kavita:      $(podman ps --format '{{.Names}}' 2>/dev/null | grep -q '^kavita$' && echo running || echo stopped)"
}

auto_update_both() {
  if ! auto_update_enabled; then
    echo "  Auto-update disabled in ${ENV_FILE}; nothing to do."
    return 0
  fi

  local fb_target
  # jvmilazz0/kavita only has latest/nightly-* — always pull latest for Kavita.
  # Filebrowser has pinned tags: follow latest only when TRACK_LATEST=1.
  if track_latest_enabled; then
    fb_target="latest"
    echo "  Auto-update policy: Kavita=latest, Filebrowser=latest (TRACK_LATEST=1)"
  else
    fb_target="$(current_fb_tag)"
    echo "  Auto-update policy: Kavita=latest, Filebrowser=${fb_target} (TRACK_LATEST=0)"
  fi

  update_kavita "latest"
  update_filebrowser "$fb_target"
}

need_root
cmd="${1:-}"
case "$cmd" in
  backup) backup_stack ;;
  list) ls -1t "$BACKUP_DIR"/kavita-books-backup-*.tar.gz 2>/dev/null || true ;;
  restore) shift; restore_stack "${1:-}" ;;
  update)
    shift
    app="${1:-}"; shift
    case "$app" in
      kavita)      update_kavita "${1:-}" ;;
      filebrowser) update_filebrowser "${1:-}" ;;
      *) usage; die "Unknown app for update: $app (use kavita or filebrowser)" ;;
    esac
    ;;
  auto-update) auto_update_both ;;
  start-fb) start_fb ;;
  stop-fb) stop_fb ;;
  fb-status) fb_status ;;
  version)
    echo "Kavita image:        $(current_kavita_image)"
    echo "Kavita digest:       $(awk -F= '/^KAVITA_DIGEST=/{print $2}' "$ENV_FILE" | tail -n1)"
    echo "Kavita UID:GID:      $(awk -F= '/^KAVITA_UID=/{print $2}' "$ENV_FILE" | tail -n1):$(awk -F= '/^KAVITA_GID=/{print $2}' "$ENV_FILE" | tail -n1)"
    echo "Filebrowser image:   $(current_fb_image)"
    echo "Filebrowser digest:  $(awk -F= '/^FB_DIGEST=/{print $2}' "$ENV_FILE" | tail -n1)"
    echo "Filebrowser UID:GID: $(awk -F= '/^FB_UID=/{print $2}' "$ENV_FILE" | tail -n1):$(awk -F= '/^FB_GID=/{print $2}' "$ENV_FILE" | tail -n1)"
    echo "Media GID:           $(awk -F= '/^MEDIA_GID=/{print $2}' "$ENV_FILE" | tail -n1)"
    echo "AUTO_UPDATE=$(env_flag AUTO_UPDATE)"
    echo "TRACK_LATEST=$(env_flag TRACK_LATEST)"
    ;;
  ""|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
MAINT
echo "  Maintenance script deployed: /usr/local/bin/kavita-books-maint.sh"

# ── Systemd stack unit ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/kavita-books-stack.service <<EOF2
[Unit]
Description=Kavita + Filebrowser (Podman) stack
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/kavita-books
ExecStart=/usr/bin/podman-compose up -d
ExecStop=/usr/bin/podman-compose down
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF2

  systemctl daemon-reload
  systemctl enable --now kavita-books-stack.service
'

# ── Verification ──────────────────────────────────────────────────────────────
sleep 3
if pct exec "$CT_ID" -- systemctl is-active --quiet kavita-books-stack.service 2>/dev/null; then
  echo "  kavita-books-stack.service is active"
else
  echo "  WARNING: kavita-books-stack.service may not be active — check: pct exec $CT_ID -- journalctl -u kavita-books-stack --no-pager -n 50" >&2
fi

RUNNING=0
for i in $(seq 1 90); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc 'podman ps --format "{{.Names}}" 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge 2 ]] && break
  sleep 2
done
pct exec "$CT_ID" -- bash -lc 'cd /opt/kavita-books && podman-compose ps' || true

KAVITA_HEALTHY=0
for i in $(seq 1 45); do
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${KAVITA_PORT}/api/health 2>/dev/null" 2>/dev/null || echo 000)"
  if [[ "$HTTP_CODE" == "200" ]]; then
    KAVITA_HEALTHY=1; break
  fi
  sleep 2
done

FB_UP=0
for i in $(seq 1 30); do
  # Accept any HTTP response (200, 302, 303, 401…) — connection refused means not ready.
  # /api/health is not a documented readiness contract for Filebrowser.
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc "curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:${FB_PORT}/ 2>/dev/null" 2>/dev/null || echo 000)"
  if [[ "$HTTP_CODE" =~ ^[1-9][0-9]{2}$ && "$HTTP_CODE" != "000" ]]; then
    FB_UP=1; break
  fi
  sleep 2
done

if [[ "$KAVITA_HEALTHY" -eq 1 ]]; then
  echo "  Kavita health check passed (HTTP 200)"
else
  echo "  WARNING: Kavita health endpoint did not return 200 yet" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u kavita-books-stack.service --no-pager -n 80" >&2
  echo "  Check: pct exec $CT_ID -- bash -lc 'cd /opt/kavita-books && podman-compose logs --tail=80'" >&2
fi

if [[ "$FB_UP" -eq 1 ]]; then
  echo "  Filebrowser is accepting HTTP connections (HTTP ${HTTP_CODE})"
else
  echo "  WARNING: Filebrowser port ${FB_PORT} not responding yet — it may still be starting" >&2
  echo "  Check: pct exec $CT_ID -- bash -lc 'cd /opt/kavita-books && podman-compose logs --tail=80'" >&2
fi

# Capture the Filebrowser generated admin password from first-boot logs.
# FB generates a random password on every fresh database init and prints it once.
FB_ADMIN_PASS="$(pct exec "$CT_ID" -- bash -lc \
  "podman logs filebrowser 2>&1 | grep -oP 'Generated random admin password for quick setup: \K\S+'" \
  2>/dev/null || echo "(not found — run: podman logs filebrowser)")"

# ── Auto-update timer (policy-driven) ─────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/kavita-books-update.service <<EOF2
[Unit]
Description=Kavita + Filebrowser auto-update maintenance run
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kavita-books-maint.sh auto-update
EOF2

  cat > /etc/systemd/system/kavita-books-update.timer <<EOF2
[Unit]
Description=Kavita + Filebrowser auto-update timer

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
  pct exec "$CT_ID" -- bash -lc 'systemctl enable --now kavita-books-update.timer'
  echo "  Auto-update timer enabled"
else
  pct exec "$CT_ID" -- bash -lc 'systemctl disable --now kavita-books-update.timer >/dev/null 2>&1 || true'
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
printf '\n  Kavita + Filebrowser (Podman)\n'
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
kavita_state=\$(podman ps --format '{{.Names}}' 2>/dev/null | grep -q '^kavita\$' && echo running || echo stopped)
fb_state=\$(podman ps --format '{{.Names}}' 2>/dev/null | grep -q '^filebrowser\$' && echo running || echo stopped)
service_active=\$(systemctl is-active kavita-books-stack.service 2>/dev/null || echo 'unknown')
kavita_image=\$(awk -F= '/^KAVITA_IMAGE=/{print \$2}' /opt/kavita-books/.env 2>/dev/null | tail -n1)
fb_image=\$(awk -F= '/^FB_IMAGE=/{print \$2}' /opt/kavita-books/.env 2>/dev/null | tail -n1)
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '  Service:   %s\n' "\$service_active"
printf '  Kavita:    %s  —  %s\n' "\$kavita_state" "\${kavita_image:-n/a}"
printf '  FB:        %s  —  %s\n' "\$fb_state" "\${fb_image:-n/a}"
printf '  Books dir: /opt/kavita-books/books\n'
printf '  Kavita:    http://%s:${KAVITA_PORT}\n' "\${ip:-n/a}"
if [ "\$fb_state" = "running" ]; then
  printf '  FB:        http://%s:${FB_PORT}  (stop when done uploading)\n' "\${ip:-n/a}"
else
  printf '  FB:        stopped  (start-fb to upload, stop-fb when done)\n'
fi
[ -n '${PUBLIC_FQDN}' ] && printf '  Public:    https://${PUBLIC_FQDN}\n' || true
printf '  Maintain:  kavita-books-maint.sh [backup|start-fb|stop-fb|fb-status|update|version]\n'
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
  KAVITA_LINK="https://${PUBLIC_FQDN}/"
else
  KAVITA_LINK="http://${CT_IP}:${KAVITA_PORT}/"
fi
FB_LINK="http://${CT_IP}:${FB_PORT}/"
CT_DESC="<a href='${KAVITA_LINK}' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Kavita Web UI</a> | <a href='${FB_LINK}' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Filebrowser</a>
<details><summary>Details</summary>Kavita ${KAVITA_TAG} + Filebrowser ${FB_TAG} on Debian ${DEBIAN_VERSION} LXC
Kavita UID:GID ${KAVITA_UID}:${KAVITA_GID} | FB UID:GID ${FB_UID}:${FB_GID} | Media GID ${MEDIA_GID}
Books: /opt/kavita-books/books (SGID 2775, shared via mediagroup)
Books storage: ${BOOKS_STORAGE}
Created by kavita-books-podman.sh</details>"
pct set "$CT_ID" --description "$CT_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  CT: $CT_ID | IP: ${CT_IP} | Login: password set"
echo ""
echo "  Access (local):"
echo "    Kavita:      http://${CT_IP}:${KAVITA_PORT}/"
echo "    Filebrowser: http://${CT_IP}:${FB_PORT}/"
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
echo "    ${APP_DIR}/kavita-config              (Kavita config at /kavita/config — backed up)"
echo "    ${APP_DIR}/filebrowser/filebrowser.db (Filebrowser database — backed up)"
echo "    ${APP_DIR}/filebrowser/settings.json  (Filebrowser config — backed up)"
if [[ "$BOOKS_STORAGE" == "rootfs" ]]; then
  echo "    ${APP_DIR}/books                      (media — rootfs; NOT in script backup; use PBS)"
elif [[ "$BOOKS_STORAGE" == /* ]]; then
  echo "    ${APP_DIR}/books <- ${BOOKS_STORAGE}  (media — host path; NOT in script backup)"
else
  echo "    ${APP_DIR}/books <- ${BOOKS_HOST_PATH:-${BOOKS_STORAGE}/kavita-books}  (ZFS; NOT in script backup)"
fi
echo ""
echo "  Permissions:"
echo "    Kavita internal UID:GID  = ${KAVITA_UID}:${KAVITA_GID}"
echo "    Filebrowser UID:GID      = ${FB_UID}:${FB_GID}"
echo "    books/ owner:group       = ${KAVITA_UID}:${MEDIA_GID} (SGID 2775)"
echo "    Both containers          : group_add mediagroup (GID ${MEDIA_GID})"
echo ""
echo "  Post-setup:"
echo "    1. Open Kavita — run the setup wizard to create your admin account"
echo "    2. Add a Library in Kavita admin settings pointing to /books"
echo "    3. Open Filebrowser — login: admin / ${FB_ADMIN_PASS}"
echo "       Change the password immediately after first login"
echo "    4. Upload books via Filebrowser (/srv in the container = books/ on host)"
echo ""
echo "  IMPORTANT — Kavita folder structure:"
echo "    Kavita requires books to be inside subdirectories, never loose at the"
echo "    root of the library folder. Files placed directly in /books will trigger:"
echo "    'one or more folders contain files at root, Kavita does not support that'"
echo ""
echo "    Correct layout:"
echo "      /books/Author Name/book.epub"
echo "      /books/Series Name/vol1.cbz"
echo "      /books/My Collection/title.pdf"
echo ""
echo "    Wrong (files at library root):"
echo "      /books/book.epub            <- Kavita will reject this"
echo ""
echo "    In Filebrowser: upload a folder containing books — the folder itself becomes"
echo "    the required subfolder. Never drop loose files directly into the root of /srv."
echo ""
echo "  Maintenance:"
echo "    Policy: AUTO_UPDATE=${AUTO_UPDATE} TRACK_LATEST=${TRACK_LATEST}"
echo "    pct exec $CT_ID -- kavita-books-maint.sh backup"
echo "    pct exec $CT_ID -- kavita-books-maint.sh list"
echo "    pct exec $CT_ID -- kavita-books-maint.sh update kavita <tag>"
echo "    pct exec $CT_ID -- kavita-books-maint.sh update filebrowser <tag>"
echo "    pct exec $CT_ID -- kavita-books-maint.sh restore /opt/kavita-books-backups/<backup.tar.gz>"
echo "    pct exec $CT_ID -- kavita-books-maint.sh auto-update"
echo ""
echo "  Filebrowser (on-demand — stop when not uploading):"
echo "    pct exec $CT_ID -- kavita-books-maint.sh start-fb"
echo "    pct exec $CT_ID -- kavita-books-maint.sh stop-fb"
echo "    pct exec $CT_ID -- kavita-books-maint.sh fb-status"
echo ""
echo "  Done."
