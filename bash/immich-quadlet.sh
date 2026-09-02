#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID=""                             # empty = auto-assign via pvesh; set e.g. CT_ID=120 to pin
HN="immich"
CPU=4
RAM=8192                             # ML (CLIP + facial recognition) needs headroom; 4096 is the floor without ML
DISK=32                              # rootfs holds PostgreSQL + /config (ML model cache ~1.5 GB) + library in rootfs mode
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"
PHOTO_STORAGE="rootfs"               # rootfs | <zfs-pool> | /absolute/host/path
                                     #   rootfs      → library lives on the CT disk (small or test installs only)
                                     #   <zfs-pool>  → dataset <pool>/immich-photos is created (or re-attached) and bind-mounted
                                     #   /host/path  → host directory is bind-mounted (created if missing, re-attached if populated)

# Immich / Podman + Quadlet
APP_PORT=2283                        # Immich binds this port on the CT interface (Network=host)
APP_TZ="Europe/Berlin"
APP_FQDN=""                          # e.g. photos.example.com ; blank = local IP mode
TAGS="immich;podman;quadlet;lxc"

# Images / versions
# imagegenius publishes plain semver tags (3.1.0) with optional variant suffix
# (3.1.0-noml = no ML, smaller; -cuda/-openvino need GPU passthrough, not handled
# here) plus the floating tags latest / noml / cuda / openvino. GHCR is the source
# of truth: https://github.com/imagegenius/docker-immich/pkgs/container/immich
APP_IMAGE_REPO="ghcr.io/imagegenius/immich"
APP_TAG="3.1.0"                      # full version (optionally -noml), or "latest"; floating 3 / 3.1 / noml are rejected
# PostgreSQL with VectorChord — Immich requires this image family. Take the tag
# from the Immich release notes; a different major (14- → 15-) needs a dump/restore
# and is refused by the maint script.
POSTGRES_IMAGE_REPO="ghcr.io/immich-app/postgres"
POSTGRES_TAG="14-vectorchord0.4.3-pgvectors0.2.0"
POSTGRES_STORAGE_TYPE="SSD"          # SSD | HDD — HDD sets DB_STORAGE_TYPE=HDD (random_page_cost tuning in the image)
# Valkey (job queue): Immich upstream ships valkey:8-bookworm; pinned to a full 8.x here.
VALKEY_IMAGE_REPO="docker.io/valkey/valkey"
VALKEY_TAG="8.1.3"                   # full version like 8.1.3, or "latest"; floating majors (8, 8.1) are rejected
DEBIAN_VERSION=13

# Auto-update policy
# AUTO_UPDATE=0 (default): timer installed but disabled; manual updates via
#   immich-maint.sh update <tag> / update-postgres <tag> / update-valkey <tag>
# AUTO_UPDATE=1: immich-update.timer re-pulls the CURRENT tags (pinned or latest)
#   daily at UPDATE_TIME and restarts only what changed; a failed health check
#   rolls back to the previous image. Immich runs DB migrations on upgrade —
#   an image rollback after a migrated schema is NOT safe; PBS covers that case.
AUTO_UPDATE=0
UPDATE_TIME="03:00"                  # local CT time (APP_TZ), HH:MM; timer runs daily

# Podman storage backend
# PODMAN_FUSE_OVERLAY=1: lab default so far — fuse=1 on the CT + fuse-overlayfs
#   as mount_program. Proxmox warns that FUSE mounts inside a CT can deadlock
#   when the CT is frozen, which snapshot-mode vzdump/PBS backups do.
# PODMAN_FUSE_OVERLAY=0: native overlayfs in the CT's user namespace (kernel
#   >= 5.11); no fuse=1, no mount_program, no freezer interaction. Verify after
#   install with: podman info --format '{{.Store.GraphDriverName}}' (overlay) and
#   run a snapshot-mode backup under load before adopting lab-wide.
PODMAN_FUSE_OVERLAY=1

# Extra packages to install (space-separated or array)
EXTRA_PACKAGES=(
)

# Behavior
CLEANUP_ON_FAIL=1

# Derived
APP_DIR="/opt/immich"
LIBRARY_DIR="${APP_DIR}/library"
APP_IMAGE="${APP_IMAGE_REPO}:${APP_TAG}"
POSTGRES_IMAGE="${POSTGRES_IMAGE_REPO}:${POSTGRES_TAG}"
VALKEY_IMAGE="${VALKEY_IMAGE_REPO}:${VALKEY_TAG}"
QUADLET_DIR="/etc/containers/systemd"
QUADLET_FILE="${QUADLET_DIR}/immich.container"
QUADLET_SERVICE="immich.service"
POSTGRES_QUADLET_FILE="${QUADLET_DIR}/immich-postgres.container"
POSTGRES_QUADLET_SERVICE="immich-postgres.service"
VALKEY_QUADLET_FILE="${QUADLET_DIR}/immich-valkey.container"
VALKEY_QUADLET_SERVICE="immich-valkey.service"
APP_ENV_FILE="${APP_DIR}/immich.env"          # DB_PASSWORD for the app container (EnvironmentFile=, 0600)
POSTGRES_ENV_FILE="${APP_DIR}/postgres.env"   # POSTGRES_PASSWORD for the DB container (EnvironmentFile=, 0600)

# ── Custom configs created by this script ─────────────────────────────────────
#   /etc/containers/systemd/immich.container           (Quadlet unit — source of truth)
#   /etc/containers/systemd/immich-postgres.container  (Quadlet unit — PostgreSQL/VectorChord)
#   /etc/containers/systemd/immich-valkey.container    (Quadlet unit — job queue)
#   /opt/immich/.env                                   (runtime state — read by maint script)
#   /opt/immich/immich.env                             (DB_PASSWORD — read by Quadlet, 0600)
#   /opt/immich/postgres.env                           (POSTGRES_PASSWORD — read by Quadlet, 0600)
#   /opt/immich/valkey.conf                            (Valkey config — loopback only, no persistence)
#   /opt/immich/postgres-init/10-listen-localhost.sql  (first-init only: listen_addresses=127.0.0.1)
#   /opt/immich/postgres/                              (PostgreSQL data — uid 999)
#   /opt/immich/config/                                (Immich app config + ML model cache — uid 1000)
#   /opt/immich/library/                               (photo library — uid 1000; mp0 bind mount unless rootfs)
#   /usr/local/bin/immich-maint.sh                     (maintenance helper)
#   /etc/systemd/system/immich-update.service
#   /etc/systemd/system/immich-update.timer
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/sysctl.d/99-hardening.conf
#   Host side (only when PHOTO_STORAGE != rootfs):
#   <zfs-pool>/immich-photos                           (ZFS dataset, created if missing)
#   <host path or dataset mountpoint>                  (chown 101000:101000 when newly created)

