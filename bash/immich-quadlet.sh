#!/usr/bin/env bash
set -Eeo pipefail
umask 022
export LC_ALL=C
# Safety revision: 2026-09-11. Fresh Proxmox CT creator; maintenance runs inside the CT.

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
APP_TAG="3.1.0"                      # full version (optionally -noml), only; floating 3 / 3.1 / noml are rejected
# PostgreSQL with VectorChord — Immich requires this image family. Take the tag
# from the Immich release notes; a different major (14- → 15-) needs a dump/restore
# and is refused by the maint script.
POSTGRES_IMAGE_REPO="ghcr.io/immich-app/postgres"
POSTGRES_TAG="14-vectorchord0.4.3-pgvectors0.2.0"
POSTGRES_STORAGE_TYPE="SSD"          # SSD | HDD — HDD sets DB_STORAGE_TYPE=HDD (random_page_cost tuning in the image)
# Valkey (job queue): Immich upstream ships valkey:8-bookworm; pinned to a full 8.x here.
VALKEY_IMAGE_REPO="docker.io/valkey/valkey"
VALKEY_TAG="8.1.3"                   # full version like 8.1.3, only; floating majors (8, 8.1) are rejected
DEBIAN_VERSION=13

# Auto-update policy
# AUTO_UPDATE=0 (default): timer installed but disabled; manual updates via
#   immich-maint.sh update <tag> / update-postgres <tag> / update-valkey <tag>
# AUTO_UPDATE=1: immich-update.timer re-pulls the CURRENT pinned tags
#   daily at UPDATE_TIME and restarts only what changed; a failed health check
#   reports failure and retains the target. Immich runs DB migrations on upgrade —
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


# Service verification and in-CT firewall
INITIAL_WAIT_SECONDS=600
UPDATE_WAIT_SECONDS=1800             # permit migrations; a timeout does not stop the app
# Bare IPs (192.168.1.20) or network CIDRs (192.168.1.0/24).
# Empty array prompts before CT creation; pressing Enter allows any source
# on APP_PORT (IPv4/IPv6). UFW stays enabled. Set client/NPM sources to restrict.
UFW_ALLOWED_SOURCES=()
SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/immich-quadlet.sh"
SCRIPT_LOCAL="/root/immich-quadlet.sh"

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
#   /usr/local/sbin/immich-ufw-check                  (service-start firewall guard)
#   /etc/default/ufw, /etc/ufw/ufw.conf               (in-CT IPv4/IPv6 policy)
#   /etc/ufw/user.rules, /etc/ufw/user6.rules         (configured source allows)
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
[[ "$CPU" =~ ^(0|[1-9][0-9]*)$ ]] && (( CPU >= 1 )) || { echo "  ERROR: CPU must be a positive integer." >&2; exit 1; }
[[ "$RAM" =~ ^(0|[1-9][0-9]*)$ ]] && (( RAM >= 256 )) || { echo "  ERROR: RAM must be >= 256 MB." >&2; exit 1; }
[[ "$DISK" =~ ^(0|[1-9][0-9]*)$ ]] && (( DISK >= 1 )) || { echo "  ERROR: DISK must be >= 1 GB." >&2; exit 1; }
[[ "$DEBIAN_VERSION" == 13 ]] || { echo "  ERROR: This creator requires Debian 13." >&2; exit 1; }
[[ "$APP_PORT" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "  ERROR: APP_PORT must be numeric." >&2; exit 1; }
(( APP_PORT >= 1024 && APP_PORT <= 65535 )) || { echo "  ERROR: APP_PORT must be between 1024 and 65535." >&2; exit 1; }
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
# Immich: pinned full semver with optional -noml (3.1.0, 3.1.0-noml). Floating
# majors (3, 3.1) and bare variant tags (noml, cuda, openvino) are rejected — they
# hide which line is running without the simplicity of "latest".
[[ "$APP_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-noml)?$ ]] || {
  echo "  ERROR: APP_TAG must be a pinned full version like 3.1.0 / 3.1.0-noml (floating tags like 3, 3.1 or noml are not accepted)." >&2
  exit 1
}
# PostgreSQL: <major>-vectorchord<ver>[-pgvectors<ver>] exactly as published by immich-app.
[[ "$POSTGRES_TAG" =~ ^14-vectorchord[0-9]+\.[0-9]+\.[0-9]+(-pgvectors[0-9]+\.[0-9]+\.[0-9]+)?$ ]] || {
  echo "  ERROR: POSTGRES_TAG must look like 14-vectorchord0.4.3-pgvectors0.2.0 (see Immich release notes)." >&2
  exit 1
}
# Valkey: pinned full semver (8.1.3, 8.1.3-bookworm). Floating majors (8, 8.1) are rejected.
[[ "$VALKEY_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: VALKEY_TAG must be a pinned full version like 8.1.3 (floating tags like 8 are not accepted)." >&2
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


for wait_var in INITIAL_WAIT_SECONDS UPDATE_WAIT_SECONDS; do
  [[ ${!wait_var} =~ ^[1-9][0-9]{1,4}$ ]] && (( ${!wait_var} >= 30 && ${!wait_var} <= 86400 )) \
    || { echo "ERROR: $wait_var must be 30..86400 seconds." >&2; exit 1; }
done
[[ $UPDATE_TIME =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "ERROR: Invalid UPDATE_TIME." >&2; exit 1; }

# ── Trap cleanup ──────────────────────────────────────────────────────────────
trap 'rc=$?;
  trap - ERR
  echo "  ERROR: failed (rc=$rc) near line ${LINENO:-?}" >&2
  echo "  Command: $BASH_COMMAND" >&2
  if [[ "${CLEANUP_ON_FAIL:-0}" -eq 1 && "${CREATED:-0}" -eq 1 ]]; then
    echo "  Cleanup: stopping/destroying CT ${CT_ID} ..." >&2
    pct stop "${CT_ID}" >/dev/null 2>&1 || true
    pct destroy "${CT_ID}" >/dev/null 2>&1 || true
  fi
  [[ -z ${PHOTO_MOUNT_SRC:-} ]] || echo "  External photo path retained: ${PHOTO_MOUNT_SRC}" >&2
  exit "$rc"
' ERR

trap 'rc=130;
  trap - ERR INT TERM HUP
  echo "  Interrupted (rc=$rc)" >&2
  echo "  Command: $BASH_COMMAND" >&2
  if [[ "${CLEANUP_ON_FAIL:-0}" -eq 1 && "${CREATED:-0}" -eq 1 ]]; then
    echo "  Cleanup: stopping/destroying CT ${CT_ID} ..." >&2
    pct stop "${CT_ID}" >/dev/null 2>&1 || true
    pct destroy "${CT_ID}" >/dev/null 2>&1 || true
  fi
  [[ -z ${PHOTO_MOUNT_SRC:-} ]] || echo "  External photo path retained: ${PHOTO_MOUNT_SRC}" >&2
  exit "$rc"
' INT TERM HUP

# ── Preflight — root & commands ───────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pvesh pveam pct pvesm qm curl python3 ip awk grep sed sort paste seq readlink cp chmod chown stat dpkg head tr ls mkdir flock mktemp mv rm tail bash timeout; do
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
# Serialize this creator before assigning an ID or checking its hostname.
exec 7>/run/lock/immich-creator.lock
flock -n 7 || { echo "ERROR: Another immich creator is running." >&2; exit 1; }

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

[[ -t 8 ]] || { echo "ERROR: Prompt input must be a terminal." >&2; exit 1; }

if [[ -n "$CT_ID" ]]; then
  [[ "$CT_ID" =~ ^(0|[1-9][0-9]*)$ ]] && (( CT_ID >= 100 && CT_ID <= 999999999 )) \
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
  echo "  Fresh creator: use the existing CT maintenance helper, or review the retained CT before removing it." >&2
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
  Listens on:        0.0.0.0:${APP_PORT} inside the CT (Network=host) — access follows the UFW source choice below
                     PostgreSQL 127.0.0.1:5432, Valkey 127.0.0.1:6379, ML 127.0.0.1:3003 (loopback only)
  Podman storage:    $([ "$PODMAN_FUSE_OVERLAY" -eq 1 ] && echo "fuse-overlayfs (fuse=1)" || echo "native overlay (no FUSE)")
  Tags:              $TAGS
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled — daily at ${UPDATE_TIME} (re-pull $APP_TAG / $POSTGRES_TAG / $VALKEY_TAG)" || echo "disabled ($APP_TAG / $POSTGRES_TAG / $VALKEY_TAG, manual)")
  Cleanup on fail:   $CLEANUP_ON_FAIL (disarmed before first persistent start) (until first service start; CT preserved after that — host photo path/dataset is never removed)
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

response=""
read -r -p "  Continue with these settings? [y/N]: " response <&8 || response=""
case "$response" in
  [yY][eE][sS]|[yY]) ;;
  *)
    echo ""
    echo "  Keeping an editable script copy..."
    if [[ -f "$SCRIPT_SELF" ]] && head -n 1 "$SCRIPT_SELF" | grep -q '^#!/usr/bin/env bash$'; then
      # The running local file is already the correct editable copy. In particular,
      # never cp a file onto itself and then fetch a replacement over user edits.
      echo "  Edit: nano $SCRIPT_SELF"
      echo "  Run:  bash $SCRIPT_SELF"
    else
      [[ ! -e $SCRIPT_LOCAL ]] || SCRIPT_LOCAL="/root/immich-quadlet-downloaded.$$.sh"
      DOWNLOAD_TEMP=$(mktemp /root/immich-download.XXXXXX)
      if curl -fLsS --retry 3 --connect-timeout 10 --max-time 120 "$SCRIPT_URL" -o "$DOWNLOAD_TEMP" \
        && head -n 1 "$DOWNLOAD_TEMP" | grep -q '^#!/usr/bin/env bash$' \
        && bash -n "$DOWNLOAD_TEMP"; then
        chmod 0700 "$DOWNLOAD_TEMP"
        mv -T "$DOWNLOAD_TEMP" "$SCRIPT_LOCAL"
        echo "  Downloaded a separate upstream copy; it may differ from the piped script."
        echo "  Edit: nano $SCRIPT_LOCAL"
      else
        rm -f -- "$DOWNLOAD_TEMP"
        echo "  ERROR: Could not save a validated upstream copy. Existing files were preserved." >&2
        exit 1
      fi
    fi
    exit 0
    ;;
esac

echo ""


# ── Firewall access sources ───────────────────────────────────────────────────
# Enter NPM host addresses for proxy-only access, or client subnets for direct
# LAN access. Enter without sources opens only APP_PORT, not the whole firewall.
FIREWALL_ACCESS_LABEL=""
if (( ${#UFW_ALLOWED_SOURCES[@]} == 0 )); then
  cat <<FIREWALL_HELP
  Firewall access for TCP $APP_PORT:

    One device:       192.168.1.20
    Whole subnet:     192.168.1.0/24
    Multiple sources: 192.168.1.20 192.168.2.0/24
    IPv6 examples:    fd00::20 or fd00::/64

  CIDR format: network-address/prefix-length
  Example: 192.168.1.0/24 covers the 192.168.1.x subnet.
  Use the network address (no host bits); replace examples with your addresses.

  Press Enter to allow any source on TCP $APP_PORT (IPv4 and IPv6).
  UFW stays enabled. Any source includes the internet if this CT is reachable.

FIREWALL_HELP
  if ! read -r -p "  Allowed sources (space-separated) [Enter = any]: " firewall_input <&8; then
    echo "ERROR: Firewall input interrupted; no access policy selected." >&2
    exit 1
  fi
  read -r -a UFW_ALLOWED_SOURCES <<< "$firewall_input"
  if (( ${#UFW_ALLOWED_SOURCES[@]} == 0 )); then
    UFW_ALLOWED_SOURCES=("0.0.0.0/0" "::/0")
    FIREWALL_ACCESS_LABEL="Any source (IPv4 and IPv6)"
  fi
fi
if ! python3 - "${UFW_ALLOWED_SOURCES[@]}"  <<'FIREWALL_VALIDATE'
import ipaddress, sys
for value in sys.argv[1:]:
    try:
        network = ipaddress.ip_network(value, strict=True)
    except ValueError:
        print(f"ERROR: Invalid firewall source {value!r}. Use a host IP (192.168.1.20) or network CIDR (192.168.1.0/24, no host bits).", file=sys.stderr)
        sys.exit(1)
    if network.network_address.is_multicast or network.network_address.is_loopback:
        print(f"ERROR: Expected a client/proxy source, got {value!r}.", file=sys.stderr)
        sys.exit(1)
FIREWALL_VALIDATE
then
  exit 1
fi
FIREWALL_ACCESS_LABEL="${FIREWALL_ACCESS_LABEL:-${UFW_ALLOWED_SOURCES[*]}}"
echo "  UFW TCP $APP_PORT allowed sources: $FIREWALL_ACCESS_LABEL"

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
for i in $(seq 1 60); do
  CT_IP="$(pct exec "$CT_ID" -- sh -lc '
    ip -4 -o addr show scope global 2>/dev/null | awk "{print \$4}" | cut -d/ -f1 | head -n1
  ' 2>/dev/null || true)"
  [[ -n "$CT_IP" ]] && break
  sleep 1
done
[[ -n "$CT_IP" ]] || { echo "  ERROR: No IPv4 address acquired via DHCP within timeout." >&2; false; }
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
  apt-get install -y locales curl ca-certificates iproute2 python3 ufw iptables util-linux podman tar gzip ${PODMAN_FUSE_PKG}
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

# ── UFW inside the CT ─────────────────────────────────────────────────────────
# Fresh CT only. Network=host uses this CT's INPUT chain.
pct exec "$CT_ID" -- bash -s -- "$APP_PORT" "${UFW_ALLOWED_SOURCES[@]}" <<'UFWSETUP'
set -euo pipefail
export LC_ALL=C
port=$1; shift
(( $# > 0 )) || { echo "ERROR: No allowed source addresses."; false; }
iptables -w 5 -S INPUT >/dev/null
ip6tables -w 5 -S INPUT >/dev/null
ufw --force reset
sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
grep -qx 'IPV6=yes' /etc/default/ufw
# The creator owns sysctl hardening; avoid a second writer in ufw-init.
grep -q '^IPT_SYSCTL=' /etc/default/ufw
sed -i 's|^IPT_SYSCTL=.*|IPT_SYSCTL=|' /etc/default/ufw
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed
ufw logging off
for source in "$@"; do
  ufw allow in proto tcp from "$source" to any port "$port"
done
ufw --force enable
systemctl enable ufw.service
systemctl restart ufw.service
for source in "$@"; do
  tool=iptables; prefix=ufw
  if [[ $source == *:* ]]; then tool=ip6tables; prefix=ufw6; fi
  "$tool" -w 5 -C "$prefix-user-input" -s "$source" -p tcp -m tcp --dport "$port" -j ACCEPT
done
UFWSETUP

tmp=$(mktemp)
cat > "$tmp" <<'UFWCHECK'
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
# Startup guard: active filtering and default-deny in both address families.
# Installation verifies specific allow rules; test access from client hosts too.
grep -qx 'ENABLED=yes' /etc/ufw/ufw.conf
grep -qx 'IPV6=yes' /etc/default/ufw
status=$(/usr/sbin/ufw status)
grep -qx 'Status: active' <<< "$status"
for tool in /usr/sbin/iptables /usr/sbin/ip6tables; do
  prefix=ufw
  [[ ${tool##*/} != ip6tables ]] || prefix=ufw6
  rules=$("$tool" -w 5 -S INPUT)
  grep -qx -- '-P INPUT DROP' <<< "$rules"
  "$tool" -w 5 -C INPUT -j "$prefix-before-input"
  "$tool" -w 5 -S "$prefix-user-input" >/dev/null
done
UFWCHECK
pct push "$CT_ID" "$tmp" /usr/local/sbin/immich-ufw-check --perms 0755
rm -f -- "$tmp"
pct exec "$CT_ID" -- /usr/local/sbin/immich-ufw-check

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
[[ "$CGROUPS_VERSION" == "v2" ]] || { echo "  ERROR: Quadlet requires cgroup v2 inside the CT; podman reports '${CGROUPS_VERSION}'." >&2; false; }
GRAPH_DRIVER="$(pct exec "$CT_ID" -- podman info --format '{{.Store.GraphDriverName}}' 2>/dev/null || echo "?")"
[[ "$GRAPH_DRIVER" == "overlay" ]] || { echo "  ERROR: Podman storage driver is '${GRAPH_DRIVER}', expected overlay." >&2; false; }
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


# ── Resolve immutable runtime images ──────────────────────────────────────────
for component in POSTGRES VALKEY APP; do
  reference_var=${component}_IMAGE
  resolved=$(pct exec "$CT_ID" -- podman image inspect --format '{{.Id}}' "${!reference_var}")
  resolved=${resolved#sha256:}
  [[ $resolved =~ ^[a-f0-9]{64}$ ]] || { echo "ERROR: Invalid image ID for $component." >&2; false; }
  printf -v "${component}_IMAGE_ID" 'sha256:%s' "$resolved"
done


# The database image decides its postgres UID/GID; do not assume Debian's 999.
POSTGRES_UID=$(pct exec "$CT_ID" -- podman run --rm --pull=never --network none --entrypoint sh "$POSTGRES_IMAGE_ID" -c 'id -u postgres')
POSTGRES_GID=$(pct exec "$CT_ID" -- podman run --rm --pull=never --network none --entrypoint sh "$POSTGRES_IMAGE_ID" -c 'id -g postgres')
[[ $POSTGRES_UID =~ ^[0-9]+$ && $POSTGRES_GID =~ ^[0-9]+$ ]] || { echo "ERROR: Cannot determine PostgreSQL ownership." >&2; false; }

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
  install -d -m 0700 -o ${POSTGRES_UID} -g ${POSTGRES_GID} '${APP_DIR}/postgres'
  install -d -m 0755 -o 1000 -g 1000 '${APP_DIR}/config'
  if [ -z '${PHOTO_MOUNT_SRC}' ]; then
    install -d -m 0755 -o 1000 -g 1000 '${LIBRARY_DIR}'
  else
    mountpoint -q '${LIBRARY_DIR}' || { echo '  ERROR: ${LIBRARY_DIR} is not a mount point inside the CT (mp0 missing?)' >&2; false; }
    owner=\$(stat -c '%u:%g' '${LIBRARY_DIR}')
    [ \"\$owner\" = '1000:1000' ] || { echo \"  ERROR: ${LIBRARY_DIR} is seen as \$owner inside the CT, expected 1000:1000 (host must be 101000:101000)\" >&2; false; }
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
# LabTag=${POSTGRES_TAG}
# LabImage=${POSTGRES_IMAGE}
Image=${POSTGRES_IMAGE_ID}
Pull=never
ContainerName=immich-postgres
Network=host
Environment=TZ=${APP_TZ}
Environment=POSTGRES_USER=immich
Environment=POSTGRES_DB=immich
${DB_STORAGE_LINE}
EnvironmentFile=${POSTGRES_ENV_FILE}
Volume=${APP_DIR}/postgres:/var/lib/postgresql/data
Volume=${APP_DIR}/postgres-init:/docker-entrypoint-initdb.d:ro
ShmSize=128m
HealthCmd=pg_isready -h 127.0.0.1 -U immich -d immich
HealthInterval=10s
HealthTimeout=5s
HealthRetries=5
HealthStartPeriod=60s
Notify=healthy
StopTimeout=110
LogDriver=journald

[Service]
Restart=always
RestartSec=5
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
# LabTag=${VALKEY_TAG}
# LabImage=${VALKEY_IMAGE}
Image=${VALKEY_IMAGE_ID}
Pull=never
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
StopTimeout=20
LogDriver=journald

[Service]
Restart=always
RestartSec=5
TimeoutStartSec=120
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF2

  cat > '${QUADLET_FILE}' <<EOF2
[Unit]
Description=Immich (imagegenius monolith)
After=network-online.target ufw.service ${POSTGRES_QUADLET_SERVICE} ${VALKEY_QUADLET_SERVICE}
Wants=network-online.target
Requires=ufw.service
Requires=${POSTGRES_QUADLET_SERVICE} ${VALKEY_QUADLET_SERVICE}

[Container]
# LabTag=${APP_TAG}
# LabImage=${APP_IMAGE}
Image=${APP_IMAGE_ID}
Pull=never
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
StopTimeout=110
LogDriver=journald

[Service]
ExecStartPre=/usr/local/sbin/immich-ufw-check
Restart=always
RestartSec=5
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
{ printf 'POSTGRES_PASSWORD=%s\n' "$DB_PASSWORD"; printf 'POSTGRES_INITDB_ARGS=--data-checksums --auth-host=scram-sha-256\nPOSTGRES_HOST_AUTH_METHOD=scram-sha-256\n'; } | pct exec "$CT_ID" -- bash -lc "
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
APP_IMAGE_ID=${APP_IMAGE_ID}
POSTGRES_IMAGE_REPO=${POSTGRES_IMAGE_REPO}
POSTGRES_TAG=${POSTGRES_TAG}
POSTGRES_IMAGE=${POSTGRES_IMAGE}
POSTGRES_IMAGE_ID=${POSTGRES_IMAGE_ID}
VALKEY_IMAGE_REPO=${VALKEY_IMAGE_REPO}
VALKEY_TAG=${VALKEY_TAG}
VALKEY_IMAGE=${VALKEY_IMAGE}
VALKEY_IMAGE_ID=${VALKEY_IMAGE_ID}
APP_PORT=${APP_PORT}
APP_TZ=${APP_TZ}
APP_FQDN=${APP_FQDN}
PHOTO_STORAGE=${PHOTO_STORAGE}
PHOTO_MOUNT_SRC=${PHOTO_MOUNT_SRC}
AUTO_UPDATE=${AUTO_UPDATE}
PODMAN_FUSE_OVERLAY=${PODMAN_FUSE_OVERLAY}
INITIAL_WAIT_SECONDS=${INITIAL_WAIT_SECONDS}
UPDATE_WAIT_SECONDS=${UPDATE_WAIT_SECONDS}
UPDATE_TIME=${UPDATE_TIME}
EOF2
  chmod 0600 '${APP_DIR}/.env'
"

# ── Maintenance script ────────────────────────────────────────────────────────
# One component per update; immutable IDs, atomic control files and explicit
# recovery policy. The helper never archives or restores application data.
tmp="$(mktemp)"
cat > "$tmp" <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail
umask 077
export LC_ALL=C

# Generated with this application's creator; no shared runtime library.
APP_DIR=/opt/immich
ENV_FILE=$APP_DIR/.env
UNIT_DIR=/etc/containers/systemd
MAIN_SERVICE=immich.service
LOCK=/run/lock/immich-maint.lock
GENERATOR=/usr/lib/systemd/system-generators/podman-system-generator
# Only temporary control-file copies are made. PBS/PVE owns data recovery.
# Atomic rename protects each file; this is not a multi-file disk transaction.
# The Quadlet contains the authoritative tag/reference/ID. Metadata is reconciled
# under the maintenance lock after an interruption.
WORK=""
SWITCHED=0
START_ATTEMPTED=0
APP_STOPPED=0
COMPONENT=""
DB_TYPE_BEFORE=""
declare -A STATE=()

die() { printf '  ERROR: %s\n' "$*" >&2; exit 1; }
read_state() {
  local line key value
  STATE=()
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
    [[ $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || die "Malformed state line."
    key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
    [[ ! ${STATE[$key]+yes} ]] || die "Duplicate state key: $key"
    STATE[$key]=$value
  done < "$ENV_FILE"
  # State is parsed as data. Never source an editable .env as root.
  for key in APP_PORT INITIAL_WAIT_SECONDS UPDATE_WAIT_SECONDS PODMAN_FUSE_OVERLAY AUTO_UPDATE; do
    [[ ${STATE[$key]:-} =~ ^(0|[1-9][0-9]{0,5})$ ]] || die "Invalid $key."
  done
  (( STATE[APP_PORT] >= 1024 && STATE[APP_PORT] <= 65535 )) || die "Invalid APP_PORT."
  (( STATE[INITIAL_WAIT_SECONDS] >= 30 && STATE[INITIAL_WAIT_SECONDS] <= 86400 )) || die "Invalid initial wait."
  (( STATE[UPDATE_WAIT_SECONDS] >= 30 && STATE[UPDATE_WAIT_SECONDS] <= 86400 )) || die "Invalid update wait."
  [[ ${STATE[AUTO_UPDATE]} =~ ^[01]$ && ${STATE[PODMAN_FUSE_OVERLAY]} =~ ^[01]$ ]] || die "Invalid policy flag."
  (( STATE[APP_PORT] != 5432 && STATE[APP_PORT] != 6379 )) || die "Backend port collision."
  (( STATE[APP_PORT] != 3003 )) || die "Machine-learning port collision."
}
unit_value() {
  local prefix=$1 file=$2
  awk -v p="$prefix" 'index($0,p)==1 {value=substr($0,length(p)+1); n++} END {if(n!=1) exit 1; print value}' "$file"
}
image_id() {
  local value
  value=$(podman image inspect --format '{{.Id}}' "$1") || return 1
  value=${value#sha256:}
  [[ $value =~ ^[a-f0-9]{64}$ ]] || return 1
  printf 'sha256:%s\n' "$value"
}
select_component() {
  COMPONENT=$1
  case $COMPONENT in
    POSTGRES) CONTAINER=immich-postgres; KIND=postgres; IMAGE_RECOVERY=0 ;;
    VALKEY) CONTAINER=immich-valkey; KIND=valkey; IMAGE_RECOVERY=1 ;;
    APP) CONTAINER=immich; KIND=app; IMAGE_RECOVERY=0 ;;
    *) die "Unknown component: $COMPONENT" ;;
  esac
  SERVICE=$CONTAINER.service
  UNIT=$UNIT_DIR/$CONTAINER.container
}
valid_tag() {
  case $1 in
    POSTGRES) [[ $2 =~ ^14-vectorchord[0-9]+\.[0-9]+\.[0-9]+(-pgvectors[0-9]+\.[0-9]+\.[0-9]+)?$ ]] ;;
    VALKEY) [[ $2 =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] ;;
    APP) [[ $2 =~ ^[0-9]+\.[0-9]+\.[0-9]+(-noml)?$ ]] ;;
    *) return 1 ;;
  esac
}
load_unit() {
  OLD_TAG=$(unit_value '# LabTag=' "$UNIT") || die "Missing LabTag metadata; use the matching upgraded creator."
  OLD_IMAGE=$(unit_value '# LabImage=' "$UNIT") || die "Missing LabImage metadata."
  OLD_ID=$(unit_value 'Image=' "$UNIT") || die "Missing image ID."
  [[ $OLD_IMAGE == *:* ]] || die "Invalid image reference."
  REPO=${OLD_IMAGE%:*}
  [[ $REPO =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*[A-Za-z0-9]$ ]] || die "Invalid repository."
  valid_tag "$COMPONENT" "$OLD_TAG" || die "Configured tag violates this component's policy."
  [[ $OLD_IMAGE == "$REPO:$OLD_TAG" && $OLD_ID =~ ^sha256:[a-f0-9]{64}$ ]] || die "Inconsistent unit metadata."
  [[ $(unit_value 'Pull=' "$UNIT") == never ]] || die "Expected Pull=never."
}
write_env() {
  local tag=$1 reference=$2 id=$3 temp
  temp=$(mktemp "${ENV_FILE}.XXXXXX") || return 1
  if ! awk -v c="$COMPONENT" -v repo="$REPO" -v t="$tag" -v r="$reference" -v id="$id" '
    $0 ~ ("^" c "_(IMAGE_REPO|TAG|IMAGE|IMAGE_ID)=") {next}
    {print}
    END {print c "_IMAGE_REPO=" repo; print c "_TAG=" t; print c "_IMAGE=" r; print c "_IMAGE_ID=" id}
  ' "$ENV_FILE" > "$temp" || ! chmod 0600 "$temp" || ! mv -fT "$temp" "$ENV_FILE"; then
    rm -f -- "$temp"; return 1
  fi
}
write_unit() {
  local tag=$1 reference=$2 id=$3 temp
  temp=$(mktemp "${UNIT}.XXXXXX") || return 1
  if ! sed -e "s|^# LabTag=.*|# LabTag=$tag|" \
      -e "s|^# LabImage=.*|# LabImage=$reference|" \
      -e "s|^Image=.*|Image=$id|" "$UNIT" > "$temp" \
      || ! chmod 0644 "$temp" || ! mv -fT "$temp" "$UNIT"; then
    rm -f -- "$temp"; return 1
  fi
}
copy_control_file() {
  local source=$1 destination=$2 temp
  temp=$(mktemp "${destination}.XXXXXX") || return 1
  if ! cp --preserve=mode,ownership "$source" "$temp" || ! mv -fT "$temp" "$destination"; then
    rm -f -- "$temp"; return 1
  fi
}
wait_service() {
  local container=$1 kind=$2 budget=$3 started=$SECONDS state restarts first code value
  local healthy_since=-1
  first=$(systemctl show "$container.service" -p NRestarts --value) || return 1
  while (( SECONDS - started < budget )); do
    state=$(systemctl show "$container.service" -p ActiveState --value) || return 1
    restarts=$(systemctl show "$container.service" -p NRestarts --value) || return 1
    [[ $state != failed && $state != inactive && $restarts == "$first" ]] || return 1
    value=0
    if [[ $state == active ]]; then
      case $kind in
        app)
          code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 3 \
            "http://127.0.0.1:${STATE[APP_PORT]}/api/server/ping") || code=000
          [[ $code =~ ^200$ ]] && value=1
          ;;
        postgres)
          timeout 5 podman exec "$container" pg_isready -q -h 127.0.0.1 -U immich -d immich && value=1
          ;;
        valkey|redis)
          code=$(timeout 5 podman exec "$container" "$kind-cli" -h 127.0.0.1 ping 2>/dev/null) || code=""
          [[ $code == PONG ]] && value=1
          ;;
      esac
    fi
    if (( value )); then
      (( healthy_since >= 0 )) || healthy_since=$SECONDS
      (( SECONDS - healthy_since >= 6 )) && return 0
    else
      healthy_since=-1
    fi
    sleep 2
  done
  return 1
}
validate_candidate() {
  local id=$1 old_user new_user actual major uid gid path version
  # Only the image shell runs, without network or data mounts. The candidate
  # application never gets production data during validation.
  podman run --rm --pull=never --network none --entrypoint /bin/sh "$id" -c true
  old_user=$(podman image inspect --format '{{.Config.User}}' "$OLD_ID")
  new_user=$(podman image inspect --format '{{.Config.User}}' "$id")
  [[ $old_user == "$new_user" ]] || die "Image USER changed; review ownership before updating."
if [[ $COMPONENT == POSTGRES ]]; then
    path="$APP_DIR/postgres"
    [[ $(cat "$path/PG_VERSION") == 14 ]] || die "On-disk PostgreSQL major does not match."
    uid=$(podman run --rm --pull=never --network none --entrypoint sh "$id" -c 'id -u postgres')
    gid=$(podman run --rm --pull=never --network none --entrypoint sh "$id" -c 'id -g postgres')
    [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ && $(stat -c '%u:%g' "$path") == "$uid:$gid" ]] \
      || die "PostgreSQL UID/GID differs from existing data; no recursive chown is attempted."
    version=$(podman run --rm --pull=never --network none --entrypoint postgres "$id" --version)
    [[ $version == "postgres (PostgreSQL) 14."* ]] || die "Candidate PostgreSQL binary has the wrong major."
  fi
}
pre_update_checks() {
if [[ -n ${STATE[PHOTO_MOUNT_SRC]:-} ]]; then
    mountpoint -q "$APP_DIR/library" || die "External photo-library mount is missing."
  fi
  for path in "$APP_DIR/config" "$APP_DIR/library"; do
    [[ $(stat -c '%u:%g' "$path") == 1000:1000 ]] || die "Immich path has unexpected ownership: $path"
  done
  :
}
post_update_checks() {

  :
}
finish() {
  local rc=$? restored=1
  trap - EXIT ERR INT TERM HUP
  set +e
  if (( rc != 0 && SWITCHED )); then
    if (( START_ATTEMPTED == 0 || IMAGE_RECOVERY == 1 )); then
      copy_control_file "$WORK/old.container" "$UNIT" || restored=0
      copy_control_file "$WORK/old.env" "$ENV_FILE" || restored=0
      systemctl daemon-reload || restored=0
      if (( restored && START_ATTEMPTED )); then
        systemctl restart "$SERVICE" && wait_service "$CONTAINER" "$KIND" "${STATE[UPDATE_WAIT_SECONDS]}" || restored=0
      fi
      if (( restored && APP_STOPPED )); then
        systemctl start "$MAIN_SERVICE" && wait_service immich app "${STATE[UPDATE_WAIT_SECONDS]}" || restored=0
      fi
      if (( restored )); then
        printf '  Previous control files/image restored; this does not undo application data changes.\n' >&2
      else
        printf '  CRITICAL: Recovery was not confirmed. Inspect %s and %s.\n' "$UNIT" "$WORK" >&2
      fi
    else
      printf '  Target %s image retained: persistent state may already have changed.\n' "$COMPONENT" >&2
      printf '  No automatic image/database downgrade. Inspect journalctl -u %s -u %s.\n' "$SERVICE" "$MAIN_SERVICE" >&2
      printf '  Recover matching PBS/PVE state if needed. A readiness timeout does not stop a migration.\n' >&2
      (( APP_STOPPED == 0 )) || printf '  After the backend is healthy: systemctl start %s\n' "$MAIN_SERVICE" >&2
    fi
  elif (( rc != 0 && APP_STOPPED )); then
    systemctl start "$MAIN_SERVICE" || restored=0
  fi
  if [[ -n $WORK ]]; then
    if (( restored )); then rm -rf -- "$WORK"; else printf '  Retained control-file copies: %s\n' "$WORK" >&2; fi
  fi
  exit "$rc"
}
trap finish EXIT
trap 'printf "  Maintenance failed near line %s.\n" "$LINENO" >&2' ERR
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

update_component() {
  local requested=${2:-} actual new_id target old_variant new_variant
  select_component "$1"
  load_unit
  SWITCHED=0; START_ATTEMPTED=0; APP_STOPPED=0
  target=${requested:-$OLD_TAG}
  valid_tag "$COMPONENT" "$target" || die "Invalid target tag for $COMPONENT."
# Semantic version downgrades of persistent components require a separate review.
  if (( IMAGE_RECOVERY == 0 )) && [[ $target != latest && $OLD_TAG != latest ]]; then
    [[ $(printf '%s\n%s\n' "$OLD_TAG" "$target" | sort -V | head -n 1) == "$OLD_TAG" ]] \
      || die "Persistent-component downgrade requires matching data recovery."
  fi

  if [[ $COMPONENT == POSTGRES ]]; then
    [[ ${OLD_TAG%%[.-]*} == ${target%%[.-]*} ]] || die "PostgreSQL major changes require a separate migration."

    printf '  VectorChord/pgvectors changes must match the running Immich release.\n'
    fi

  if [[ $COMPONENT == APP ]]; then
    [[ ${OLD_TAG%%.*} == ${target%%.*} ]] || die "Application major changes require a separate migration review."
  fi

  if [[ $COMPONENT == APP ]]; then
    old_variant=""; new_variant=""
    [[ $OLD_TAG != *-* ]] || old_variant=${OLD_TAG#*-}
    [[ $target != *-* ]] || new_variant=${target#*-}
    [[ $old_variant == "$new_variant" ]] || die "Immich ML image variant changes require a separate review."
  fi
  /usr/local/sbin/immich-ufw-check || die "Restore active UFW filtering before maintenance."
  actual=$(podman inspect --format '{{.Image}}' "$CONTAINER") || die "Cannot inspect running image."
  [[ $(image_id "$actual") == "$OLD_ID" ]] || die "Running/configured image mismatch; inspect the service."
  wait_service "$CONTAINER" "$KIND" 30 || die "$SERVICE is unhealthy before update."
  if [[ $COMPONENT != APP ]]; then
    wait_service immich app 30 || die "Application is unhealthy before backend update."
  fi
  if [[ ${STATE[${COMPONENT}_TAG]:-} != "$OLD_TAG" ||
        ${STATE[${COMPONENT}_IMAGE]:-} != "$OLD_IMAGE" ||
        ${STATE[${COMPONENT}_IMAGE_ID]:-} != "$OLD_ID" ||
        ${STATE[${COMPONENT}_IMAGE_REPO]:-} != "$REPO" ]]; then
    write_env "$OLD_TAG" "$OLD_IMAGE" "$OLD_ID"
    read_state
    printf '  Reconciled metadata from the authoritative Quadlet.\n'
  fi
  pre_update_checks
  if (( YES == 0 )); then
    [[ -t 8 ]] || die "Interactive terminal or --yes is required."
    printf '  Verify a matching PBS/PVE recovery checkpoint on the host before updating.\n'
    (( STATE[PODMAN_FUSE_OVERLAY] == 0 )) || printf '  FUSE is enabled: use stop-mode PBS; do not freeze this running CT.\n'
    printf '  External Immich photo storage needs its own coordinated checkpoint; CT backup excludes bind mounts.\n'
    (( IMAGE_RECOVERY )) || printf '  Once the target starts, automatic image downgrade is disabled.\n'
    read -r -p "  Update $COMPONENT $OLD_TAG -> $target? [y/N]: " answer <&8 || return 0
    [[ $answer =~ ^([Yy]|[Yy][Ee][Ss])$ ]] || return 0
  else
    printf '  --yes skips confirmation; no backup is created or verified.\n'
  fi
  podman pull "$REPO:$target"
  new_id=$(image_id "$REPO:$target") || die "Cannot resolve target image."
  if [[ $new_id == "$OLD_ID" && $target == "$OLD_TAG" ]]; then
    printf '  %s unchanged; no restart.\n' "$COMPONENT"
    return 0
  fi
  validate_candidate "$new_id"
  WORK=$(mktemp -d /run/immich-update.XXXXXX)
  cp --preserve=mode,ownership "$UNIT" "$WORK/old.container"
  cp --preserve=mode,ownership "$ENV_FILE" "$WORK/old.env"
  SWITCHED=1
  write_unit "$target" "$REPO:$target" "$new_id"
  write_env "$target" "$REPO:$target" "$new_id"
  "$GENERATOR" --dryrun > "$WORK/generator.txt"
  grep -Fq "$CONTAINER.service" "$WORK/generator.txt" || die "Generator omitted $SERVICE."
  systemctl daemon-reload
  [[ $(systemctl show "$SERVICE" -p LoadState --value) == loaded ]] || die "Unit did not load."
  if [[ $new_id != "$OLD_ID" ]]; then
    if [[ $COMPONENT != APP ]]; then
      APP_STOPPED=1
      systemctl stop "$MAIN_SERVICE"
    fi
    START_ATTEMPTED=1
    systemctl restart "$SERVICE"
    wait_service "$CONTAINER" "$KIND" "${STATE[UPDATE_WAIT_SECONDS]}" || die "$SERVICE failed readiness or restarted."
    if [[ $COMPONENT != APP ]]; then
      systemctl start "$MAIN_SERVICE"
      wait_service immich app "${STATE[UPDATE_WAIT_SECONDS]}" || die "Application did not recover after backend update."
    fi
  fi
  actual=$(podman inspect --format '{{.Image}}' "$CONTAINER")
  [[ $(image_id "$actual") == "$new_id" ]] || die "Running image differs from target."
  post_update_checks
  SWITCHED=0; START_ATTEMPTED=0; APP_STOPPED=0
  rm -rf -- "$WORK"; WORK=""
  # Retain the prior image for inspection/recovery. No broad image prune.
  read_state
  printf '  Updated %s: %s (%s).\n' "$COMPONENT" "$target" "$new_id"
}

[[ $EUID == 0 ]] || die "Run as root inside the immich CT."
for command in podman systemctl curl awk sed sort head cat stat grep mktemp cp chmod mv rm flock timeout python3; do
  command -v "$command" >/dev/null || die "Missing command: $command"
done
[[ -f $ENV_FILE ]] || die "Missing $ENV_FILE."
exec 9>"$LOCK"
flock -n 9 || die "Another maintenance operation is running."
YES=0
ARGS=()
for arg in "$@"; do
  case $arg in --yes|-y) YES=1 ;; *) ARGS+=("$arg") ;; esac
done
set -- "${ARGS[@]}"
cmd=${1:---help}
read_state
case $cmd in
  update|update-postgres|update-valkey)
    (( $# <= 2 )) || die "Usage: $0 $cmd [tag] [--yes]"
    if (( YES == 0 )); then
      exec 8</dev/tty || die "Interactive terminal or --yes is required."
    fi
    case $cmd in
      update-postgres) update_component POSTGRES "${2:-}" ;;
      update-valkey) update_component VALKEY "${2:-}" ;;
      update) update_component APP "${2:-}" ;;
    esac
    ;;
  auto-update)
    (( $# == 1 )) || die "auto-update takes no tag."
    [[ ${STATE[AUTO_UPDATE]} == 1 ]] || { printf '  Auto-update is disabled.\n'; exit 0; }
    YES=1
    for component in POSTGRES VALKEY APP; do
      update_component "$component"
    done
    ;;
  check)
    (( $# <= 2 )) && [[ ${2:-} == "" || ${2:-} == --initial ]] || die "Usage: $0 check [--initial]"
    /usr/local/sbin/immich-ufw-check
    budget=${STATE[UPDATE_WAIT_SECONDS]}
    [[ ${2:-} != --initial ]] || budget=${STATE[INITIAL_WAIT_SECONDS]}
    for component in POSTGRES VALKEY APP; do
      select_component "$component"
      load_unit
      if [[ ${2:-} == --initial ]]; then
        [[ $(systemctl show "$SERVICE" -p NRestarts --value) == 0 ]] || die "$SERVICE restarted during initial startup."
      fi
      wait_service "$CONTAINER" "$KIND" "$budget" || die "$SERVICE failed readiness or restarted."
      actual=$(podman inspect --format '{{.Image}}' "$CONTAINER")
      [[ $(image_id "$actual") == "$OLD_ID" ]] || die "Running/configured image mismatch: $SERVICE"
    done
    printf '  Service readiness, stable restart counts, image IDs and UFW checks passed.\n'
    ;;
  version)
    (( $# == 1 )) || die "version takes no argument."
    for component in POSTGRES VALKEY APP; do
      select_component "$component"; load_unit
      printf '  %s\n    tag: %s\n    configured ID: %s\n    running ID: ' "$CONTAINER" "$OLD_TAG" "$OLD_ID"
      podman inspect --format '{{.Image}}' "$CONTAINER" || true
    done
    ;;
  --help|-h|'')
    printf 'Usage: %s update [tag] [--yes] | update-postgres [tag] [--yes] | update-valkey [tag] [--yes] | auto-update | check [--initial] | version\n' "$0"
    printf '  Exact image IDs; one component per operation; PBS/PVE handles data recovery.\n'
    printf '  Fresh-creator helper: do not replace an older deployed helper without migrating its control files.\n'
    ;;
  *) die "Unknown command: $cmd" ;;
esac
MAINT
pct push "$CT_ID" "$tmp" /usr/local/bin/immich-maint.sh --perms 0755
rm -f -- "$tmp"

# ── Start via Quadlet ─────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -s -- immich-postgres immich-valkey immich <<'QUADLET_VALIDATE'
set -euo pipefail
output=$(mktemp)
trap 'rm -f -- "$output"' EXIT
/usr/lib/systemd/system-generators/podman-system-generator --dryrun > "$output"
for service in "$@"; do
  grep -Fq "$service.service" "$output" || { echo "ERROR: Quadlet generator omitted $service." >&2; exit 1; }
done
systemctl daemon-reload
for service in "$@"; do
  [[ $(systemctl show "$service.service" -p LoadState --value) == loaded ]] || exit 1
done
QUADLET_VALIDATE
pct exec "$CT_ID" -- /usr/local/sbin/immich-ufw-check
# Preserve the CT even if the first persistent start fails partway through.
CLEANUP_ON_FAIL=0
pct exec "$CT_ID" -- systemctl start immich.service

# Destructive cleanup was disarmed before the first persistent service start.

# ── Verification ──────────────────────────────────────────────────────────────
sleep 30
if ! pct exec "$CT_ID" -- /usr/local/bin/immich-maint.sh check --initial; then
  echo "ERROR: Initial readiness/image/firewall verification failed; CT $CT_ID is preserved." >&2
  exit 1
fi
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


# Verify credentials and the effective database, not only pg_isready.
if ! pct exec "$CT_ID" -- python3 - <<'DATABASE_VERIFY'
import pathlib, subprocess, urllib.parse
app = "immich"
root = pathlib.Path("/opt") / app
container = app + "-postgres"
def envfile(path):
    result = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        if key in result:
            raise SystemExit("Duplicate credential key")
        result[key] = value
    return result
appenv = envfile(root / (app + ".env"))
pgenv = envfile(root / "postgres.env")
for ctr, values in ((app, appenv), (container, pgenv)):
    for key, expected in values.items():
        got = subprocess.check_output(["podman", "exec", ctr, "printenv", key], text=True, timeout=15).removesuffix("\n")
        if got != expected:
            raise SystemExit(f"Credential/config round trip failed: {ctr} {key}")
password = urllib.parse.urlsplit(appenv["DATABASE_URL"]).password if app == "docmost" else appenv["DB_PASSWORD"]
def sql(statement, secret):
    command = ["podman", "exec", "-i", container, "bash", "-c",
               'IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql -w -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$1" -d "$1" -tAc "$2"',
               "check", app, statement]
    return subprocess.run(command, input=secret+"\n", text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=15)
if sql("SELECT 1", "deliberately-wrong").returncode == 0:
    raise SystemExit("PostgreSQL accepted an incorrect TCP password")
checks = [
    ("SELECT 1", "1"),
    ("SELECT rolcanlogin AND rolsuper FROM pg_roles WHERE rolname='immich'", "t"),
    ("SELECT pg_get_userbyid(datdba)='immich' FROM pg_database WHERE datname='immich'", "t"),
    ("SELECT count(*)>0 FROM pg_tables WHERE schemaname='public'", "t"),
    ("SHOW data_directory", "/var/lib/postgresql/data"),
]
if app == "immich":
    checks.append(("SELECT count(*)=1 FROM pg_extension WHERE extname='vchord'", "t"))
for query, expected in checks:
    result = sql(query, password)
    if result.returncode or result.stdout.strip() != expected:
        raise SystemExit("Database authentication, role, storage or migration verification failed")
# pg_hba_file_rules is administrator-only; do not grant it to the app role.
admin = "postgres" if app == "docmost" else "immich"
query = "SELECT count(*)=0 FROM pg_hba_file_rules WHERE error IS NOT NULL OR (type LIKE 'host%' AND auth_method <> 'scram-sha-256')"
hba = subprocess.run(["podman", "exec", container, "psql", "-w", "-U", admin, "-d", app, "-tAc", query],
                     text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=15)
if hba.returncode or hba.stdout.strip() != "t":
    raise SystemExit("PostgreSQL host authentication is not consistently SCRAM")
print("  Database credentials, authentication, role, persistent path and schema verified.")
DATABASE_VERIFY
then
  VERIFY_FAIL=1
fi

if (( VERIFY_FAIL == 1 )); then
  echo "" >&2
  echo "  FATAL: Core verification failed — CT $CT_ID is preserved but the install is incomplete." >&2
  echo "  Inspect the container and fix manually, or destroy and re-run." >&2
  if [[ -n "$PHOTO_MOUNT_SRC" ]]; then
    echo "  Host photo path ${PHOTO_MOUNT_SRC} is retained. Inspect it and recover matching database/media state if necessary." >&2
  fi
  exit 1
fi

# ── Auto-update timer (policy-driven) ─────────────────────────────────────────
pct exec "$CT_ID" -- bash -s -- "$UPDATE_TIME" <<'TIMER_INSTALL'
set -euo pipefail
cat > /etc/systemd/system/immich-update.service <<EOF2
[Unit]
Description=immich image maintenance
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/immich-maint.sh auto-update
TimeoutStartSec=infinity
TimeoutStopSec=180
EOF2
cat > /etc/systemd/system/immich-update.timer <<EOF2
[Unit]
Description=immich daily image maintenance
[Timer]
OnCalendar=*-*-* $1:00
Persistent=true
[Install]
WantedBy=timers.target
EOF2
systemctl daemon-reload
TIMER_INSTALL
if [[ $AUTO_UPDATE == 1 ]]; then
  pct exec "$CT_ID" -- systemctl enable --now immich-update.timer
else
  pct exec "$CT_ID" -- systemctl disable --now immich-update.timer
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


cat <<OPERATIONS

  IMMICH — OPERATIONS

  CONTAINER     $HN | CT $CT_ID | $CT_IP
  WEB/ADMIN     http://$CT_IP:$APP_PORT/
  ALLOWED FROM  $FIREWALL_ACCESS_LABEL
  FIREWALL      UFW inside the CT, IPv4 and IPv6; no PVE firewall dependency
  AUTO-UPDATE   $AUTO_UPDATE | daily $UPDATE_TIME ($APP_TZ)
  IMAGES        exact local IDs, Pull=never; old images retained for review

  RUN ON THE PROXMOX HOST
    pct enter $CT_ID
    pct exec $CT_ID -- /usr/local/bin/immich-maint.sh version

  RUN INSIDE THE CT
    /usr/local/bin/immich-maint.sh check
    /usr/local/bin/immich-maint.sh update $APP_TAG
    ufw status verbose
    journalctl -u immich.service --no-pager -n 80

  ACCESS CHECK
    Test the web endpoint from your intended client/proxy.
    If you restricted sources, also test from outside the allowed list.
    Installer rule checks do not prove the full network path.
    Add/delete UFW rules directly; do not restart ufw.service while apps run.

  RECOVERY
    Verify a matching PBS/PVE checkpoint before updates; --yes only skips prompts.
    If FUSE is enabled, use stop-mode PBS. Back up external bind mounts separately.
    For persistent components, failed updates retain the target after it may start.
    The helper changes one component at a time; earlier successes remain applied.
    Creators build new CTs. Existing CTs require a reviewed control-file migration.

OPERATIONS

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
echo "    pct exec $CT_ID -- /usr/local/bin/immich-maint.sh update <tag>           # pin e.g. 3.1.0 / 3.1.0-noml"
echo "    pct exec $CT_ID -- /usr/local/bin/immich-maint.sh update-postgres <tag>  # same PG major only, per Immich release notes"
echo "    pct exec $CT_ID -- /usr/local/bin/immich-maint.sh update-valkey <tag>    # pin e.g. 8.1.3"
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
echo "    Port ${APP_PORT} listens on all CT interfaces (Network=host) — access follows the UFW source choice shown above."
echo "    PostgreSQL (5432), Valkey (6379) and the ML service (3003) are bound to 127.0.0.1 inside the CT."
if [[ "$PODMAN_FUSE_OVERLAY" -eq 1 ]]; then
  echo "    Backups: fuse=1 + fuse-overlayfs can deadlock under snapshot-mode vzdump/PBS (freezer)."
  echo "             Use stop-mode backups for this CT, or test PODMAN_FUSE_OVERLAY=0."
fi
echo "    Extra config (env vars, HW transcoding devices): edit ${QUADLET_FILE}, then systemctl daemon-reload && systemctl restart immich.service"
echo ""