# ── Config validation ─────────────────────────────────────────────────────────
[[ "$HN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || { echo "  ERROR: HN is not a valid hostname: $HN" >&2; exit 1; }
[[ "$CPU" =~ ^[0-9]+$ ]] && (( CPU >= 1 )) || { echo "  ERROR: CPU must be a positive integer." >&2; exit 1; }
[[ "$RAM" =~ ^[0-9]+$ ]] && (( RAM >= 256 )) || { echo "  ERROR: RAM must be >= 256 MB." >&2; exit 1; }
[[ "$DISK" =~ ^[0-9]+$ ]] && (( DISK >= 1 )) || { echo "  ERROR: DISK must be >= 1 GB." >&2; exit 1; }
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }
[[ "$APP_PORT" =~ ^[0-9]+$ ]] || { echo "  ERROR: APP_PORT must be numeric." >&2; exit 1; }
(( APP_PORT >= 1 && APP_PORT <= 65535 )) || { echo "  ERROR: APP_PORT must be between 1 and 65535." >&2; exit 1; }
# All three containers share the CT network stack (Network=host).
(( APP_PORT != 5432 && APP_PORT != 6379 && APP_PORT != 3003 )) \
  || { echo "  ERROR: APP_PORT $APP_PORT collides with PostgreSQL (5432), Valkey (6379) or machine learning (3003) on the shared host network." >&2; exit 1; }
[[ "$AUTO_UPDATE" =~ ^[01]$ ]] || { echo "  ERROR: AUTO_UPDATE must be 0 or 1." >&2; exit 1; }
[[ "$PODMAN_FUSE_OVERLAY" =~ ^[01]$ ]] || { echo "  ERROR: PODMAN_FUSE_OVERLAY must be 0 or 1." >&2; exit 1; }
[[ "$CLEANUP_ON_FAIL" =~ ^[01]$ ]] || { echo "  ERROR: CLEANUP_ON_FAIL must be 0 or 1." >&2; exit 1; }
[[ "$POSTGRES_STORAGE_TYPE" =~ ^(SSD|HDD)$ ]] || { echo "  ERROR: POSTGRES_STORAGE_TYPE must be SSD or HDD." >&2; exit 1; }
# Image repos are interpolated into podman, sed, the Quadlet units and .env.
for _repo_var in APP_IMAGE_REPO POSTGRES_IMAGE_REPO VALKEY_IMAGE_REPO; do
  [[ "${!_repo_var}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*[A-Za-z0-9]$ ]] || {
    echo "  ERROR: ${_repo_var} must look like registry/namespace/name (no tag, no spaces)." >&2
    exit 1
  }
done
unset _repo_var
# Immich: "latest" or full semver with optional -noml (3.1.0, 3.1.0-noml). Floating
# majors (3, 3.1) and bare variant tags (noml, cuda, openvino) are rejected — they
# hide which line is running without the simplicity of "latest".
[[ "$APP_TAG" == "latest" || "$APP_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-noml)?$ ]] || {
  echo "  ERROR: APP_TAG must be 'latest' or a full version like 3.1.0 / 3.1.0-noml (floating tags like 3, 3.1 or noml are not accepted)." >&2
  exit 1
}
# PostgreSQL: <major>-vectorchord<ver>[-pgvectors<ver>] exactly as published by immich-app.
[[ "$POSTGRES_TAG" =~ ^[0-9]{2}-vectorchord[0-9]+\.[0-9]+\.[0-9]+(-pgvectors[0-9]+\.[0-9]+\.[0-9]+)?$ ]] || {
  echo "  ERROR: POSTGRES_TAG must look like 14-vectorchord0.4.3-pgvectors0.2.0 (see Immich release notes)." >&2
  exit 1
}
# Valkey: "latest" or full semver (8.1.3, 8.1.3-bookworm). Floating majors (8, 8.1) are rejected.
[[ "$VALKEY_TAG" == "latest" || "$VALKEY_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: VALKEY_TAG must be 'latest' or a full version like 8.1.3 (floating tags like 8 are not accepted)." >&2
  exit 1
}
[[ "$UPDATE_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "  ERROR: UPDATE_TIME must be HH:MM (24h), e.g. 03:00." >&2; exit 1; }
[[ -e "/usr/share/zoneinfo/${APP_TZ}" ]] || { echo "  ERROR: APP_TZ not found in /usr/share/zoneinfo: $APP_TZ" >&2; exit 1; }
[[ "$APP_TZ" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)+$ ]] || { echo "  ERROR: APP_TZ contains invalid characters." >&2; exit 1; }
if [[ -n "$APP_FQDN" ]]; then
  [[ "$APP_FQDN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]] \
    || { echo "  ERROR: APP_FQDN is not a valid hostname: $APP_FQDN" >&2; exit 1; }
fi
# PHOTO_STORAGE is interpolated into pct set --mp0, zfs create and chown.
if [[ "$PHOTO_STORAGE" == /* ]]; then
  [[ "$PHOTO_STORAGE" =~ ^/[A-Za-z0-9._/-]+$ && "$PHOTO_STORAGE" != *//* && "$PHOTO_STORAGE" != */ ]] \
    || { echo "  ERROR: PHOTO_STORAGE host path must be an absolute path without spaces, trailing slash or '//': $PHOTO_STORAGE" >&2; exit 1; }
elif [[ "$PHOTO_STORAGE" != "rootfs" ]]; then
  [[ "$PHOTO_STORAGE" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]*$ ]] \
    || { echo "  ERROR: PHOTO_STORAGE must be rootfs, an absolute host path, or a ZFS pool name." >&2; exit 1; }
fi
[[ "$TAGS" =~ ^[A-Za-z0-9._-]+(;[A-Za-z0-9._-]+)*$ ]] || { echo "  ERROR: TAGS must be a semicolon-separated list without spaces." >&2; exit 1; }
for pkg in "${EXTRA_PACKAGES[@]}"; do
  [[ "$pkg" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || { echo "  ERROR: Invalid package name in EXTRA_PACKAGES: $pkg" >&2; exit 1; }
done

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

for cmd in pvesh pveam pct pvesm qm curl python3 ip awk grep sed sort paste seq readlink cp chmod chown stat dpkg head tr ls mkdir; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done
if [[ "$PHOTO_STORAGE" != "rootfs" && "$PHOTO_STORAGE" != /* ]]; then
  for cmd in zfs zpool; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd (PHOTO_STORAGE is a ZFS pool name)" >&2; exit 1; }
  done
fi

# pveam lists templates for more than one CPU architecture. Selecting only by
# Debian version can pick an ARM64 rootfs on an AMD64 host (or vice versa),
# which creates successfully but fails when LXC executes /sbin/init.
HOST_ARCH="$(dpkg --print-architecture)"
case "$HOST_ARCH" in
  amd64|arm64) ;;
  *) echo "  ERROR: Unsupported Proxmox host architecture: $HOST_ARCH" >&2; exit 1 ;;
esac

# Prompts read from the terminal directly so the script also works when
# piped (curl ... | bash) and stdin is the script body.
if ! exec 8</dev/tty; then
  echo "  ERROR: An interactive terminal is required for confirmation and password prompts." >&2
  exit 1
fi

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

# Creator scripts are not idempotent: a re-run would create a second CT with the
# same hostname. Refuse if one already exists on this node (e.g. a preserved
# failed install) — destroy it first or change HN.
EXISTING_CT="$(pct list 2>/dev/null | awk -v h="$HN" 'NR>1 && $NF==h {print $1}' | head -n1)"
if [[ -n "$EXISTING_CT" ]]; then
  echo "  ERROR: A CT with hostname '${HN}' already exists on this node (CT ${EXISTING_CT})." >&2
  echo "  Destroy it (pct set ${EXISTING_CT} --protection 0; pct destroy ${EXISTING_CT}) or change HN, then re-run." >&2
  exit 1
fi

# ── Discover available resources ──────────────────────────────────────────────
AVAIL_TMPL_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'vztmpl' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_CT_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^vmbr' | sort | paste -sd, | sed 's/,/, /g' || echo "n/a")"
AVAIL_ZFS_POOLS="n/a"
if command -v zpool >/dev/null 2>&1; then
  AVAIL_ZFS_POOLS="$(zpool list -H -o name 2>/dev/null | sort | paste -sd, - | sed 's/,/, /g' || true)"
  AVAIL_ZFS_POOLS="${AVAIL_ZFS_POOLS:-none}"
fi

# Derived host-path → CT-path mapping for the confirmation screen (read-only here;
# creation, ownership and the existing-data prompt happen after confirmation).
PHOTO_MOUNT_SRC=""                   # host path attached as mp0; empty in rootfs mode
PHOTOS_DATASET=""
PHOTO_MAPPING="${LIBRARY_DIR} on CT rootfs (${DISK} GB shared with OS, DB and ML cache)"
if [[ "$PHOTO_STORAGE" == /* ]]; then
  PHOTO_MOUNT_SRC="$PHOTO_STORAGE"
  if [[ -d "$PHOTO_STORAGE" && -n "$(ls -A "$PHOTO_STORAGE" 2>/dev/null)" ]]; then
    PHOTO_MAPPING="${PHOTO_STORAGE} → ${LIBRARY_DIR} (mp0; EXISTING DATA — will prompt)"
  elif [[ -d "$PHOTO_STORAGE" ]]; then
    PHOTO_MAPPING="${PHOTO_STORAGE} → ${LIBRARY_DIR} (mp0; empty directory)"
  else
    PHOTO_MAPPING="${PHOTO_STORAGE} → ${LIBRARY_DIR} (mp0; will be created)"
  fi
elif [[ "$PHOTO_STORAGE" != "rootfs" ]]; then
  PHOTOS_DATASET="${PHOTO_STORAGE}/immich-photos"
  _mp="$(zfs get -H -o value mountpoint "$PHOTOS_DATASET" 2>/dev/null || true)"
  if [[ -n "$_mp" && "$_mp" != "-" && "$_mp" != "legacy" ]]; then
    PHOTO_MOUNT_SRC="$_mp"
    if [[ -n "$(ls -A "$_mp" 2>/dev/null)" ]]; then
      PHOTO_MAPPING="${PHOTOS_DATASET} (${_mp}) → ${LIBRARY_DIR} (mp0; EXISTING DATASET WITH DATA — will prompt)"
    else
      PHOTO_MAPPING="${PHOTOS_DATASET} (${_mp}) → ${LIBRARY_DIR} (mp0; existing empty dataset — will prompt)"
    fi
  else
    PHOTO_MAPPING="${PHOTOS_DATASET} → ${LIBRARY_DIR} (mp0; dataset will be created)"
  fi
  unset _mp
fi

# ── Show defaults & confirm ───────────────────────────────────────────────────
cat <<EOF2

  Immich Quadlet LXC Creator — Configuration
  ────────────────────────────────────────
  CT ID:             $CT_ID
  Hostname:          $HN
  CPU cores:         $CPU
  RAM (MB):          $RAM
  Disk (GB):         $DISK
  Bridge:            $BRIDGE ($AVAIL_BRIDGES)
  Template storage:  $TEMPLATE_STORAGE ($AVAIL_TMPL_STORES)
  Container storage: $CONTAINER_STORAGE ($AVAIL_CT_STORES)
  Host architecture: $HOST_ARCH
  Debian:            $DEBIAN_VERSION
  Immich image:      $APP_IMAGE
  Postgres image:    $POSTGRES_IMAGE (storage type: $POSTGRES_STORAGE_TYPE)
  Valkey image:      $VALKEY_IMAGE (job queue, no persistence)
  App port:          $APP_PORT
  Timezone:          $APP_TZ
  FQDN:              $([ -n "$APP_FQDN" ] && echo "$APP_FQDN" || echo "(no public FQDN — local IP mode)")
  Photo storage:     $PHOTO_STORAGE (ZFS pools: $AVAIL_ZFS_POOLS)
  Photo library:     $PHOTO_MAPPING
  Listens on:        0.0.0.0:${APP_PORT} inside the CT (Network=host) — reachable from the whole LAN
                     PostgreSQL 127.0.0.1:5432, Valkey 127.0.0.1:6379, ML 127.0.0.1:3003 (loopback only)
  Podman storage:    $([ "$PODMAN_FUSE_OVERLAY" -eq 1 ] && echo "fuse-overlayfs (fuse=1)" || echo "native overlay (no FUSE)")
  Tags:              $TAGS
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled — daily at ${UPDATE_TIME} (re-pull $APP_TAG / $POSTGRES_TAG / $VALKEY_TAG)" || echo "disabled ($APP_TAG / $POSTGRES_TAG / $VALKEY_TAG, manual)")
  Cleanup on fail:   $CLEANUP_ON_FAIL (until first service start; CT preserved after that — host photo path/dataset is never removed)
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/immich-quadlet.sh"
SCRIPT_LOCAL="/root/immich-quadlet.sh"
SCRIPT_SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

read -r -p "  Continue with these settings? [y/N]: " response <&8
case "$response" in
  [yY][eE][sS]|[yY]) ;;
  *)
    echo ""
    echo "  Saving current script to ${SCRIPT_LOCAL} for editing..."
    # Shebang check: when run as 'curl | bash', $0 is the bash binary, not this script.
    if [[ -f "$SCRIPT_SELF" ]] && head -n1 "$SCRIPT_SELF" 2>/dev/null | grep -q '^#!/usr/bin/env bash$' \
      && cp -f -- "$SCRIPT_SELF" "$SCRIPT_LOCAL"; then
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
      exit 1
    fi
    exit 0
    ;;
esac

echo ""

# ── Preflight — environment ───────────────────────────────────────────────────
pvesm status | awk -v s="$TEMPLATE_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Template storage not found: $TEMPLATE_STORAGE" >&2; exit 1; }
pvesh get /storage/"$TEMPLATE_STORAGE" --output-format json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'vztmpl' in d.get('content','')" 2>/dev/null \
  || { echo "  ERROR: Template storage '$TEMPLATE_STORAGE' does not support vztmpl content." >&2; exit 1; }

pvesm status | awk -v s="$CONTAINER_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Container storage not found: $CONTAINER_STORAGE" >&2; exit 1; }
pvesh get /storage/"$CONTAINER_STORAGE" --output-format json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'rootdir' in d.get('content','')" 2>/dev/null \
  || { echo "  ERROR: Container storage '$CONTAINER_STORAGE' does not support rootdir content." >&2; exit 1; }

ip link show "$BRIDGE" >/dev/null 2>&1 \
  || { echo "  ERROR: Bridge not found: $BRIDGE" >&2; exit 1; }

if [[ -n "$PHOTOS_DATASET" ]]; then
  zpool list -H -o name "$PHOTO_STORAGE" >/dev/null 2>&1 \
    || { echo "  ERROR: ZFS pool not found: $PHOTO_STORAGE (available: $AVAIL_ZFS_POOLS)" >&2; exit 1; }
fi
if [[ "$PHOTO_STORAGE" == /* && -e "$PHOTO_STORAGE" && ! -d "$PHOTO_STORAGE" ]]; then
  echo "  ERROR: PHOTO_STORAGE exists but is not a directory: $PHOTO_STORAGE" >&2
  exit 1
fi

# ── Root password ─────────────────────────────────────────────────────────────
PASSWORD=""
while true; do
  read -r -s -p "  Set root password: " PW1 <&8; echo
  if [[ -z "$PW1" ]]; then echo "  Password cannot be blank."; continue; fi
  if [[ "$PW1" == *" "* ]]; then echo "  Password cannot contain spaces."; continue; fi
  if [[ ${#PW1} -lt 8 ]]; then echo "  Password must be at least 8 characters."; continue; fi
  read -r -s -p "  Verify root password: " PW2 <&8; echo
  if [[ "$PW1" == "$PW2" ]]; then PASSWORD="$PW1"; break; fi
  echo "  Passwords do not match. Try again."
done

echo ""

# ── Photo storage — host-side preparation ─────────────────────────────────────
# Unprivileged LXC idmap: CT uid 1000 (Immich PUID) is host uid 101000. A bind
# mount must be owned by 101000:101000 on the host for the app to write to it.
# Newly created paths are chowned; populated paths are attached as-is and their
# top-level ownership is checked, never mass-chowned (re-check before touching
# existing data). Nothing here is undone by the cleanup trap.
PHOTO_EXISTING=0
if [[ "$PHOTO_STORAGE" == "rootfs" ]]; then
  echo "  WARNING: No external photo storage configured — the library lives on the CT rootfs (${DISK} GB)." >&2
  echo "           Set PHOTO_STORAGE to a ZFS pool or host path for a production library." >&2
elif [[ "$PHOTO_STORAGE" == /* ]]; then
  if [[ -d "$PHOTO_STORAGE" && -n "$(ls -A "$PHOTO_STORAGE" 2>/dev/null)" ]]; then
    _owner="$(stat -c '%u:%g' "$PHOTO_STORAGE")"
    echo ""
    echo "  !! EXISTING DATA DETECTED — host path: ${PHOTO_STORAGE}"
    echo "  This directory is non-empty and will be bind-mounted as ${LIBRARY_DIR} on the"
    echo "  new CT. Existing files are preserved and ownership is NOT changed."
    echo "  Top-level owner: ${_owner} (must be 101000:101000 = CT uid 1000)"
    echo ""
    read -r -p "  Attach existing library to the new instance? [y/N]: " _pr <&8
    case "$_pr" in
      [yY][eE][sS]|[yY]) PHOTO_EXISTING=1 ;;
      *) echo "  Aborted." >&2; exit 1 ;;
    esac
    [[ "$_owner" == "101000:101000" ]] || {
      echo "  ERROR: ${PHOTO_STORAGE} is owned by ${_owner}, expected 101000:101000." >&2
      echo "         Fix on the host first (verify the contents before any recursive chown):" >&2
      echo "         chown -R 101000:101000 ${PHOTO_STORAGE}" >&2
      exit 1
    }
    unset _owner _pr
  else
    mkdir -p "$PHOTO_STORAGE"
    chown 101000:101000 "$PHOTO_STORAGE"
    chmod 0755 "$PHOTO_STORAGE"
  fi
  echo "  Photo library: ${PHOTO_MOUNT_SRC} → ${LIBRARY_DIR} (mp0)"
else
  if [[ -z "$PHOTO_MOUNT_SRC" ]]; then
    echo "  Creating ZFS dataset: ${PHOTOS_DATASET}"
    zfs create -o compression=lz4 "$PHOTOS_DATASET"
    PHOTO_MOUNT_SRC="$(zfs get -H -o value mountpoint "$PHOTOS_DATASET")"
    [[ -n "$PHOTO_MOUNT_SRC" && "$PHOTO_MOUNT_SRC" == /* ]] || { echo "  ERROR: Dataset ${PHOTOS_DATASET} has no usable mountpoint: '${PHOTO_MOUNT_SRC}'" >&2; exit 1; }
    chown 101000:101000 "$PHOTO_MOUNT_SRC"
    chmod 0755 "$PHOTO_MOUNT_SRC"
  else
    [[ "$(zfs get -H -o value mounted "$PHOTOS_DATASET" 2>/dev/null)" == "yes" ]] \
      || { echo "  ERROR: Dataset ${PHOTOS_DATASET} exists but is not mounted at ${PHOTO_MOUNT_SRC}." >&2; exit 1; }
    _owner="$(stat -c '%u:%g' "$PHOTO_MOUNT_SRC")"
    _photo_empty=1
    [[ -n "$(ls -A "$PHOTO_MOUNT_SRC" 2>/dev/null)" ]] && _photo_empty=0
    echo ""
    echo "  !! EXISTING ZFS DATASET DETECTED"
    echo "  Dataset:  ${PHOTOS_DATASET}"
    echo "  Path:     ${PHOTO_MOUNT_SRC}"
    if [[ "$_photo_empty" -eq 0 ]]; then
      echo "  Content:  non-empty — existing Immich photo library found; it will be"
      echo "            bind-mounted as ${LIBRARY_DIR}. Files preserved, ownership NOT changed."
      echo "  Owner:    ${_owner} (must be 101000:101000 = CT uid 1000)"
    else
      echo "  Content:  empty dataset — ownership will be set to 101000:101000"
    fi
    echo ""
    read -r -p "  Attach this dataset to the new instance? [y/N]: " _pr <&8
    case "$_pr" in
      [yY][eE][sS]|[yY]) ;;
      *) echo "  Aborted." >&2; exit 1 ;;
    esac
    if [[ "$_photo_empty" -eq 0 ]]; then
      PHOTO_EXISTING=1
      [[ "$_owner" == "101000:101000" ]] || {
        echo "  ERROR: ${PHOTO_MOUNT_SRC} is owned by ${_owner}, expected 101000:101000." >&2
        echo "         Fix on the host first (verify the contents before any recursive chown):" >&2
        echo "         chown -R 101000:101000 ${PHOTO_MOUNT_SRC}" >&2
        exit 1
      }
    else
      chown 101000:101000 "$PHOTO_MOUNT_SRC"
      chmod 0755 "$PHOTO_MOUNT_SRC"
    fi
    unset _owner _photo_empty _pr
  fi
  echo "  Photo library: ${PHOTOS_DATASET} (${PHOTO_MOUNT_SRC}) → ${LIBRARY_DIR} (mp0)"
fi

# ── Generate DB password ──────────────────────────────────────────────────────
# Written only to the two EnvironmentFile= credential files (streamed over
# stdin, never in argv or .env).
set +o pipefail
DB_PASSWORD="$(head -c 4096 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 40)"
set -o pipefail
[[ ${#DB_PASSWORD} -eq 40 ]] || { echo "  ERROR: Failed to generate DB password." >&2; exit 1; }

# ── Template discovery & download ─────────────────────────────────────────────
pveam update

echo ""
TEMPLATE="$(pveam available -section system \
  | awk -v p="debian-${DEBIAN_VERSION}" -v a="$HOST_ARCH" \
      '$2 ~ ("^" p "-standard_") && $2 ~ ("_" a "\\.tar\\.(zst|gz|xz)$") {print $2}' \
  | sort -V | tail -n1)"
[[ -n "$TEMPLATE" ]] || {
  echo "  ERROR: No Debian ${DEBIAN_VERSION} template for host architecture ${HOST_ARCH} was found via pveam." >&2
  exit 1
}
echo "  Template: $TEMPLATE"

if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk -v v="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" '$1==v{found=1} END{exit(!found)}'; then
  echo "  Template already present: $TEMPLATE"
else
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

# ── Create LXC ────────────────────────────────────────────────────────────────
# Root password is set after start via chpasswd on stdin, keeping it out of
# the host process list (pct create -password exposes it in ps).
CT_FEATURES="nesting=1,keyctl=1"
[[ "$PODMAN_FUSE_OVERLAY" -eq 1 ]] && CT_FEATURES+=",fuse=1"

PCT_OPTIONS=(
  -hostname "$HN"
  -cores "$CPU"
  -memory "$RAM"
  -rootfs "${CONTAINER_STORAGE}:${DISK}"
  -onboot 1
  -ostype debian
  -arch "$HOST_ARCH"
  -unprivileged 1
  -features "$CT_FEATURES"
  -tags "$TAGS"
  -net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,ip6=manual"
)

pct create "$CT_ID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" "${PCT_OPTIONS[@]}"
CREATED=1

# Bind mount attached before first start; PVE creates the mount target inside
# the rootfs on start. Bind mounts are excluded from vzdump/PBS by design —
# the library is backed up externally (ZFS snapshots / external tools).
if [[ -n "$PHOTO_MOUNT_SRC" ]]; then
  pct set "$CT_ID" --mp0 "${PHOTO_MOUNT_SRC},mp=${LIBRARY_DIR}"
  echo "  Photos mount: ${PHOTO_MOUNT_SRC} -> ${LIBRARY_DIR} (CT ${CT_ID}, mp0)"
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

printf 'root:%s\n' "$PASSWORD" | pct exec "$CT_ID" -- chpasswd
unset PASSWORD PW1 PW2

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
PODMAN_FUSE_PKG=""
[[ "$PODMAN_FUSE_OVERLAY" -eq 1 ]] && PODMAN_FUSE_PKG="fuse-overlayfs"

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y locales curl ca-certificates iproute2 podman tar gzip ${PODMAN_FUSE_PKG}
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
OVERLAY_OPTIONS=""
if [[ "$PODMAN_FUSE_OVERLAY" -eq 1 ]]; then
  OVERLAY_OPTIONS='
[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"'
fi

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  mkdir -p /etc/containers

  cat > /etc/containers/storage.conf <<EOF2
[storage]
driver = \"overlay\"
runroot = \"/run/containers/storage\"
graphroot = \"/var/lib/containers/storage\"
${OVERLAY_OPTIONS}
EOF2

  cat > /etc/containers/containers.conf <<EOF2
[containers]
log_size_max = 10485760
EOF2
"

pct exec "$CT_ID" -- podman info >/dev/null 2>&1
pct exec "$CT_ID" -- podman --version

# Quadlet requires cgroup v2 and the overlay driver must actually be active
# (a silent fallback to vfs would work but eat disk and be very slow).
CGROUPS_VERSION="$(pct exec "$CT_ID" -- podman info --format '{{.Host.CgroupsVersion}}' 2>/dev/null || echo "?")"
[[ "$CGROUPS_VERSION" == "v2" ]] || { echo "  ERROR: Quadlet requires cgroup v2 inside the CT; podman reports '${CGROUPS_VERSION}'." >&2; exit 1; }
GRAPH_DRIVER="$(pct exec "$CT_ID" -- podman info --format '{{.Store.GraphDriverName}}' 2>/dev/null || echo "?")"
[[ "$GRAPH_DRIVER" == "overlay" ]] || { echo "  ERROR: Podman storage driver is '${GRAPH_DRIVER}', expected overlay." >&2; exit 1; }
echo "  Podman: cgroup ${CGROUPS_VERSION}, storage driver ${GRAPH_DRIVER}$([ "$PODMAN_FUSE_OVERLAY" -eq 1 ] && echo " (fuse-overlayfs)" || echo " (native)")"

# ── Pull images ───────────────────────────────────────────────────────────────
echo "  Pulling Immich image: ${APP_IMAGE} ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman pull '${APP_IMAGE}'
"

echo "  Pulling PostgreSQL image: ${POSTGRES_IMAGE} ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman pull '${POSTGRES_IMAGE}'
"

echo "  Pulling Valkey image: ${VALKEY_IMAGE} ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman pull '${VALKEY_IMAGE}'
"

# ── Prepare persistent paths ──────────────────────────────────────────────────
# Immich persistent state (all of it):
#   /opt/immich/postgres/   PostgreSQL cluster (→ /var/lib/postgresql/data). The
#                           image entrypoint starts as root and drops to postgres
#                           (uid 999, Debian-based image); it chowns the data dir
#                           itself, ownership is set here so the mode is 0700 from
#                           the start.
#   /opt/immich/config/     Immich config + ML model cache (→ /config), uid 1000
#                           (PUID/PGID — s6 init chowns on start too).
#   /opt/immich/library/    photo library (→ /photos), uid 1000. In rootfs mode
#                           created here; otherwise it is the mp0 bind mount whose
#                           ownership was set/verified on the host.
# Valkey holds only the BullMQ job queue; upstream Immich runs it without a
# volume, so no persistent path (jobs are re-queued by the server).
# Do not pre-create anything below these directories — the containers
# initialise their own subdirectories on first start.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  install -d -m 0755 '${APP_DIR}'
  install -d -m 0755 '${APP_DIR}/postgres-init'
  install -d -m 0700 -o 999 -g 999 '${APP_DIR}/postgres'
  install -d -m 0755 -o 1000 -g 1000 '${APP_DIR}/config'
  if [ -z '${PHOTO_MOUNT_SRC}' ]; then
    install -d -m 0755 -o 1000 -g 1000 '${LIBRARY_DIR}'
  else
    mountpoint -q '${LIBRARY_DIR}' || { echo '  ERROR: ${LIBRARY_DIR} is not a mount point inside the CT (mp0 missing?)' >&2; exit 1; }
    owner=\$(stat -c '%u:%g' '${LIBRARY_DIR}')
    [ \"\$owner\" = '1000:1000' ] || { echo \"  ERROR: ${LIBRARY_DIR} is seen as \$owner inside the CT, expected 1000:1000 (host must be 101000:101000)\" >&2; exit 1; }
  fi
  ls -ld '${APP_DIR}/postgres' '${APP_DIR}/config' '${LIBRARY_DIR}'
"

# ── PostgreSQL first-init script ──────────────────────────────────────────────
# Network=host would put PostgreSQL on every CT interface. The official
# entrypoint runs *.sql from /docker-entrypoint-initdb.d once, on an empty data
# directory; ALTER SYSTEM persists into postgresql.auto.conf and applies when
# the real server starts (listen_addresses needs a restart, which the init flow
# does anyway). The container command line is left untouched so the image's
# own VectorChord/shared_preload_libraries handling is not overridden.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > '${APP_DIR}/postgres-init/10-listen-localhost.sql' <<'EOF2'
-- managed by immich-quadlet.sh: bind PostgreSQL to loopback only (Network=host)
ALTER SYSTEM SET listen_addresses = '127.0.0.1';
EOF2
  chmod 0644 '${APP_DIR}/postgres-init/10-listen-localhost.sql'
"

# ── Valkey config ─────────────────────────────────────────────────────────────
# Loopback only on the shared host network. No persistence: the queue is
# rebuilt by Immich on start (matches the upstream compose, which mounts no
# volume). No maxmemory/eviction — evicting queue entries would drop jobs.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > '${APP_DIR}/valkey.conf' <<EOF2
bind 127.0.0.1
port 6379
protected-mode yes
save \"\"
appendonly no
loglevel warning
EOF2
  chmod 0644 '${APP_DIR}/valkey.conf'
"

# ── Quadlet unit files ────────────────────────────────────────────────────────
# Rootful Quadlet: /etc/containers/systemd/ — no linger, no --user flags needed.
# systemd daemon-reload triggers the Quadlet generator; three transient services
# are produced and WantedBy=multi-user.target handles boot start.
# Network=host bypasses Netavark NAT issues on Debian LXC; SERVER_PORT tells the
# app which port to bind instead of PublishPort=. All three containers share the
# CT network stack, so Immich reaches PostgreSQL and Valkey on 127.0.0.1.
# Backends carry HealthCmd= + Notify=healthy: their service only reports
# "started" once the health check passes, so Requires=/After= on immich.service
# is equivalent to compose's depends_on condition: service_healthy.
# Credentials live in postgres.env / immich.env (0600) via EnvironmentFile=,
# so the unit files contain no secrets and stay 0644.
DB_STORAGE_LINE=""
[[ "$POSTGRES_STORAGE_TYPE" == "HDD" ]] && DB_STORAGE_LINE="Environment=DB_STORAGE_TYPE=HDD"

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  mkdir -p '${QUADLET_DIR}'

  cat > '${POSTGRES_QUADLET_FILE}' <<EOF2
[Unit]
Description=PostgreSQL (VectorChord) for Immich
After=network-online.target
Wants=network-online.target

[Container]
Image=${POSTGRES_IMAGE}
ContainerName=immich-postgres
Network=host
Environment=TZ=${APP_TZ}
Environment=POSTGRES_USER=immich
Environment=POSTGRES_DB=immich
Environment=POSTGRES_INITDB_ARGS=--data-checksums
${DB_STORAGE_LINE}
EnvironmentFile=${POSTGRES_ENV_FILE}
Volume=${APP_DIR}/postgres:/var/lib/postgresql/data
Volume=${APP_DIR}/postgres-init:/docker-entrypoint-initdb.d:ro
ShmSize=128m
HealthCmd=pg_isready -U immich -d immich
HealthInterval=10s
HealthTimeout=5s
HealthRetries=5
HealthStartPeriod=60s
Notify=healthy
LogDriver=journald

[Service]
Restart=always
TimeoutStartSec=300
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF2

  cat > '${VALKEY_QUADLET_FILE}' <<EOF2
[Unit]
Description=Valkey for Immich (job queue)
After=network-online.target
Wants=network-online.target

[Container]
Image=${VALKEY_IMAGE}
ContainerName=immich-valkey
Network=host
Environment=TZ=${APP_TZ}
Exec=valkey-server /etc/valkey/valkey.conf
Volume=${APP_DIR}/valkey.conf:/etc/valkey/valkey.conf:ro
HealthCmd=valkey-cli -h 127.0.0.1 ping
HealthInterval=10s
HealthTimeout=5s
HealthRetries=3
HealthStartPeriod=10s
Notify=healthy
LogDriver=journald

[Service]
Restart=always
TimeoutStartSec=120
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF2

  cat > '${QUADLET_FILE}' <<EOF2
[Unit]
Description=Immich (imagegenius monolith)
After=network-online.target ${POSTGRES_QUADLET_SERVICE} ${VALKEY_QUADLET_SERVICE}
Wants=network-online.target
Requires=${POSTGRES_QUADLET_SERVICE} ${VALKEY_QUADLET_SERVICE}

[Container]
Image=${APP_IMAGE}
ContainerName=immich
Network=host
Environment=TZ=${APP_TZ}
Environment=PUID=1000
Environment=PGID=1000
Environment=DB_HOSTNAME=127.0.0.1
Environment=DB_PORT=5432
Environment=DB_USERNAME=immich
Environment=DB_DATABASE_NAME=immich
Environment=REDIS_HOSTNAME=127.0.0.1
Environment=REDIS_PORT=6379
Environment=SERVER_HOST=0.0.0.0
Environment=SERVER_PORT=${APP_PORT}
Environment=MACHINE_LEARNING_HOST=127.0.0.1
Environment=MACHINE_LEARNING_PORT=3003
EnvironmentFile=${APP_ENV_FILE}
Volume=${LIBRARY_DIR}:/photos
Volume=${APP_DIR}/config:/config
LogDriver=journald

[Service]
Restart=always
TimeoutStartSec=300
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF2

  chmod 0644 '${POSTGRES_QUADLET_FILE}' '${VALKEY_QUADLET_FILE}' '${QUADLET_FILE}'
"

# ── Container credentials files ───────────────────────────────────────────────
# Read by Quadlet via EnvironmentFile= (podman --env-file). Written UNQUOTED —
# podman keeps quotes as part of the value. Streamed over stdin so the password
# never appears in host or CT argv, and no temp file is created.
printf 'POSTGRES_PASSWORD=%s\n' "$DB_PASSWORD" | pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  umask 077
  cat > '${POSTGRES_ENV_FILE}'
  chmod 0600 '${POSTGRES_ENV_FILE}'
"
printf 'DB_PASSWORD=%s\n' "$DB_PASSWORD" | pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  umask 077
  cat > '${APP_ENV_FILE}'
  chmod 0600 '${APP_ENV_FILE}'
"
unset DB_PASSWORD

# ── Runtime state file ────────────────────────────────────────────────────────
# .env is not read by Quadlet or systemd. It is the maint script's source of
# truth for current image tags and policy flags. Keep it in sync with the
# Quadlet units whenever an image is updated. No secrets in here.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > '${APP_DIR}/.env' <<EOF2
APP_IMAGE_REPO=${APP_IMAGE_REPO}
APP_TAG=${APP_TAG}
APP_IMAGE=${APP_IMAGE}
POSTGRES_IMAGE_REPO=${POSTGRES_IMAGE_REPO}
POSTGRES_TAG=${POSTGRES_TAG}
POSTGRES_IMAGE=${POSTGRES_IMAGE}
VALKEY_IMAGE_REPO=${VALKEY_IMAGE_REPO}
VALKEY_TAG=${VALKEY_TAG}
VALKEY_IMAGE=${VALKEY_IMAGE}
APP_PORT=${APP_PORT}
APP_TZ=${APP_TZ}
APP_FQDN=${APP_FQDN}
PHOTO_STORAGE=${PHOTO_STORAGE}
PHOTO_MOUNT_SRC=${PHOTO_MOUNT_SRC}
AUTO_UPDATE=${AUTO_UPDATE}
EOF2
  chmod 0600 '${APP_DIR}/.env'
"

# ── Maintenance script ────────────────────────────────────────────────────────
# update <tag>:          Immich — pull → sed Image= in Quadlet file → sed .env →
#   daemon-reload → restart immich.service → /api/server/ping check; rollback
#   restores both files, daemon-reload, restart. Immich migrates the DB schema on
#   upgrade; a rolled-back image may refuse a migrated DB — that is what the
#   PVE snapshot / PBS backup is for.
# update-postgres <tag>: same flow for the DB unit; refuses a different PG major
#   (14- → 15- needs dump/restore). Immich is stopped around the DB restart.
# update-valkey <tag>:   same flow for the queue unit; Immich restarted after.
# auto-update:  re-pull ALL current tags (latest or pinned); restart only what
#   changed (backend change ⇒ Immich is stopped/started around it); rollback
#   re-tags the previous image IDs and restarts.
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/immich-maint.sh && chmod 0755 /usr/local/bin/immich-maint.sh' <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR="${APP_DIR:-/opt/immich}"
QUADLET_DIR="/etc/containers/systemd"
QUADLET_FILE="${QUADLET_DIR}/immich.container"
POSTGRES_QUADLET_FILE="${QUADLET_DIR}/immich-postgres.container"
VALKEY_QUADLET_FILE="${QUADLET_DIR}/immich-valkey.container"
SERVICE="immich.service"
POSTGRES_SERVICE="immich-postgres.service"
VALKEY_SERVICE="immich-valkey.service"
CONTAINER="immich"
POSTGRES_CONTAINER="immich-postgres"
VALKEY_CONTAINER="immich-valkey"
ENV_FILE="${APP_DIR}/.env"

need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF2
  Immich Maintenance (Quadlet)
  ────────────────────────────
  Usage:
    $0 update <tag> [--yes]            # Immich:     latest, or pin e.g. 3.1.0 / 3.1.0-noml
    $0 update-postgres <tag> [--yes]   # PostgreSQL: e.g. 14-vectorchord0.4.3-pgvectors0.2.0 (same major only)
    $0 update-valkey <tag> [--yes]     # Valkey:     latest, or pin e.g. 8.1.3
    $0 auto-update                     # re-pull current tags (only if AUTO_UPDATE=1)
    $0 version

  Notes:
    - update pulls the tag, updates the Quadlet unit and .env, restarts what is needed
    - auto-update is called by immich-update.timer; it never changes the tags
    - to switch between tracking and pinning: update latest / update <full version>
    - Immich migrates the database on upgrade — read the release notes first;
      a rollback after a migrated schema needs the PVE snapshot / PBS backup
    - PostgreSQL major changes (14- → 15-) are refused; they need a dump/restore
    - backup and restore are handled by PBS and PVE snapshots; the photo library
      (bind mount) is outside vzdump — back it up on the host (ZFS snapshot / external)
    - take a PVE snapshot before manual updates: pct snapshot <CT_ID> pre-update-\$(date +%Y%m%d)
EOF2
}

[[ -d "$APP_DIR" ]]               || die "APP_DIR not found: $APP_DIR"
[[ -f "$ENV_FILE" ]]              || die "Missing env file: $ENV_FILE"
[[ -f "$QUADLET_FILE" ]]          || die "Missing Quadlet unit: $QUADLET_FILE"
[[ -f "$POSTGRES_QUADLET_FILE" ]] || die "Missing Quadlet unit: $POSTGRES_QUADLET_FILE"
[[ -f "$VALKEY_QUADLET_FILE" ]]   || die "Missing Quadlet unit: $VALKEY_QUADLET_FILE"

# One maintenance operation at a time — a manual update must not overlap the timer.
LOCK_FILE="/run/lock/immich-maint.lock"
mkdir -p /run/lock
exec 9>"$LOCK_FILE"
flock -n 9 || die "Another immich-maint.sh operation is already running."

env_val() {
  awk -F= -v key="$1" '$1==key{print substr($0, length(key)+2)}' "$ENV_FILE" | tail -n1
}

env_flag() {
  local raw
  raw="$(env_val "$1" | tr -d '[:space:]')"
  [[ "$raw" =~ ^[01]$ ]] && printf '%s' "$raw" || printf '0'
}

app_port() {
  local port
  port="$(env_val APP_PORT | tr -d '[:space:]')"
  [[ "$port" =~ ^[0-9]+$ ]] && printf '%s' "$port" || printf '2283'
}

running_image_id() {
  podman inspect --format '{{.Image}}' "$1" 2>/dev/null || true
}

image_id_of() {
  podman image inspect --format '{{.Id}}' "$1" 2>/dev/null || true
}

image_digest_of() {
  podman image inspect --format '{{index .RepoDigests 0}}' "$1" 2>/dev/null || echo n/a
}

# /api/server/ping is answered by the Node server (200 + {"res":"pong"}) only
# once it is up and connected; the web UI is served by the same process.
# Generous window: first start after an upgrade runs DB migrations and reloads
# ML models.
wait_for_app() {
  local port code
  port="$(app_port)"
  for i in $(seq 1 120); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${port}/api/server/ping" 2>/dev/null || echo 000)"
    [[ "$code" == "200" ]] && return 0
    sleep 3
  done
  return 1
}

wait_for_postgres() {
  for i in $(seq 1 60); do
    podman exec "$POSTGRES_CONTAINER" pg_isready -q -U immich -d immich >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

wait_for_valkey() {
  local pong
  for i in $(seq 1 20); do
    pong="$(podman exec "$VALKEY_CONTAINER" valkey-cli -h 127.0.0.1 ping 2>/dev/null || true)"
    [[ "$pong" == "PONG" ]] && return 0
    sleep 2
  done
  return 1
}

wait_for_stack() {
  wait_for_postgres && wait_for_valkey && wait_for_app
}

confirm_or_exit() {
  echo ""
  echo "  IMPORTANT: Take a PVE snapshot before proceeding."
  echo "  Use: pct snapshot <CT_ID> pre-update-$(date +%Y%m%d)"
  echo "  (With an mp0 bind mount PVE may refuse the snapshot — snapshot the ZFS dataset / rely on PBS instead.)"
  echo ""
  read -r -p "  Continue? [y/N]: " confirm
  case "$confirm" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) echo "  Aborted."; return 1 ;;
  esac
}

# Restart the right units after an image change. A backend restart drops
# Immich's connections, so Immich is stopped first and started afterwards.
#   $1 = app | postgres | valkey | backends   (backends = both DB and queue)
restart_for() {
  case "$1" in
    app)      systemctl restart "$SERVICE" ;;
    postgres) systemctl stop "$SERVICE"; systemctl restart "$POSTGRES_SERVICE"; systemctl start "$SERVICE" ;;
    valkey)   systemctl stop "$SERVICE"; systemctl restart "$VALKEY_SERVICE";   systemctl start "$SERVICE" ;;
    backends) systemctl stop "$SERVICE"; systemctl restart "$POSTGRES_SERVICE"; systemctl restart "$VALKEY_SERVICE"; systemctl start "$SERVICE" ;;
    *) die "restart_for: unknown target $1" ;;
  esac
}

# Shared pinned-tag switch for one unit. Tag validation and app-specific guards
# are done by the callers; this function does the file/pull/restart/rollback flow.
#   $1 = app | postgres | valkey   $2 = new tag   $3 = 1 to skip the confirmation
switch_image() {
  local which="$1" new_tag="$2" skip_confirm="$3"
  local label key file old_tag repo old_image new_image old_id tmp_env tmp_quadlet
  case "$which" in
    app)      label="Immich";     key="APP";      file="$QUADLET_FILE" ;;
    postgres) label="PostgreSQL"; key="POSTGRES"; file="$POSTGRES_QUADLET_FILE" ;;
    valkey)   label="Valkey";     key="VALKEY";   file="$VALKEY_QUADLET_FILE" ;;
    *) die "switch_image: unknown target $which" ;;
  esac

  repo="$(env_val "${key}_IMAGE_REPO")"
  [[ -n "$repo" ]] || die "Could not read ${key}_IMAGE_REPO from .env"
  old_image="$(env_val "${key}_IMAGE")"
  [[ -n "$old_image" ]] || die "Could not read ${key}_IMAGE from .env"
  old_tag="${old_image##*:}"
  new_image="${repo}:${new_tag}"
  # Capture the current image ID before pulling: if new_tag == old_tag, the pull
  # moves the tag and the old ref would otherwise resolve to the NEW image on rollback.
  old_id="$(image_id_of "$old_image")"
  tmp_env="$(mktemp)"
  tmp_quadlet="$(mktemp)"

  echo "  Current ${label} tag: $old_tag"
  echo "  Target  ${label} tag: $new_tag"

  if [[ "$skip_confirm" -eq 0 ]]; then
    confirm_or_exit || { rm -f "$tmp_env" "$tmp_quadlet"; exit 0; }
  fi

  cp -a "$ENV_FILE" "$tmp_env"
  cp -a "$file"     "$tmp_quadlet"

  cleanup() { rm -f "$tmp_env" "$tmp_quadlet"; }
  rollback() {
    echo "  !! ${label} update failed — rolling back and restarting ..." >&2
    cp -a "$tmp_env"     "$ENV_FILE"
    cp -a "$tmp_quadlet" "$file"
    [[ -n "$old_id" ]] && podman tag "$old_id" "$old_image" >/dev/null 2>&1 || true
    systemctl daemon-reload
    restart_for "$which" || true
    rm -f "$tmp_env" "$tmp_quadlet"
    if wait_for_stack; then
      echo "  Rollback complete — ${old_image} is healthy again." >&2
    else
      echo "  CRITICAL: rollback to ${old_image} did not become healthy. Restore the CT from the PVE snapshot / PBS." >&2
      [[ "$which" == "app" ]] && echo "  (If the new Immich already migrated the database, the old image cannot run against it.)" >&2
    fi
  }
  trap rollback ERR

  echo "  Pulling target image ..."
  podman pull "$new_image"

  sed -i "s|^Image=.*|Image=${new_image}|" "$file"
  sed -i \
    -e "s|^${key}_TAG=.*|${key}_TAG=$new_tag|" \
    -e "s|^${key}_IMAGE=.*|${key}_IMAGE=$new_image|" \
    "$ENV_FILE"

  echo "  Reloading Quadlet and restarting ..."
  systemctl daemon-reload
  restart_for "$which"

  echo "  Waiting for the stack ..."
  if ! wait_for_stack; then
    trap - ERR
    rollback
    die "Stack did not become healthy after ${label} update."
  fi

  trap - ERR
  cleanup
  if [[ -n "$old_id" && "$old_id" != "$(image_id_of "$new_image")" ]]; then
    podman rmi "$old_id" >/dev/null 2>&1 || true
  fi
  echo "  OK: ${label} updated to $new_tag"
}

parse_update_args() {
  # sets NEW_TAG and SKIP_CONFIRM from "$@"
  NEW_TAG=""; SKIP_CONFIRM=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) SKIP_CONFIRM=1; shift ;;
      *) NEW_TAG="$1"; shift ;;
    esac
  done
}

# update <tag> [--yes] — switch Immich to "latest" or a pinned version
update_app() {
  parse_update_args "$@"
  [[ -n "$NEW_TAG" ]] || die "Usage: immich-maint.sh update <tag>"
  [[ "$NEW_TAG" == "latest" || "$NEW_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-noml)?$ ]] \
    || die "Invalid tag: $NEW_TAG — use 'latest' or a full version like 3.1.0 / 3.1.0-noml (floating 3, 3.1, noml are not accepted)."
  echo "  NOTE: Immich applies database migrations on upgrade. Read the release notes"
  echo "        (breaking changes, required PostgreSQL image) before continuing."
  switch_image app "$NEW_TAG" "$SKIP_CONFIRM"
}

# update-postgres <tag> [--yes] — switch the DB image within the same PostgreSQL major
update_postgres() {
  parse_update_args "$@"
  [[ -n "$NEW_TAG" ]] || die "Usage: immich-maint.sh update-postgres <tag>"
  [[ "$NEW_TAG" =~ ^[0-9]{2}-vectorchord[0-9]+\.[0-9]+\.[0-9]+(-pgvectors[0-9]+\.[0-9]+\.[0-9]+)?$ ]] \
    || die "Invalid tag: $NEW_TAG — expected e.g. 14-vectorchord0.4.3-pgvectors0.2.0 (from Immich release notes)."
  local cur_tag cur_major new_major
  cur_tag="$(env_val POSTGRES_TAG)"
  cur_major="${cur_tag%%-*}"
  new_major="${NEW_TAG%%-*}"
  [[ "$cur_major" == "$new_major" ]] \
    || die "PostgreSQL major change ${cur_major} → ${new_major} is not handled here: it needs a pg_dumpall/restore into a fresh data directory. Aborting."
  echo "  NOTE: VectorChord/pgvectors bumps must match what the running Immich version"
  echo "        expects — check the Immich release notes before continuing."
  switch_image postgres "$NEW_TAG" "$SKIP_CONFIRM"
}

# update-valkey <tag> [--yes] — switch the queue backend to "latest" or a pinned version
update_valkey() {
  parse_update_args "$@"
  [[ -n "$NEW_TAG" ]] || die "Usage: immich-maint.sh update-valkey <tag>"
  [[ "$NEW_TAG" == "latest" || "$NEW_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] \
    || die "Invalid tag: $NEW_TAG — use 'latest' or a full version like 8.1.3."
  switch_image valkey "$NEW_TAG" "$SKIP_CONFIRM"
}

# auto-update — re-pull the current tags (latest or pinned); restart only what changed
auto_update_app() {
  if [[ "$(env_flag AUTO_UPDATE)" != "1" ]]; then
    echo "  Auto-update disabled in ${ENV_FILE}; nothing to do."
    return 0
  fi

  local app_image pg_image vk_image app_old_id pg_old_id vk_old_id app_new_id pg_new_id vk_new_id
  app_image="$(env_val APP_IMAGE)";      [[ -n "$app_image" ]] || die "Could not read APP_IMAGE from .env"
  pg_image="$(env_val POSTGRES_IMAGE)";  [[ -n "$pg_image" ]]  || die "Could not read POSTGRES_IMAGE from .env"
  vk_image="$(env_val VALKEY_IMAGE)";    [[ -n "$vk_image" ]]  || die "Could not read VALKEY_IMAGE from .env"
  app_old_id="$(running_image_id "$CONTAINER")"
  pg_old_id="$(running_image_id "$POSTGRES_CONTAINER")"
  vk_old_id="$(running_image_id "$VALKEY_CONTAINER")"

  echo "  Auto-update: re-pulling ${pg_image} ..."
  podman pull "$pg_image"
  pg_new_id="$(image_id_of "$pg_image")";   [[ -n "$pg_new_id" ]]  || die "Could not inspect pulled image ${pg_image}"
  echo "  Auto-update: re-pulling ${vk_image} ..."
  podman pull "$vk_image"
  vk_new_id="$(image_id_of "$vk_image")";   [[ -n "$vk_new_id" ]]  || die "Could not inspect pulled image ${vk_image}"
  echo "  Auto-update: re-pulling ${app_image} ..."
  podman pull "$app_image"
  app_new_id="$(image_id_of "$app_image")"; [[ -n "$app_new_id" ]] || die "Could not inspect pulled image ${app_image}"

  local app_changed=0 pg_changed=0 vk_changed=0
  [[ -z "$app_old_id" || "$app_new_id" != "$app_old_id" ]] && app_changed=1
  [[ -z "$pg_old_id"  || "$pg_new_id"  != "$pg_old_id"  ]] && pg_changed=1
  [[ -z "$vk_old_id"  || "$vk_new_id"  != "$vk_old_id"  ]] && vk_changed=1

  if [[ "$app_changed" -eq 0 && "$pg_changed" -eq 0 && "$vk_changed" -eq 0 ]]; then
    echo "  OK: all images are already current — no restart needed."
    return 0
  fi

  local target="app"
  if   [[ "$pg_changed" -eq 1 && "$vk_changed" -eq 1 ]]; then target="backends"
  elif [[ "$pg_changed" -eq 1 ]]; then target="postgres"
  elif [[ "$vk_changed" -eq 1 ]]; then target="valkey"
  fi

  rollback() {
    echo "  !! Auto-update failed — restoring previous images and restarting ..." >&2
    [[ "$app_changed" -eq 1 && -n "$app_old_id" ]] && podman tag "$app_old_id" "$app_image" >/dev/null 2>&1 || true
    [[ "$pg_changed"  -eq 1 && -n "$pg_old_id"  ]] && podman tag "$pg_old_id"  "$pg_image"  >/dev/null 2>&1 || true
    [[ "$vk_changed"  -eq 1 && -n "$vk_old_id"  ]] && podman tag "$vk_old_id"  "$vk_image"  >/dev/null 2>&1 || true
    restart_for "$target" || true
    if wait_for_stack; then
      echo "  Rollback complete — previous images are healthy again." >&2
    else
      echo "  CRITICAL: rollback did not become healthy. Restore the CT from the PVE snapshot / PBS." >&2
      [[ "$app_changed" -eq 1 ]] && echo "  (If the new Immich already migrated the database, the old image cannot run against it.)" >&2
    fi
  }
  trap rollback ERR

  echo "  Changed — Immich: ${app_changed}, PostgreSQL: ${pg_changed}, Valkey: ${vk_changed}; restarting (${target}) ..."
  restart_for "$target"

  echo "  Waiting for the stack ..."
  if ! wait_for_stack; then
    trap - ERR
    rollback
    die "Stack did not become healthy after auto-update."
  fi

  trap - ERR
  [[ "$app_changed" -eq 1 && -n "$app_old_id" ]] && podman rmi "$app_old_id" >/dev/null 2>&1 || true
  [[ "$pg_changed"  -eq 1 && -n "$pg_old_id"  ]] && podman rmi "$pg_old_id"  >/dev/null 2>&1 || true
  [[ "$vk_changed"  -eq 1 && -n "$vk_old_id"  ]] && podman rmi "$vk_old_id"  >/dev/null 2>&1 || true
  echo "  OK: Immich stack refreshed (Immich changed: ${app_changed}, PostgreSQL changed: ${pg_changed}, Valkey changed: ${vk_changed})"
}

need_root
cmd="${1:-}"
case "$cmd" in
  update)          shift; update_app "$@" ;;
  update-postgres) shift; update_postgres "$@" ;;
  update-valkey)   shift; update_valkey "$@" ;;
  auto-update)     auto_update_app ;;
  version)
    # With "latest" the tag carries no version info; the digest identifies the build.
    echo "Configured Immich image:     $(env_val APP_IMAGE)"
    echo "Running Immich image ID:     $(running_image_id "$CONTAINER")"
    echo "Immich digest:               $(image_digest_of "$(env_val APP_IMAGE)")"
    echo "Immich server version:       $(curl -s --max-time 3 "http://127.0.0.1:$(app_port)/api/server/version" 2>/dev/null || echo n/a)"
    echo "Configured PostgreSQL image: $(env_val POSTGRES_IMAGE)"
    echo "Running PostgreSQL image ID: $(running_image_id "$POSTGRES_CONTAINER")"
    echo "Configured Valkey image:     $(env_val VALKEY_IMAGE)"
    echo "Running Valkey image ID:     $(running_image_id "$VALKEY_CONTAINER")"
    echo "AUTO_UPDATE=$(env_flag AUTO_UPDATE)"
    ;;
  ""|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
MAINT
echo "  Maintenance script deployed: /usr/local/bin/immich-maint.sh"

# ── Start via Quadlet ─────────────────────────────────────────────────────────
# daemon-reload triggers the Quadlet generator which produces immich.service,
# immich-postgres.service and immich-valkey.service as transient systemd units.
# WantedBy=multi-user.target handles boot restarts. Transient units cannot be
# systemctl-enabled; daemon-reload is sufficient. Starting immich.service pulls
# in both backends via Requires= and waits for their health checks (Notify=healthy)
# before the app container is created. First DB init + Immich migrations +
# ML model download can take a few minutes.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  systemctl daemon-reload
  systemctl start '${QUADLET_SERVICE}'
"

# ── Disarm destructive cleanup ────────────────────────────────────────────────
CLEANUP_ON_FAIL=0

# ── Verification ──────────────────────────────────────────────────────────────
sleep 3
VERIFY_FAIL=0

for svc in "$POSTGRES_QUADLET_SERVICE" "$VALKEY_QUADLET_SERVICE" "$QUADLET_SERVICE"; do
  if pct exec "$CT_ID" -- systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo "  Quadlet service is active: ${svc}"
  else
    echo "  ERROR: ${svc} is not active" >&2
    echo "  Check: pct exec $CT_ID -- systemctl status ${svc}" >&2
    echo "  Check: pct exec $CT_ID -- journalctl -u ${svc} --no-pager -n 50" >&2
    VERIFY_FAIL=1
  fi
done

RUNNING=0
for i in $(seq 1 60); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc \
    'podman ps --filter name=^immich$ --filter name=^immich-postgres$ --filter name=^immich-valkey$ --format "{{.Names}}" 2>/dev/null | wc -l' \
    2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge 3 ]] && break
  sleep 2
done
pct exec "$CT_ID" -- bash -lc 'podman ps' || true

if [[ "$RUNNING" -lt 3 ]]; then
  echo "  ERROR: Expected 3 containers running (immich, immich-postgres, immich-valkey), found $RUNNING" >&2
  VERIFY_FAIL=1
else
  echo "  Container count OK ($RUNNING running)"
fi

if pct exec "$CT_ID" -- sh -lc 'podman exec immich-postgres pg_isready -q -U immich -d immich' >/dev/null 2>&1; then
  echo "  PostgreSQL accepts connections (pg_isready)"
else
  echo "  ERROR: PostgreSQL is not ready (pg_isready failed)" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u immich-postgres.service --no-pager -n 50" >&2
  VERIFY_FAIL=1
fi

VK_PONG="$(pct exec "$CT_ID" -- sh -lc 'podman exec immich-valkey valkey-cli -h 127.0.0.1 ping 2>/dev/null' 2>/dev/null || true)"
if [[ "$VK_PONG" == "PONG" ]]; then
  echo "  Valkey responds on 127.0.0.1:6379 (PONG)"
else
  echo "  ERROR: Valkey did not answer PING on 127.0.0.1:6379" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u immich-valkey.service --no-pager -n 50" >&2
  VERIFY_FAIL=1
fi

# Both backends must be loopback-only on the shared host network. The PostgreSQL
# binding comes from the first-init ALTER SYSTEM; if it did not apply, the DB
# would be reachable from the whole LAN with only the password protecting it.
PG_LISTEN="$(pct exec "$CT_ID" -- sh -lc 'ss -tlnH 2>/dev/null | awk "\$4 ~ /:5432\$/ {print \$4}" | sort -u | paste -sd, -' 2>/dev/null || true)"
VK_LISTEN="$(pct exec "$CT_ID" -- sh -lc 'ss -tlnH 2>/dev/null | awk "\$4 ~ /:6379\$/ {print \$4}" | sort -u | paste -sd, -' 2>/dev/null || true)"
if [[ "$PG_LISTEN" == "127.0.0.1:5432" ]]; then
  echo "  PostgreSQL listens on loopback only (${PG_LISTEN})"
else
  echo "  ERROR: PostgreSQL listener is '${PG_LISTEN:-none}', expected exactly 127.0.0.1:5432" >&2
  echo "  Check: pct exec $CT_ID -- podman exec immich-postgres cat /var/lib/postgresql/data/postgresql.auto.conf" >&2
  VERIFY_FAIL=1
fi
if [[ "$VK_LISTEN" == "127.0.0.1:6379" ]]; then
  echo "  Valkey listens on loopback only (${VK_LISTEN})"
else
  echo "  ERROR: Valkey listener is '${VK_LISTEN:-none}', expected exactly 127.0.0.1:6379" >&2
  VERIFY_FAIL=1
fi

# /api/server/ping returns 200 {"res":"pong"} once the server is up and connected
# to DB + queue. First start runs migrations and downloads ML models — allow time.
IM_HEALTHY=0
for i in $(seq 1 120); do
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc "curl -s -o /dev/null -w '%{http_code}' --max-time 3 'http://127.0.0.1:${APP_PORT}/api/server/ping' 2>/dev/null" 2>/dev/null || echo 000)"
  case "$HTTP_CODE" in
    200)
      IM_HEALTHY=1
      break
      ;;
  esac
  sleep 3
done

if [[ "$IM_HEALTHY" -eq 1 ]]; then
  echo "  Immich health check passed (HTTP $HTTP_CODE)"
else
  echo "  ERROR: Immich /api/server/ping did not return 200 on port ${APP_PORT}" >&2
  echo "  Check: pct exec $CT_ID -- systemctl status immich.service" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u immich.service --no-pager -n 80" >&2
  VERIFY_FAIL=1
fi

if (( VERIFY_FAIL == 1 )); then
  echo "" >&2
  echo "  FATAL: Core verification failed — CT $CT_ID is preserved but the install is incomplete." >&2
  echo "  Inspect the container and fix manually, or destroy and re-run." >&2
  if [[ -n "$PHOTO_MOUNT_SRC" ]]; then
    echo "  The host photo path ${PHOTO_MOUNT_SRC} was NOT touched by the failure and is safe to re-attach." >&2
  fi
  exit 1
fi

# ── Auto-update timer (policy-driven) ─────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
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
OnCalendar=*-*-* ${UPDATE_TIME}:00
Persistent=true

[Install]
WantedBy=timers.target
EOF2

  systemctl daemon-reload
"
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
  if ! sysctl --system >/dev/null 2>&1; then
    echo "  WARNING: sysctl --system reported errors — some keys may be read-only in this unprivileged CT:" >&2
    sysctl --system 2>&1 | grep -i "error\|permission" >&2 || true
  fi
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
printf '\\n  Immich (Podman/Quadlet)\\n'
printf '  ────────────────────────────────────\\n'
MOTD

  cat > /etc/update-motd.d/10-sysinfo <<'MOTD'
#!/bin/sh
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '  Hostname:  %s\\n' \"\$(hostname)\"
printf '  IP:        %s\\n' \"\${ip:-n/a}\"
printf '  Uptime:    %s\\n' \"\$(uptime -p 2>/dev/null || uptime)\"
printf '  Disk:      %s\\n' \"\$(df -h / | awk 'NR==2{printf \"%s/%s (%s used)\", \$3, \$2, \$5}')\"
MOTD

  cat > /etc/update-motd.d/30-app <<'MOTD'
#!/bin/sh
running=\$(podman ps --filter name=^immich$ --filter name=^immich-postgres$ --filter name=^immich-valkey$ --format '{{.Names}}' 2>/dev/null | wc -l)
svc_status=\$(systemctl is-active immich.service 2>/dev/null); svc_status=\${svc_status:-unknown}
pg_status=\$(systemctl is-active immich-postgres.service 2>/dev/null); pg_status=\${pg_status:-unknown}
vk_status=\$(systemctl is-active immich-valkey.service 2>/dev/null); vk_status=\${vk_status:-unknown}
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
image=\$(awk -F= '/^APP_IMAGE=/{print \$2}' /opt/immich/.env 2>/dev/null | tail -n1)
pg_image=\$(awk -F= '/^POSTGRES_IMAGE=/{print \$2}' /opt/immich/.env 2>/dev/null | tail -n1)
vk_image=\$(awk -F= '/^VALKEY_IMAGE=/{print \$2}' /opt/immich/.env 2>/dev/null | tail -n1)
auto=\$(awk -F= '/^AUTO_UPDATE=/{print \$2}' /opt/immich/.env 2>/dev/null | tail -n1)
fqdn=\$(awk -F= '/^APP_FQDN=/{print \$2}' /opt/immich/.env 2>/dev/null | tail -n1)
src=\$(awk -F= '/^PHOTO_MOUNT_SRC=/{print \$2}' /opt/immich/.env 2>/dev/null | tail -n1)
port=\$(awk -F= '/^APP_PORT=/{print \$2}' /opt/immich/.env 2>/dev/null | tail -n1)
port=\${port:-2283}
lib_use=\$(df -h /opt/immich/library 2>/dev/null | awk 'NR==2{printf \"%s/%s (%s used)\", \$3, \$2, \$5}')
printf '  Containers: immich + immich-postgres + immich-valkey (%s running)\\n' \"\$running\"
printf '  Services:   immich.service (%s) | postgres (%s) | valkey (%s)\\n' \"\$svc_status\" \"\$pg_status\" \"\$vk_status\"
printf '  Image:      %s\\n' \"\${image:-n/a}\"
printf '  Postgres:   %s (127.0.0.1:5432)\\n' \"\${pg_image:-n/a}\"
printf '  Valkey:     %s (127.0.0.1:6379, no persistence)\\n' \"\${vk_image:-n/a}\"
printf '  Policy:     %s\\n' \"\$([ \"\$auto\" = '1' ] && echo 'auto-update daily (re-pull current tags)' || echo 'manual updates only')\"
printf '  Library:    /opt/immich/library %s\\n' \"\$([ -n \"\$src\" ] && echo \"<- host \$src (mp0)\" || echo '(rootfs)')\"
printf '              %s\\n' \"\${lib_use:-n/a}\"
printf '  Data:       /opt/immich/postgres  /opt/immich/config (ML cache)\\n'
printf '  Logs:       journalctl -u immich.service -f\\n'
printf '  Maintain:   /usr/local/bin/immich-maint.sh [update|update-postgres|update-valkey|auto-update|version]\\n'
printf '  Updates:    systemctl status immich-update.timer\\n'
if [ -n \"\$fqdn\" ]; then
  printf '  Web UI:     https://%s/\\n' \"\$fqdn\"
fi
printf '  Web UI:     http://%s:%s/\\n' \"\${ip:-n/a}\" \"\$port\"
printf '  Health:     http://%s:%s/api/server/ping\\n' \"\${ip:-n/a}\" \"\$port\"
printf '\\n'
printf '  Post-setup: first registered user becomes admin; ML models load on first\\n'
printf '              use (cold start takes minutes). Admin -> Settings -> Server -> External domain.\\n'
printf '              NPM: Websockets on; client_max_body_size 0; proxy_read/send_timeout 600s; proxy_buffering off.\\n'
MOTD

  cat > /etc/update-motd.d/99-footer <<'MOTD'
#!/bin/sh
printf '  ────────────────────────────────────\\n\\n'
MOTD

  chmod +x /etc/update-motd.d/*
"

pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Proxmox UI description ────────────────────────────────────────────────────
IM_DESC_LINK="http://${CT_IP}:${APP_PORT}/"
IM_DESC_LABEL="Immich (local)"
if [[ -n "$APP_FQDN" ]]; then
  IM_DESC_LINK="https://${APP_FQDN}/"
  IM_DESC_LABEL="Immich (public)"
fi
IM_DESC="<a href='${IM_DESC_LINK}' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>${IM_DESC_LABEL}</a>
<details><summary>Details</summary>Immich (Podman/Quadlet, imagegenius monolith) on Debian ${DEBIAN_VERSION} LXC
Tag: ${APP_TAG} | Postgres: ${POSTGRES_TAG} | Valkey: ${VALKEY_TAG}
Library: $([ -n "$PHOTO_MOUNT_SRC" ] && echo "${PHOTO_MOUNT_SRC} (mp0)" || echo "rootfs")
Created by immich-quadlet.sh</details>"
pct set "$CT_ID" --description "$IM_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "    CT: $CT_ID | IP: ${CT_IP} | Web UI: http://${CT_IP}:${APP_PORT}/"
if [[ -n "$APP_FQDN" ]]; then
  echo "    Public:   https://${APP_FQDN}/"
fi
echo "    Image:    ${APP_IMAGE}"
echo "    Postgres: ${POSTGRES_IMAGE} (127.0.0.1:5432, data: ${APP_DIR}/postgres)"
echo "    Valkey:   ${VALKEY_IMAGE} (127.0.0.1:6379, job queue, no persistence)"
echo "    Quadlet:  ${QUADLET_FILE}"
echo "              ${POSTGRES_QUADLET_FILE}"
echo "              ${VALKEY_QUADLET_FILE}"
echo "    Secrets:  ${POSTGRES_ENV_FILE}  ${APP_ENV_FILE}  (0600, DB password)"
echo "    Config:   ${APP_DIR}/config  (Immich config + ML model cache)"
if [[ -n "$PHOTO_MOUNT_SRC" ]]; then
  echo "    Library:  ${LIBRARY_DIR} <- ${PHOTO_MOUNT_SRC} (mp0$([ -n "$PHOTOS_DATASET" ] && echo ", dataset ${PHOTOS_DATASET}"))"
else
  echo "    Library:  ${LIBRARY_DIR} (rootfs — set PHOTO_STORAGE for a production library)"
fi
echo "    Policy:   $([ "$AUTO_UPDATE" -eq 1 ] && echo "auto-update daily at ${UPDATE_TIME} (re-pull ${APP_TAG} / ${POSTGRES_TAG} / ${VALKEY_TAG})" || echo "manual updates only (${APP_TAG} / ${POSTGRES_TAG} / ${VALKEY_TAG})")"
echo ""
if [[ "$PHOTO_EXISTING" -eq 1 ]]; then
  echo "    !! Existing photo library attached. Verify it in the web UI after first login;"
  echo "       if assets are missing: Administration -> Jobs -> Library -> Scan All."
  echo "       (A library from a different Immich instance without its database is NOT"
  echo "        re-imported automatically — the DB in ${APP_DIR}/postgres is new.)"
  echo ""
fi
echo "    pct exec $CT_ID -- systemctl status immich.service"
echo "    pct exec $CT_ID -- journalctl -u immich.service --no-pager -n 50"
echo "    pct exec $CT_ID -- /usr/local/bin/immich-maint.sh update <tag>           # latest, or pin e.g. 3.1.0 / 3.1.0-noml"
echo "    pct exec $CT_ID -- /usr/local/bin/immich-maint.sh update-postgres <tag>  # same PG major only, per Immich release notes"
echo "    pct exec $CT_ID -- /usr/local/bin/immich-maint.sh update-valkey <tag>    # latest, or pin e.g. 8.1.3"
echo "    pct exec $CT_ID -- /usr/local/bin/immich-maint.sh auto-update            # re-pull current tags now (if AUTO_UPDATE=1)"
echo "    pct exec $CT_ID -- /usr/local/bin/immich-maint.sh version"
echo "    Backup/restore: PBS + PVE snapshots cover the CT (DB, config)."
if [[ -n "$PHOTO_MOUNT_SRC" ]]; then
  echo "                    The library bind mount (mp0) is outside vzdump — back up ${PHOTO_MOUNT_SRC} on the host"
  echo "                    (ZFS snapshots / external tool). PVE may refuse CT snapshots while mp0 is attached."
fi
echo ""
echo "    First visit: register the first user — it becomes the admin account."
echo "    ML models are downloaded into ${APP_DIR}/config on first use — the first search/face job takes minutes."
echo "    Admin -> Settings -> Server -> External domain: set to https://${APP_FQDN:-<your-domain>}"
echo "    NPM proxy host: http | ${CT_IP}:${APP_PORT} | enable Websockets Support; Advanced -> Custom Nginx Configuration:"
echo "      client_max_body_size 0;"
echo "      proxy_read_timeout 600s;"
echo "      proxy_send_timeout 600s;"
echo "      proxy_buffering off;"
echo "    Port ${APP_PORT} listens on all CT interfaces (Network=host) — restrict with the PVE firewall if needed."
echo "    PostgreSQL (5432), Valkey (6379) and the ML service (3003) are bound to 127.0.0.1 inside the CT."
if [[ "$PODMAN_FUSE_OVERLAY" -eq 1 ]]; then
  echo "    Backups: fuse=1 + fuse-overlayfs can deadlock under snapshot-mode vzdump/PBS (freezer)."
  echo "             Use stop-mode backups for this CT, or test PODMAN_FUSE_OVERLAY=0."
fi
echo "    Extra config (env vars, HW transcoding devices): edit ${QUADLET_FILE}, then systemctl daemon-reload && systemctl restart immich.service"
echo ""
