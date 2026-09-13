#!/usr/bin/env bash
set -Eeo pipefail
umask 022
export LC_ALL=C
# Hardening integration: 2026-09-13. Reviewed lab-hardening v1.1.1 embedded verbatim.
# Fix: scoped IPv6 DHCPv6 socket parsing; same shared correction as Flatnotes.
# Fix: normalize Podman container image IDs before checking worker provenance.
# Fresh Proxmox CT creator; maintenance and reusable verification run inside the CT.
# Fix: do not pass the Proxmox SSH session marker into the guest hardening check.
# Fix: scope IMMICH_HOST inside the worker run script; the image forbids a global setting.

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

# Shared Debian 13 LXC hardening (service CT; no forwarding)
HARDENING_PROFILE="lxc"              # LXC-only policy; not a VM/Proxmox-host profile
HARDENING_RP_FILTER=1                 # strict; use 2 only for reviewed asymmetric paths
HARDENING_KEEP_SSH=0                  # 0 = remove SSH server; 1 = preserve (does not open UFW)
HARDENING_REMOVE_POSTFIX=1            # 1 = remove Postfix; 0 = preserve intentional mail service
HARDENING_JOURNAL_DAYS=14
HARDENING_JOURNAL_MAX_MB=256
HARDENING_JOURNAL_RUNTIME_MB=64
HARDENING_UPDATE_MAX_AGE_HOURS=72
# Additional external TCP listeners, e.g. the actual SSH port if SSH is preserved.
# The finalized APP_PORT is prepended after the prompts. Backends are loopback-only.
HARDENING_TCP_PORTS=""
# DHCP client ports: IPv4 68; Debian template clients may also bind IPv6 546.
# This permits their inventory; it does not enable DHCPv6 or create firewall rules.
HARDENING_UDP_PORTS="68 546"
# Lists allow external listeners; they do not prove application readiness.
# An empty final list is inventory-only for that protocol.

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
#   /usr/local/sbin/immich-verify                     (repeatable Immich verification)
#   /usr/local/sbin/immich-worker-prepare             (derive worker startup for each image)
#   /opt/immich/microservices-run                     (worker-only loopback; read-only bind)
#   /var/backups/immich-worker/                       (previous worker startup files)
#   /opt/immich/verification.json                     (selected port and UFW sources)
#   /etc/default/ufw, /etc/ufw/ufw.conf               (in-CT IPv4/IPv6 policy)
#   /etc/ufw/user.rules, /etc/ufw/user6.rules         (configured source allows)
#   /etc/containers/systemd/immich.container           (Quadlet; public API + loopback worker)
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
#   /etc/update-motd.d/25-lab-hardening
#   /etc/sysctl.d/99-hardening.conf
#   /etc/apt/apt.conf.d/99-lab-hardening
#   /etc/needrestart/conf.d/99-lab-hardening.conf
#   /etc/systemd/journald.conf.d/99-lab-hardening.conf
#   /etc/systemd/system/apt-daily{,-upgrade}.service.d/90-lab-readiness.conf
#   /etc/systemd/system/lab-hardening-check.{service,timer}
#   /usr/local/sbin/lab-{apt-wait-online,hardening-check}
#   /var/lib/lab-hardening/{policy.json,status.json,last-index-refresh,check.lock}
#   /var/backups/lab-hardening/<run>/                  (common configuration backups)
#   SSH service/socket masks                         (when HARDENING_KEEP_SSH=0)
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

# Validate shared settings before creating the CT; the embedded block validates again.
[[ $HARDENING_PROFILE == lxc && $HARDENING_RP_FILTER =~ ^[12]$ &&
   $HARDENING_KEEP_SSH =~ ^[01]$ && $HARDENING_REMOVE_POSTFIX =~ ^[01]$ ]] || {
  echo "ERROR: Invalid LXC hardening profile, rp_filter or service-removal flag." >&2; exit 1;
}
for value in "$HARDENING_JOURNAL_DAYS" "$HARDENING_JOURNAL_MAX_MB" \
  "$HARDENING_JOURNAL_RUNTIME_MB" "$HARDENING_UPDATE_MAX_AGE_HOURS"; do
  [[ $value =~ ^[1-9][0-9]{0,3}$ ]] || { echo "ERROR: Hardening numeric values must be 1..9999." >&2; exit 1; }
done
for port in $HARDENING_TCP_PORTS $HARDENING_UDP_PORTS; do
  if [[ ! $port =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
    echo "ERROR: Hardening port lists require space-separated port numbers (1..65535)." >&2; exit 1
  fi
done

# ── Trap cleanup ──────────────────────────────────────────────────────────────
# rc is assigned from $? on the first line of the trap (not read from the caller).
# shellcheck disable=SC2154
trap 'rc=$?;
  trap - ERR
  echo "  ERROR: failed (rc=$rc) near line ${LINENO:-?}" >&2
  printf "  Command (first 240 characters): %.240s\n" "$BASH_COMMAND" >&2
  if [[ "${CLEANUP_ON_FAIL:-0}" -eq 1 && "${CREATED:-0}" -eq 1 ]]; then
    echo "  Cleanup: stopping/destroying CT ${CT_ID} ..." >&2
    pct stop "${CT_ID}" >/dev/null 2>&1 || true
    pct destroy "${CT_ID}" >/dev/null 2>&1 || true
  elif [[ "${CREATED:-0}" -eq 1 ]]; then
    echo "  CT ${CT_ID} is preserved. Inspect the failing stage output and guest journal; hardening status exists only after that stage begins." >&2
  fi
  [[ -z ${PHOTO_MOUNT_SRC:-} ]] || echo "  External photo path retained: ${PHOTO_MOUNT_SRC}" >&2
  exit "$rc"
' ERR

trap 'rc=130;
  trap - ERR INT TERM HUP
  echo "  Interrupted (rc=$rc)" >&2
  printf "  Command (first 240 characters): %.240s\n" "$BASH_COMMAND" >&2
  if [[ "${CLEANUP_ON_FAIL:-0}" -eq 1 && "${CREATED:-0}" -eq 1 ]]; then
    echo "  Cleanup: stopping/destroying CT ${CT_ID} ..." >&2
    pct stop "${CT_ID}" >/dev/null 2>&1 || true
    pct destroy "${CT_ID}" >/dev/null 2>&1 || true
  elif [[ "${CREATED:-0}" -eq 1 ]]; then
    echo "  CT ${CT_ID} is preserved. Inspect the failing stage output and guest journal; hardening status exists only after that stage begins." >&2
  fi
  [[ -z ${PHOTO_MOUNT_SRC:-} ]] || echo "  External photo path retained: ${PHOTO_MOUNT_SRC}" >&2
  exit "$rc"
' INT TERM HUP

# ── Preflight — root & commands ───────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pveversion pvesh pveam pct pvesm qm curl python3 ip awk grep sed sort paste seq readlink cp chmod chown stat dpkg head tr ls mkdir flock mktemp mv rm tail bash timeout; do
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
  Hardening:         reviewed v1.1.1 | $HARDENING_PROFILE | rp_filter=$HARDENING_RP_FILTER
                     keep SSH=$HARDENING_KEEP_SSH | remove Postfix=$HARDENING_REMOVE_POSTFIX
  Cleanup on fail:   $CLEANUP_ON_FAIL (disarmed before first persistent start; host photo data is never removed)
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

# All application/storage/firewall prompts are complete. Add only the final app
# port to the common listener policy; 5432/6379/3003 remain loopback-only.
HARDENING_TCP_PORTS="${APP_PORT}${HARDENING_TCP_PORTS:+ $HARDENING_TCP_PORTS}"

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
# The counter bounds DHCP polling; only elapsed attempts matter.
# shellcheck disable=SC2034
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
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  export LANG=C.UTF-8
  export LC_ALL=C.UTF-8
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
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  apt-get update -qq
  apt-get install -y locales curl ca-certificates iproute2 python3 ufw iptables util-linux podman tar gzip ${PODMAN_FUSE_PKG}
  sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
  ln -sf /usr/share/zoneinfo/${APP_TZ} /etc/localtime
  echo '${APP_TZ}' > /etc/timezone
"

# SSH/Postfix removal is owned by the late shared hardening block.

# ── UFW inside the CT ─────────────────────────────────────────────────────────
# Fresh CT only. Network=host uses this CT's INPUT chain.
pct exec "$CT_ID" -- bash -s -- "$APP_PORT" "${UFW_ALLOWED_SOURCES[@]}" <<'UFWSETUP'
set -euo pipefail
export LC_ALL=C
port=$1; shift
(( $# > 0 )) || { echo "ERROR: No allowed source addresses."; false; }
iptables -w 5 -S INPUT >/dev/null
ip6tables -w 5 -S INPUT >/dev/null
sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
grep -qx 'IPV6=yes' /etc/default/ufw
# The shared hardening block later backs up and disables UFW sysctl loading.
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
# Persist the original application access choice for repeatable verification.
install -d -m 0755 /opt/immich
python3 - "$port" "$@" <<'UFW_SOURCES_SAVE'
import json, pathlib, sys
path = pathlib.Path('/opt/immich/verification.json')
path.write_text(json.dumps({'app_port': int(sys.argv[1]), 'allowed_sources': sys.argv[2:]}, indent=2) + '\n')
path.chmod(0o644)
UFW_SOURCES_SAVE
UFWSETUP

# Capture the actual selected rules before starting services or applying hardening.
UFW_POLICY_BEFORE=$(pct exec "$CT_ID" -- python3 - <<'UFW_SNAPSHOT'
import hashlib, pathlib, subprocess
for path in ('/etc/ufw/user.rules', '/etc/ufw/user6.rules', '/etc/ufw/ufw.conf'):
    print(path, hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest())
for tool in ('iptables', 'ip6tables'):
    rules = subprocess.check_output([tool, '-w', '5', '-S'])
    print(tool, hashlib.sha256(rules).hexdigest())
UFW_SNAPSHOT
)

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
  for chain in INPUT FORWARD; do
    rules=$("$tool" -w 5 -S "$chain")
    grep -qx -- "-P $chain DROP" <<< "$rules"
  done
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
Volume=${APP_DIR}/microservices-run:/etc/s6-overlay/s6-rc.d/svc-microservices/run:ro
StopTimeout=110
LogDriver=journald

[Service]
ExecStartPre=/usr/local/sbin/immich-ufw-check
ExecStartPre=/usr/local/sbin/immich-worker-prepare
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

# ── Immich verification helper ────────────────────────────────────────────────
# Uses the existing maintenance readiness/image checks plus application-specific
# credentials, schema, storage, ML isolation and selected UFW source checks.
tmp=$(mktemp)
cat > "$tmp" <<'IMMICH_VERIFY'
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
# Reusable creation/post-start verification. Does not restart or update services.
# Arguments: optional --initial (also requires zero initial systemd restarts).
/usr/local/bin/immich-maint.sh check "$@"
python3 - <<'IMMICH_VERIFY_PY'
import ipaddress
import json
import os
import re
from pathlib import Path
import stat
import subprocess
import time
import urllib.request

os.environ['LC_ALL'] = 'C'
os.environ['PATH'] = '/usr/sbin:/usr/bin:/sbin:/bin'
root = Path('/opt/immich')

def require(condition, message):
    if not condition:
        raise SystemExit('ERROR: ' + message)

def run(args, timeout=30):
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
    require(result.returncode == 0, 'Command failed: ' + ' '.join(args[:3]))
    return result.stdout.strip()

def read_env(path):
    values = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        key, value = line.split('=', 1)
        require(key not in values, 'Duplicate key in ' + str(path))
        values[key] = value
    return values

require(os.geteuid() == 0, 'Run inside the Immich CT as root.')
state = read_env(root / '.env')
port = int(state['APP_PORT'])
require(1024 <= port <= 65535 and port not in (5432, 6379, 3003), 'Invalid APP_PORT.')
policy = json.loads((root / 'verification.json').read_text())
require(policy['app_port'] == port, 'Verification policy and APP_PORT differ; review both.')
require(bool(policy['allowed_sources']), 'No saved firewall sources.')
for source in policy['allowed_sources']:
    network = ipaddress.ip_network(source, strict=True)
    tool, prefix = ('ip6tables', 'ufw6') if network.version == 6 else ('iptables', 'ufw')
    run([tool, '-w', '5', '-C', prefix + '-user-input', '-s', source,
         '-p', 'tcp', '-m', 'tcp', '--dport', str(port), '-j', 'ACCEPT'])
print('  Selected IPv4/IPv6 application source rules are present.')

for path in (root / '.env', root / 'immich.env', root / 'postgres.env'):
    info = path.stat()
    require(not path.is_symlink() and info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o600,
            'Expected a root-owned 0600 control file: ' + str(path))

names = {'immich', 'immich-postgres', 'immich-valkey'}
require(set(run(['podman', 'ps', '--format', '{{.Names}}']).splitlines()) == names,
        'Expected exactly the three Immich stack containers running.')
containers = json.loads(run(['podman', 'inspect', *sorted(names)]))
expected_mounts = {
    'immich': {'/photos': (str(root / 'library'), True), '/config': (str(root / 'config'), True),
               '/etc/s6-overlay/s6-rc.d/svc-microservices/run': (str(root / 'microservices-run'), False)},
    'immich-postgres': {'/var/lib/postgresql/data': (str(root / 'postgres'), True)},
    'immich-valkey': {'/etc/valkey/valkey.conf': (str(root / 'valkey.conf'), False)},
}
for container in containers:
    name = container['Name'].lstrip('/')
    require(container['State']['Running'], name + ' is not running.')
    require(container['HostConfig']['NetworkMode'] == 'host', name + ' must use Network=host.')
    if name == 'immich':
        require(not any(entry.startswith('IMMICH_HOST=') for entry in container['Config']['Env']),
                'The image rejects container-wide IMMICH_HOST; it must be scoped to the worker.')
        worker_file = root / 'microservices-run'
        info = worker_file.stat()
        require(not worker_file.is_symlink() and info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o755,
                'Worker startup must be a regular root-owned 0755 file.')
        worker_text = worker_file.read_text()
        # Podman container inspect reports Image as a bare 64-character ID;
        # the preparation helper records the Quadlet's canonical sha256: ID.
        # Compare full IDs, accepting the optional prefix only on inspect data.
        running_image = container.get('Image')
        require(isinstance(running_image, str), 'Podman did not report the running image ID.')
        image_match = re.fullmatch(r'(?:sha256:)?([a-f0-9]{64})', running_image)
        require(image_match is not None, 'Podman reported an invalid full SHA-256 image ID.')
        running_id = 'sha256:' + image_match.group(1)
        recorded_ids = re.findall(r'^# Lab source image: (.*)$', worker_text, re.M)
        require(len(recorded_ids) == 1, 'Worker startup must record exactly one source image ID.')
        require(re.fullmatch(r'sha256:[a-f0-9]{64}', recorded_ids[0]) is not None,
                'Worker startup has an invalid source image ID.')
        require(recorded_ids[0] == running_id,
                f'Worker source image mismatch: prepared={recorded_ids[0]}, running={running_id}.')
        require(worker_text.count('export IMMICH_HOST=127.0.0.1\n') == 1,
                'Worker-only loopback export is missing or duplicated.')
        require('/usr/local/sbin/immich-worker-prepare' in run(
                ['systemctl', 'show', 'immich.service', '-p', 'ExecStartPre', '--value']),
                'Worker preparation is missing from the generated service.')
    mounts = {m['Destination']: m for m in container['Mounts']}
    for target, (source, writable) in expected_mounts[name].items():
        mount = mounts.get(target, {})
        require(mount.get('Type') == 'bind' and mount.get('Source') == source
                and mount.get('RW') == writable,
                f'{name}: incorrect persistent/config mount at {target}.')
    require(run(['systemctl', 'show', name + '.service', '-p', 'FragmentPath', '--value'])
            .startswith('/run/systemd/generator'), name + ' is not generated by Quadlet.')
    wants = Path('/run/systemd/generator/multi-user.target.wants') / (name + '.service')
    require(wants.exists(), name + ' has no generated boot-start dependency.')

if state.get('PHOTO_MOUNT_SRC'):
    run(['mountpoint', '-q', str(root / 'library')])
for path in (root / 'library', root / 'config'):
    info = path.stat()
    require((info.st_uid, info.st_gid) == (1000, 1000), 'Unexpected Immich ownership: ' + str(path))
pg_uid = int(run(['podman', 'exec', 'immich-postgres', 'id', '-u', 'postgres']))
pg_gid = int(run(['podman', 'exec', 'immich-postgres', 'id', '-g', 'postgres']))
info = (root / 'postgres').stat()
require((info.st_uid, info.st_gid) == (pg_uid, pg_gid), 'PostgreSQL data owner differs from its image user.')
require((root / 'postgres/PG_VERSION').read_text().strip() == '14', 'Unexpected on-disk PostgreSQL major.')
# Tiny, uniquely named probes only; no existing media/config files are modified.
run(['podman', 'exec', '--user', '1000:1000', 'immich', 'sh', '-c', '''
set -eu
probe=
trap 'test -z "$probe" || rm -f -- "$probe"' EXIT
for path in /photos /config; do
  probe=$(mktemp "$path/.immich-verify.XXXXXX")
  printf 'immich-verify\n' > "$probe"
  test "$(cat "$probe")" = immich-verify
  rm -f -- "$probe"
  probe=
done
'''])
print('  Quadlet boot-start, host networking, real mounts, ownership and UID 1000 writes verified.')

def sockets():
    listeners = {}
    for line in run(['ss', '-H', '-lnt']).splitlines():
        fields = line.split()
        require(len(fields) >= 4, 'Unrecognized ss output.')
        addr, number = fields[3].rsplit(':', 1)
        addr = addr.split('%', 1)[0].strip('[]')
        listeners.setdefault(int(number), set()).add(addr)
    return listeners

listeners = sockets()
ml_enabled = not state['APP_TAG'].endswith('-noml')
if ml_enabled and 3003 not in listeners:
    deadline = time.monotonic() + int(state['INITIAL_WAIT_SECONDS'])
    while 3003 not in listeners and time.monotonic() < deadline:
        time.sleep(2)
        listeners = sockets()
require('0.0.0.0' in listeners.get(port, set()), 'Immich has no expected external IPv4 listener.')
for number, label in ((5432, 'PostgreSQL'), (6379, 'Valkey')):
    require(listeners.get(number) == {'127.0.0.1'}, label + ' must listen only on 127.0.0.1.')
ml_listeners = listeners.get(3003, set())
require(not ml_enabled or ml_listeners == {'127.0.0.1'}, 'Enabled ML must listen only on 127.0.0.1:3003.')
for addr in ml_listeners:
    require(addr != '*' and ipaddress.ip_address(addr).is_loopback, 'Machine learning is externally exposed.')
print('  PostgreSQL/Valkey loopback isolation verified; ML ' + ('loopback listener verified.' if ml_enabled else 'omitted by -noml image.'))

# The microservices worker uses port 0: verify its owner and actual binding,
# never add whichever ephemeral port was chosen to the external allowlist.
top = run(['podman', 'top', 'immich', 'hpid', 'comm']).splitlines()
worker_pids = set()
for line in top[1:]:
    fields = line.split()
    require(len(fields) == 2 and fields[0].isdigit(), 'Unrecognized Immich process inventory.')
    if fields[1] == 'immich':
        worker_pids.add(int(fields[0]))
require(worker_pids, 'No Immich microservices process found.')
worker_ports = set()
for line in run(['ss', '-H', '-lntp']).splitlines():
    fields = line.split()
    require(len(fields) >= 4, 'Unrecognized ss process output.')
    owners = {int(value) for value in re.findall(r'pid=(\d+)', line)}
    if not owners.intersection(worker_pids):
        continue
    addr, number = fields[3].rsplit(':', 1)
    addr = addr.split('%', 1)[0].strip('[]')
    require(addr == '127.0.0.1',
            f'Immich microservices must bind only to 127.0.0.1; found {fields[3]}.')
    worker_ports.add(int(number))
require(worker_ports, 'No owned microservices loopback listener found.')
print('  Microservices loopback listener verified on dynamic TCP port(s): '
      + ', '.join(str(number) for number in sorted(worker_ports)))

with urllib.request.urlopen(f'http://127.0.0.1:{port}/api/server/ping', timeout=10) as response:
    require(response.status == 200 and json.load(response).get('res') == 'pong',
            'Immich ping must return HTTP 200 with JSON res=pong.')
with urllib.request.urlopen(f'http://127.0.0.1:{port}/', timeout=10) as response:
    require(response.status == 200 and 'text/html' in response.headers.get('Content-Type', ''),
            'Immich web UI must return HTTP 200 and HTML.')
require(run(['podman', 'exec', 'immich-valkey', 'valkey-cli', '-h', '127.0.0.1', 'ping']) == 'PONG',
        'Valkey PING failed.')
print('  Immich HTTP 200, JSON pong, web UI and Valkey PONG verified.')

timer = 'immich-update.timer'
if state['AUTO_UPDATE'] == '1':
    run(['systemctl', 'is-enabled', '--quiet', timer])
    run(['systemctl', 'is-active', '--quiet', timer])
else:
    require(run(['systemctl', 'show', timer, '-p', 'UnitFileState', '--value']) == 'disabled'
            and run(['systemctl', 'show', timer, '-p', 'ActiveState', '--value']) == 'inactive',
            'Application auto-update timer must remain disabled/inactive for AUTO_UPDATE=0.')
print('  Application image-update timer matches its separate policy.')

import pathlib, subprocess
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
password = appenv["DB_PASSWORD"]
require(password == pgenv["POSTGRES_PASSWORD"], "App and PostgreSQL credentials differ.")
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
checks.append(("SELECT count(*)=1 FROM pg_extension WHERE extname='vchord'", "t"))
for query, expected in checks:
    result = sql(query, password)
    if result.returncode or result.stdout.strip() != expected:
        raise SystemExit("Database authentication, role, storage or migration verification failed")
# pg_hba_file_rules is administrator-only; do not grant it to the app role.
admin = "immich"
query = "SELECT count(*)=0 FROM pg_hba_file_rules WHERE error IS NOT NULL OR (type LIKE 'host%' AND auth_method <> 'scram-sha-256')"
hba = subprocess.run(["podman", "exec", container, "psql", "-w", "-U", admin, "-d", app, "-tAc", query],
                     text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=15)
if hba.returncode or hba.stdout.strip() != "t":
    raise SystemExit("PostgreSQL host authentication is not consistently SCRAM")
print("  Database credentials, authentication, role, persistent path and schema verified.")

print("  Immich verification: OK")
IMMICH_VERIFY_PY
IMMICH_VERIFY
pct push "$CT_ID" "$tmp" /usr/local/sbin/immich-verify --perms 0755
rm -f -- "$tmp"

# Prepare a worker-only startup override on every app start and image change.
tmp="$(mktemp)"
cat > "$tmp" <<'IMMICH_WORKER_PREPARE'
#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 022
# Called by immich.service before every start, including image updates.
# The image rejects a global IMMICH_HOST. Set it only in the worker run script,
# after with-contenv, while retaining the selected image's remaining startup code.
unit=/etc/containers/systemd/immich.container
target=/opt/immich/microservices-run
[[ $EUID == 0 && -f $unit && ! -L $unit && -d /opt/immich ]]
exec 8>/run/lock/immich-worker-prepare.lock
flock -n 8
image=$(awk -F= '$1=="Image" {print $2}' "$unit")
[[ $image =~ ^sha256:[a-f0-9]{64}$ ]]
[[ $(awk -F= '$1=="Pull" {print $2}' "$unit") == never ]]
if grep -Eq '^Environment=.*IMMICH_HOST=' "$unit" ||
   grep -Eq '^IMMICH_HOST=' /opt/immich/immich.env; then
  echo 'ERROR: Remove the prohibited container-wide IMMICH_HOST setting.' >&2
  exit 1
fi
[[ ! -L $target ]]
tmp=$(mktemp /opt/immich/.microservices-run.XXXXXXXX)
trap 'rm -f -- "$tmp"' EXIT
podman run --rm -i --pull=never --network none --read-only --entrypoint node "$image" - "$image" > "$tmp" <<'WORKER_PREPARE_JS'
const fs = require('node:fs');
const image = process.argv[2];
const file = '/etc/s6-overlay/s6-rc.d/svc-microservices/run';
const original = fs.readFileSync(file, 'utf8');
const compiled = fs.readFileSync('/app/immich/server/dist/workers/microservices.js', 'utf8');
const marker = 'export IMMICH_WORKERS_INCLUDE="microservices"';
if (!original.startsWith('#!/usr/bin/with-contenv bash\n') ||
    original.split('\n').filter(line => line === marker).length !== 1 ||
    /^\s*(?:export\s+)?IMMICH_HOST\s*=/m.test(original) ||
    !compiled.includes('app.listen(0, host)')) {
  throw new Error('Unreviewed microservices startup: refusing to generate a worker override.');
}
const scoped = original.replace(marker,
  marker + '\n# Lab source image: ' + image + '\n' +
  '# Scoped after with-contenv; never exported into the image initializer.\n' +
  'export IMMICH_HOST=127.0.0.1');
process.stdout.write(scoped);
WORKER_PREPARE_JS
bash -n "$tmp"
chmod 0755 "$tmp"
chown 0:0 "$tmp"
if [[ -f $target ]] && cmp -s "$tmp" "$target"; then
  chmod 0755 "$target"
  chown 0:0 "$target"
else
  if [[ -e $target ]]; then
    [[ -f $target ]]
    install -d -m 0700 /var/backups/immich-worker
    backup=$(mktemp -d /var/backups/immich-worker/change.XXXXXXXX)
    cp -a -- "$target" "$backup/microservices-run"
  fi
  mv -fT -- "$tmp" "$target"
fi
printf '  Worker-only loopback startup prepared from %s.\n' "$image"
IMMICH_WORKER_PREPARE
pct push "$CT_ID" "$tmp" /usr/local/sbin/immich-worker-prepare --perms 0755
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
# Preserve the CT if image compatibility or the first persistent start fails.
CLEANUP_ON_FAIL=0
pct exec "$CT_ID" -- systemctl start "$QUADLET_SERVICE"

# Destructive cleanup was disarmed before the first persistent service start.

# ── Initial application readiness ─────────────────────────────────────────────
sleep 30
pct exec "$CT_ID" -- /usr/local/bin/immich-maint.sh check --initial

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

# ── Extra packages ────────────────────────────────────────────────────────────
if [[ "${#EXTRA_PACKAGES[@]}" -gt 0 ]]; then
  pct exec "$CT_ID" -- bash -lc "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
    apt-get install -y ${EXTRA_PACKAGES[*]}
  "
fi

# ── Cleanup packages ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
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
printf '  Verify:     /usr/local/sbin/immich-verify\\n'
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

# ── Common hardening ──────────────────────────────────────────────────────────
# Last package/MOTD writer: later code must not alter managed common settings.
# The reviewed v1.1.1 standalone block is embedded byte-for-byte below.
# It corrects v1.1 scoped IPv6 parsing; all shared policy checks are retained.
# Reassert in the caller: both ERR and INT/TERM/HUP traps honor this flag.
CLEANUP_ON_FAIL=0
# This is a Proxmox-only creator: the guest is entered through pct exec, not SSH.
# pct exec inherits the host process environment. Its SSH_CONNECTION describes
# the host login and would falsely trigger the block's direct-guest SSH guard.
# Clear only this script's inherited marker; the host SSH session is unaffected.
# The standalone block and its safeguard for real guest SSH sessions stay intact.
unset SSH_CONNECTION
# BEGIN EMBEDDED lab-hardening-block.sh v1.1.1
#!/usr/bin/env bash
# ── Shared Debian 13 LXC hardening block ───────────────────────────────────────
# Version: 1.1.1 (2026-09-12; scoped IPv6 listener parsing fix)
# Paste this whole file AFTER the creator's MOTD/cleanup steps and BEFORE its
# final verification/summary. Later MOTD code must not delete 25-lab-hardening.
# Replace its old unattended-upgrades and sysctl sections with this block.
# The initial OS upgrade and application/UFW setup must already have run.
# Keep application-specific ports, source rules, users, health checks and units.
# Creators retain set -Eeo pipefail and their ERR trap; do not invoke this block
# as the condition of an if/! command. Late failures must preserve the CT.
#
# On PVE: an existing running CT_ID is mandatory; all changes run via pct exec.
# Direct: root inside an existing Debian 13 LXC. Other environments are refused.
# Scope: Proxmox service LXCs without routing, including Podman Network=host.
# Routers, VPN gateways and containers using bridge forwarding need another policy.
#
# Features: dual-stack sysctl policy and UFW checks; scoped service removal;
# Debian updates without auto-reboot; conservative dependency cleanup;
# persistent bounded journals; report-only needrestart; APT readiness repair;
# hourly/boot checks, local status reporting, configuration backups.
# No remote downloads of scripts; no changes to app images or Proxmox config.
# Reports are local (journal, status.json, MOTD); no email/webhook is configured.
# Re-running saves a new config backup; package removals have no automatic undo.
# UFW logging and all allow/deny rules retain the installer's existing policy.
#
# Managed paths:
#   /etc/sysctl.d/99-hardening.conf
#   /etc/apt/apt.conf.d/99-lab-hardening
#   /etc/needrestart/conf.d/99-lab-hardening.conf
#   /etc/systemd/journald.conf.d/99-lab-hardening.conf
#   /etc/systemd/system/apt-daily{,-upgrade}.service.d/90-lab-readiness.conf (LXC)
#   /etc/systemd/system/lab-hardening-check.{service,timer}
#   /usr/local/sbin/lab-{apt-wait-online,hardening-check}
#   /etc/update-motd.d/25-lab-hardening
#   /etc/default/ufw (IPT_SYSCTL only); SSH service/socket masks (when SSH removed)
#   /var/lib/lab-hardening/{policy.json,status.json,last-index-refresh,check.lock}
#   /var/backups/lab-hardening/<run>/ (configuration copies and dry-run log)
# References: Debian trixie apt.conf(5), systemd-sysctl(8), ifquery(8),
# journald.conf(5), needrestart(1); kernel.org networking/ip-sysctl.html.
#
# Settings may instead be assigned in the creator's top config section.
HARDENING_PROFILE="${HARDENING_PROFILE:-lxc}"              # lxc; auto remains a compatible alias
HARDENING_RP_FILTER="${HARDENING_RP_FILTER:-1}"            # 1=strict; 2=loose for asymmetric paths
HARDENING_KEEP_SSH="${HARDENING_KEEP_SSH:-0}"              # 0=remove; 1=preserve
HARDENING_REMOVE_POSTFIX="${HARDENING_REMOVE_POSTFIX:-1}"   # 0 for intentional mail service
HARDENING_JOURNAL_DAYS="${HARDENING_JOURNAL_DAYS:-14}"
HARDENING_JOURNAL_MAX_MB="${HARDENING_JOURNAL_MAX_MB:-256}"
HARDENING_JOURNAL_RUNTIME_MB="${HARDENING_JOURNAL_RUNTIME_MB:-64}"
HARDENING_UPDATE_MAX_AGE_HOURS="${HARDENING_UPDATE_MAX_AGE_HOURS:-72}"
# Optional space-separated external listening ports; leave empty to inventory
# only. Loopback listeners are excluded. For DHCP include UDP 68 (and 546 if used).
# Examples: Matrix TCP="8008 8080" UDP="68"; NPM TCP="80 443 81" UDP="68".
# If preserving SSH, include its actual listening port in the TCP list.
HARDENING_TCP_PORTS="${HARDENING_TCP_PORTS:-}"
HARDENING_UDP_PORTS="${HARDENING_UDP_PORTS:-}"

# ── Dispatch into the guest ───────────────────────────────────────────────────
# The subshell isolates the block's options/variables from its parent creator.
# shellcheck disable=SC2034
CLEANUP_ON_FAIL=0
(
set -Eeuo pipefail
export LC_ALL=C
[[ $EUID == 0 ]] || { echo 'ERROR: Run as root.' >&2; exit 1; }
hardening_exec=()
if command -v pveversion >/dev/null 2>&1; then
  [[ ${CT_ID:-} =~ ^[1-9][0-9]+$ ]] || {
    echo 'ERROR: On Proxmox, supply an existing CT_ID; the host is never hardened.' >&2; exit 1;
  }
  pct status "$CT_ID" | grep -qx 'status: running'
  hardening_exec=(pct exec "$CT_ID" --)
fi
"${hardening_exec[@]}" bash -s -- \
  "$HARDENING_PROFILE" "$HARDENING_RP_FILTER" "$HARDENING_KEEP_SSH" \
  "$HARDENING_REMOVE_POSTFIX" "$HARDENING_JOURNAL_DAYS" \
  "$HARDENING_JOURNAL_MAX_MB" "$HARDENING_JOURNAL_RUNTIME_MB" \
  "$HARDENING_UPDATE_MAX_AGE_HOURS" "$HARDENING_TCP_PORTS" \
  "$HARDENING_UDP_PORTS" <<'LAB_HARDENING_GUEST'
set -Eeuo pipefail
umask 022
export LC_ALL=C DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
PROFILE=$1 RP_FILTER=$2 KEEP_SSH=$3 REMOVE_POSTFIX=$4
JOURNAL_DAYS=$5 JOURNAL_MAX_MB=$6 JOURNAL_RUNTIME_MB=$7 UPDATE_MAX_AGE=$8
TCP_PORTS=$9 UDP_PORTS=${10}
[[ $EUID == 0 && -d /run/systemd/system ]] || {
  echo 'ERROR: A running systemd guest and root access are required.' >&2; exit 1;
}
command -v pveversion >/dev/null 2>&1 && {
  echo 'ERROR: Refusing to change a Proxmox host.' >&2; exit 1;
}
# shellcheck disable=SC1091
. /etc/os-release
[[ $ID == debian && $VERSION_ID == 13 ]] || {
  echo 'ERROR: This policy requires Debian 13.' >&2; exit 1;
}
container=$(systemd-detect-virt --container || true)
[[ $container == lxc ]] || {
  echo 'ERROR: This block requires a Debian 13 LXC container.' >&2; exit 1;
}
[[ $PROFILE == lxc || $PROFILE == auto ]] || {
  echo 'ERROR: Only the lxc hardening profile is supported.' >&2; exit 1;
}
PROFILE=lxc
[[ $RP_FILTER == auto ]] && RP_FILTER=1
[[ $KEEP_SSH == auto ]] && KEEP_SSH=0
[[ $RP_FILTER =~ ^[12]$ && $KEEP_SSH =~ ^[01]$ && $REMOVE_POSTFIX =~ ^[01]$ ]] || {
  echo 'ERROR: Invalid hardening setting.' >&2; exit 1;
}
[[ $KEEP_SSH == 1 || -z ${SSH_CONNECTION:-} ]] || {
  echo 'ERROR: Run through pct exec/console before removing SSH, or set HARDENING_KEEP_SSH=1.' >&2; exit 1;
}
for value in "$JOURNAL_DAYS" "$JOURNAL_MAX_MB" "$JOURNAL_RUNTIME_MB" "$UPDATE_MAX_AGE"; do
  [[ $value =~ ^[1-9][0-9]{0,3}$ ]] || { echo 'ERROR: Numeric policy values must be 1..9999.' >&2; exit 1; }
done
for port in $TCP_PORTS $UDP_PORTS; do
  if [[ ! $port =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
    echo 'ERROR: Port lists require space-separated numbers from 1 to 65535.' >&2; exit 1
  fi
done
for command in ufw iptables ip6tables ip ss sysctl python3 systemctl apt-get flock; do
  command -v "$command" >/dev/null || { echo "ERROR: Missing prerequisite: $command" >&2; exit 1; }
done
exec 9>/run/lock/lab-hardening-install.lock
flock -n 9 || { echo 'ERROR: Hardening is already running.' >&2; exit 1; }

# Check before any changes. Existing forwarding usually means bridge/VPN/router
# functionality; do not silently break it with a service-host policy.
for path in /proc/sys/net/ipv4/ip_forward /proc/sys/net/{ipv4,ipv6}/conf/*/forwarding; do
  [[ -r $path && $(cat "$path") == 0 ]] || {
    echo "ERROR: Forwarding enabled/unavailable at $path; review the guest network role." >&2; exit 1;
  }
done
ufw status | grep -qx 'Status: active'
grep -qx 'IPV6=yes' /etc/default/ufw
for tool in iptables ip6tables; do
  prefix=ufw; [[ $tool != ip6tables ]] || prefix=ufw6
  "$tool" -w 5 -S INPUT | grep -qx -- '-P INPUT DROP'
  "$tool" -w 5 -S FORWARD | grep -qx -- '-P FORWARD DROP'
  "$tool" -w 5 -C INPUT -j "$prefix-before-input"
  "$tool" -w 5 -S "$prefix-user-input" >/dev/null
done

# ── Staging and backups ───────────────────────────────────────────────────────
stage=$(mktemp -d /var/tmp/lab-hardening.XXXXXX)
chmod 0700 "$stage"
backup="/var/backups/lab-hardening/$(date -u +%Y%m%dT%H%M%SZ)-$$"
install -d -m 0700 "$backup"
hardening_exit=0
trap 'hardening_exit=$?; rm -rf -- "$stage"; exit "$hardening_exit"' EXIT
trap 'echo "ERROR: Hardening failed near guest line $LINENO. Guest preserved; config backups: $backup" >&2' ERR
install -d -m 0755 /var/lib/lab-hardening
if [[ $(systemctl show lab-hardening-check.timer -p LoadState --value) == loaded ]]; then
  systemctl stop lab-hardening-check.timer
  systemctl stop lab-hardening-check.service
fi

# APT package operations use locks, strict download errors, and report-only
# needrestart. No dist-upgrade is performed late in an already running app install.
apt-get -o DPkg::Lock::Timeout=120 -o APT::Update::Error-Mode=any update
date +%s > "$stage/index-refreshed"
apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends \
  unattended-upgrades needrestart python3-apt ca-certificates procps

mkdir -p "$stage/etc/apt/apt.conf.d" "$stage/etc/needrestart/conf.d" \
  "$stage/etc/systemd/journald.conf.d" "$stage/etc/sysctl.d" \
  "$stage/etc/systemd/system" "$stage/usr/local/sbin" "$stage/etc/update-motd.d"
cat > "$stage/etc/apt/apt.conf.d/99-lab-hardening" <<'APT_POLICY'
// Managed by lab-hardening-block.sh. Debian release stays fixed at trixie.
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
  "origin=Debian,codename=trixie,label=Debian";
  "origin=Debian,codename=trixie-updates,label=Debian";
  "origin=Debian,codename=trixie-security,label=Debian-Security";
};
// Preserve deliberate package blacklists/holds; report them in the check.
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Update::Error-Mode "any";
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
Unattended-Upgrade::Automatic-Reboot "false";
APT_POLICY
cat > "$stage/etc/needrestart/conf.d/99-lab-hardening.conf" <<'NEEDRESTART_POLICY'
# Report only. Package maintainer scripts may still restart their own services.
$nrconf{restart} = 'l';
NEEDRESTART_POLICY
cat > "$stage/etc/systemd/journald.conf.d/99-lab-hardening.conf" <<JOURNAL_POLICY
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=${JOURNAL_MAX_MB}M
SystemKeepFree=128M
RuntimeMaxUse=${JOURNAL_RUNTIME_MB}M
MaxRetentionSec=${JOURNAL_DAYS}day
RateLimitIntervalSec=30s
RateLimitBurst=10000
JOURNAL_POLICY

# ── Network policy ───────────────────────────────────────────────────────────
cat > "$stage/etc/sysctl.d/99-hardening.conf" <<SYSCTL_POLICY
# Managed by lab-hardening-block.sh: non-routing Debian 13 LXC.
# Forwarding comes first because changing it can reset IPv4 interface settings.
net.ipv4.ip_forward = 0
net.ipv4.conf.all.forwarding = 0
net.ipv4.conf.default.forwarding = 0
net.ipv4.conf.*.forwarding = 0
net.ipv6.conf.all.forwarding = 0
net.ipv6.conf.default.forwarding = 0
net.ipv6.conf.*.forwarding = 0
net.ipv4.conf.all.rp_filter = $RP_FILTER
net.ipv4.conf.default.rp_filter = $RP_FILTER
net.ipv4.conf.*.rp_filter = $RP_FILTER
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.*.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.*.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.*.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.*.accept_redirects = 0
# -1 rejects all IPv6 routing headers; 0 would still accept type 2.
net.ipv6.conf.all.accept_source_route = -1
net.ipv6.conf.default.accept_source_route = -1
net.ipv6.conf.*.accept_source_route = -1
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
# Preserve IPv6 addressing, router advertisements, autoconf and DHCP.
SYSCTL_POLICY

# ── APT readiness wrapper ─────────────────────────────────────────────────────
# No network-manager disabling, DHCP changes or network restarts. Re-evaluate
# ownership on every APT run; delegate to Debian's helper unless proven safe.
cat > "$stage/usr/local/sbin/lab-apt-wait-online" <<'APT_WAIT_HELPER'
#!/usr/bin/python3
import json
import os
import subprocess
os.environ['LC_ALL'] = 'C'
os.environ['PATH'] = '/usr/sbin:/usr/bin:/sbin:/bin'

def capture(args):
    return subprocess.run(args, text=True, capture_output=True, timeout=15, check=True).stdout

try:
    if capture(['systemd-detect-virt', '--container']).strip() == 'lxc':
        capture(['systemctl', 'is-active', 'networking.service'])
        rows = [line.split() for line in capture(
            ['networkctl', 'list', '--no-legend', '--no-pager']).splitlines() if line.strip()]
        # An unfamiliar output shape cannot authorize bypassing the stock check.
        if rows and all(len(row) == 5 and row[4] == 'unmanaged' for row in rows):
            configured = set(capture(['ifquery', '--list']).split())
            addresses = json.loads(capture(['ip', '-j', '-4', 'address', 'show']))
            routes = json.loads(capture(['ip', '-j', '-4', 'route', 'show', 'default']))
            for link in addresses:
                name = link['ifname']
                if (name in configured and 'UP' in link.get('flags', [])
                        and any(a.get('scope') == 'global' for a in link.get('addr_info', []))
                        and any(r.get('dev') == name for r in routes)):
                    capture(['ifquery', '--state', name])
                    raise SystemExit(0)
except (OSError, subprocess.SubprocessError, ValueError, KeyError):
    pass
os.execv('/usr/lib/apt/apt-helper', ['apt-helper', 'wait-online'])
APT_WAIT_HELPER
# Only replace Debian's single stock pre-check, or our own earlier wrapper.
# Preserve unknown/custom ExecStartPre sequences by refusing to replace them.
for unit in apt-daily.service apt-daily-upgrade.service; do
  systemctl show "$unit" -p ExecStartPre --value > "$stage/precheck"
  python3 - "$stage/precheck" <<'APT_PRECHECK'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
paths = re.findall(r'path=([^ ;]+)', text)
if paths not in (['/usr/lib/apt/apt-helper'], ['/usr/local/sbin/lab-apt-wait-online']):
    raise SystemExit('ERROR: Custom APT ExecStartPre detected; preserve it and review integration.')
if paths == ['/usr/lib/apt/apt-helper'] and not re.search(r'argv\[\]=/usr/lib/apt/apt-helper wait-online\s*;', text):
    raise SystemExit('ERROR: Unexpected apt-helper pre-check arguments.')
APT_PRECHECK
  mkdir -p "$stage/etc/systemd/system/$unit.d"
  cat > "$stage/etc/systemd/system/$unit.d/90-lab-readiness.conf" <<'APT_DROPIN'
[Service]
ExecStartPre=
ExecStartPre=-/usr/local/sbin/lab-apt-wait-online
APT_DROPIN
done

# ── Reusable verification/report helper ────────────────────────────────────────
# This helper reads policy/runtime state. Its only writes are its lock and report.
# It never changes firewall rules, installs updates or restarts applications.
cat > "$stage/usr/local/sbin/lab-hardening-check" <<'CHECK_HELPER'
#!/usr/bin/python3
import fcntl
import glob
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

os.environ['LC_ALL'] = 'C'
os.environ['PATH'] = '/usr/sbin:/usr/bin:/sbin:/bin'

STATE = Path('/var/lib/lab-hardening')
errors, warnings, listeners = [], [], []

def run(args, timeout=30):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip()
    except (OSError, subprocess.SubprocessError) as exc:
        errors.append(f'Cannot run {args[0]}: {exc}')
        return 127, ''

def require(condition, message):
    if not condition:
        errors.append(message)

def read(path):
    try:
        return Path(path).read_text()
    except OSError as exc:
        errors.append(f'Cannot read {path}: {exc}')
        return ''

if os.geteuid() != 0:
    raise SystemExit('Run lab-hardening-check as root.')
lock = open(STATE / 'check.lock', 'a')
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit('A hardening check is already running.')
try:
    policy = json.loads(read(STATE / 'policy.json'))
    for path, digest in policy['files'].items():
        try:
            require(hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest,
                    f'Managed file changed: {path}; review and rerun the hardening block.')
        except OSError:
            errors.append(f'Managed file missing: {path}')

    # Runtime readback, including dotted interface names through procfs globbing.
    for line in read('/etc/sysctl.d/99-hardening.conf').splitlines():
        line = line.split('#', 1)[0].strip()
        if not line:
            continue
        key, expected = (part.strip() for part in line.split('=', 1))
        paths = glob.glob('/proc/sys/' + key.replace('.', '/'))
        require(bool(paths), f'Required sysctl unavailable: {key}')
        for path in paths:
            require(read(path).strip() == expected, f'Sysctl mismatch: {path}, expected {expected}')

    rc, status = run(['ufw', 'status'])
    require(rc == 0 and 'Status: active' in status.splitlines(), 'UFW is inactive.')
    ufw_defaults = read('/etc/default/ufw')
    require(re.search(r'^IPV6=yes$', ufw_defaults, re.M), 'UFW IPv6 support disabled.')
    require(re.search(r'^IPT_SYSCTL=$', ufw_defaults, re.M), 'UFW sysctl loading is enabled.')
    for tool, prefix in [('iptables', 'ufw'), ('ip6tables', 'ufw6')]:
        for chain in ['INPUT', 'FORWARD']:
            rc, rules = run([tool, '-w', '5', '-S', chain])
            require(rc == 0 and f'-P {chain} DROP' in rules.splitlines(), f'{tool} {chain} is not DROP.')
        rc, _ = run([tool, '-w', '5', '-C', 'INPUT', '-j', prefix + '-before-input'])
        require(rc == 0, f'{tool} UFW INPUT hook is missing.')
        rc, _ = run([tool, '-w', '5', '-S', prefix + '-user-input'])
        require(rc == 0, f'{tool} UFW user chain is missing.')

    # APT lists are compared as sets: vendor/local duplication cannot widen policy.
    import apt_pkg
    apt_pkg.init()
    cfg = apt_pkg.config
    origins = {
        'origin=Debian,codename=trixie,label=Debian',
        'origin=Debian,codename=trixie-updates,label=Debian',
        'origin=Debian,codename=trixie-security,label=Debian-Security',
    }
    require(set(cfg.value_list('Unattended-Upgrade::Origins-Pattern')) == origins,
            'Effective unattended-upgrade origins differ from policy.')
    require(not cfg.value_list('Unattended-Upgrade::Allowed-Origins'), 'Additional legacy Allowed-Origins exist.')
    for key, expected in {
        'APT::Periodic::Enable': '1', 'APT::Periodic::Update-Package-Lists': '1',
        'APT::Periodic::Unattended-Upgrade': '1', 'APT::Periodic::AutocleanInterval': '7',
        'APT::Update::Error-Mode': 'any',
        'Unattended-Upgrade::Automatic-Reboot': 'false',
        'Unattended-Upgrade::InstallOnShutdown': 'false',
        'Unattended-Upgrade::Remove-New-Unused-Dependencies': 'true',
        'Unattended-Upgrade::Remove-Unused-Dependencies': 'false',
        'Unattended-Upgrade::Remove-Unused-Kernel-Packages': 'false',
    }.items():
        require(cfg.find(key) == expected, f'APT policy conflict: {key}')
    if cfg.value_list('Unattended-Upgrade::Package-Blacklist'):
        warnings.append('An unattended-upgrades blacklist is active; review excluded packages.')
    if cfg.value_list('Unattended-Upgrade::Package-Whitelist'):
        warnings.append('An unattended-upgrades whitelist is active; review update coverage.')
    rc, holds = run(['apt-mark', 'showhold'])
    require(rc == 0, 'Cannot inspect held packages.')
    if holds:
        warnings.append('Held packages: ' + ', '.join(holds.splitlines()))
    for unit in ['ufw.service', 'unattended-upgrades.service', 'apt-daily.timer',
                 'apt-daily-upgrade.timer', 'lab-hardening-check.timer']:
        require(run(['systemctl', 'is-enabled', '--quiet', unit])[0] == 0, f'{unit} is not enabled.')
        require(run(['systemctl', 'is-active', '--quiet', unit])[0] == 0, f'{unit} is not active.')
    for unit in ['apt-daily.service', 'apt-daily-upgrade.service']:
        rc, result = run(['systemctl', 'show', unit, '-p', 'Result', '--value'])
        require(rc == 0 and result == 'success', f'{unit} last result: {result or "unknown"}')
    now = time.time()
    stamps = [Path('/var/lib/apt/periodic/update-stamp'), STATE / 'last-index-refresh']
    last_refresh = max((p.stat().st_mtime for p in stamps if p.exists()), default=0)
    require(now - last_refresh <= policy['update_max_age_hours'] * 3600,
            'APT indexes have no recent recorded refresh; inspect apt-daily.service.')

    # Verify the merged journald settings; commented defaults are not assignments.
    rc, journal = run(['systemd-analyze', 'cat-config', 'systemd/journald.conf'])
    require(rc == 0, 'Cannot inspect journald policy.')
    effective = {}
    section = ''
    for line in journal.splitlines():
        line = line.strip()
        if line.startswith('['):
            section = line
        elif section == '[Journal]' and '=' in line and not line.startswith(('#', ';')):
            k, v = line.split('=', 1)
            effective[k.strip()] = v.strip()
    for key, expected in policy['journal'].items():
        require(effective.get(key) == expected, f'Journald policy conflict: {key}')
    require(run(['systemctl', 'is-active', '--quiet', 'systemd-journald.service'])[0] == 0,
            'Journald is not active.')
    require(bool(glob.glob('/var/log/journal/*/*.journal')), 'Persistent journal files are missing.')

    removed = []
    if not policy['keep_ssh']:
        removed.append('openssh-server')
    if policy['remove_postfix']:
        removed.append('postfix')
    for package in removed:
        _, status = run(['dpkg-query', '-W', '-f=${db:Status-Status}', package])
        require(status != 'installed', f'Unwanted package installed: {package}')
    if not policy['keep_ssh']:
        for unit in ['ssh.service', 'ssh.socket']:
            require(run(['systemctl', 'is-enabled', unit])[1] == 'masked', f'{unit} is not masked.')
            require(run(['systemctl', 'is-active', '--quiet', unit])[0] != 0, f'{unit} is active.')

    # Inventory excludes loopback; optional port lists verify external listeners.
    rc, sockets = run(['ss', '-H', '-lntu'])
    require(rc == 0, 'Cannot inspect listening sockets.')
    for line in sockets.splitlines():
        fields = line.split()
        if len(fields) < 5:
            errors.append('Unrecognized ss output.')
            continue
        proto, endpoint = fields[0], fields[4]
        addr, port = endpoint.rsplit(':', 1)
        # ss may print [IPv6]%interface:port or [IPv6%interface]:port.
        addr = addr.split('%', 1)[0].strip('[]')
        try:
            if ipaddress.ip_address(addr).is_loopback:
                continue
        except ValueError:
            if addr != '*':
                errors.append(f'Unrecognized socket address: {addr}')
        listeners.append(f'{proto} {endpoint}')
        allowed = policy.get(proto + '_ports', [])
        if allowed:
            require(int(port) in allowed, f'Unexpected external listener: {proto} {endpoint}')
    # needrestart's explicit batch/list mode cannot restart applications.
    rc, restart = run(['needrestart', '-b', '-r', 'l', '-l'], timeout=90)
    require(rc == 0, 'needrestart report failed.')
    requests = [line for line in restart.splitlines()
                if line.startswith(('NEEDRESTART-SVC:', 'NEEDRESTART-CONT:', 'NEEDRESTART-SESS:'))]
    if requests:
        warnings.append('Processes need a reviewed restart: ' + '; '.join(requests))
except Exception as exc:
    errors.append(f'Check could not complete: {type(exc).__name__}: {exc}')

status = 'FAIL' if errors else ('WARN' if warnings else 'OK')
report = {'status': status, 'checked_at': int(time.time()), 'errors': errors,
          'warnings': warnings, 'external_listeners': listeners}
temporary = STATE / ('status.' + str(os.getpid()) + '.tmp')
temporary.write_text(json.dumps(report, indent=2) + '\n')
temporary.chmod(0o644)
os.replace(temporary, STATE / 'status.json')
print('Lab hardening: ' + status)
for entry in errors:
    print('ERROR: ' + entry)
for entry in warnings:
    print('WARNING: ' + entry)
print('External listeners: ' + (', '.join(listeners) or 'none'))
raise SystemExit(1 if errors else 0)
CHECK_HELPER

cat > "$stage/etc/systemd/system/lab-hardening-check.service" <<'CHECK_SERVICE'
[Unit]
Description=Verify lab hardening and report update/restart status
After=network.target systemd-journal-flush.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/lab-hardening-check
Nice=10
TimeoutStartSec=240
StandardOutput=journal
StandardError=journal
CHECK_SERVICE
cat > "$stage/etc/systemd/system/lab-hardening-check.timer" <<'CHECK_TIMER'
[Unit]
Description=Check lab hardening after boot and hourly
[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
RandomizedDelaySec=60
Unit=lab-hardening-check.service
[Install]
WantedBy=timers.target
CHECK_TIMER
cat > "$stage/etc/update-motd.d/25-lab-hardening" <<'MOTD_HELPER'
#!/usr/bin/python3
import json
from pathlib import Path
import time
try:
    p = json.loads(Path('/var/lib/lab-hardening/status.json').read_text())
    stale = time.time() - p['checked_at'] > 3 * 3600
    print('  Hardening: ' + ('STALE' if stale else p['status'])
          + ' | root check: /usr/local/sbin/lab-hardening-check')
except (OSError, ValueError, KeyError):
    print('  Hardening: not yet verified | root check: /usr/local/sbin/lab-hardening-check')
MOTD_HELPER

# ── Install managed files atomically, preserving previous configuration ────────
python3 - "$stage" "$backup" <<'INSTALL_FILES'
import os, pathlib, shutil, sys, tempfile
stage, backup = map(pathlib.Path, sys.argv[1:])
for source in sorted(stage.rglob('*')):
    if not source.is_file() or source.parent == stage:
        continue
    relative = source.relative_to(stage)
    target = pathlib.Path('/') / relative
    if target.is_symlink():
        raise SystemExit(f'ERROR: Refusing to overwrite symlink: {target}')
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        saved = backup / relative
        saved.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(target, saved)
    fd, temporary = tempfile.mkstemp(prefix='.lab-hardening-', dir=target.parent)
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(source.read_bytes())
        mode = 0o755 if str(relative).startswith(('usr/local/sbin/', 'etc/update-motd.d/')) else 0o644
        os.chmod(temporary, mode)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
# Preserve all UFW policy/rules; only stop its competing sysctl loader.
target = pathlib.Path('/etc/default/ufw')
saved = backup / 'etc/default/ufw'
saved.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(target, saved)
import re
text, count = re.subn(r'^IPT_SYSCTL=.*$', 'IPT_SYSCTL=', target.read_text(), flags=re.M)
if count != 1:
    raise SystemExit('ERROR: Expected one IPT_SYSCTL assignment in /etc/default/ufw.')
fd, temporary = tempfile.mkstemp(prefix='.lab-ufw-', dir=target.parent)
with os.fdopen(fd, 'w') as out:
    out.write(text)
os.chmod(temporary, target.stat().st_mode & 0o777)
os.replace(temporary, target)
INSTALL_FILES
install -m 0644 "$stage/index-refreshed" /var/lib/lab-hardening/last-index-refresh

# ── Remove and verify unwanted services ───────────────────────────────────────
remove_packages=()
if [[ $KEEP_SSH == 0 ]]; then
  for unit in ssh.service ssh.socket; do
    if [[ $(systemctl show "$unit" -p LoadState --value) != not-found ]]; then
      systemctl stop "$unit"
    fi
  done
  remove_packages+=(openssh-server)
fi
[[ $REMOVE_POSTFIX == 0 ]] || remove_packages+=(postfix)
installed_remove=()
for package in "${remove_packages[@]}"; do
  if [[ $(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true) == installed ]]; then
    installed_remove+=("$package")
  fi
done
if (( ${#installed_remove[@]} > 0 )); then
  # No blanket autoremove: apps outside dpkg may use packages marked automatic.
  apt-get -o DPkg::Lock::Timeout=120 purge -y "${installed_remove[@]}"
fi
if [[ $KEEP_SSH == 0 ]]; then
  systemctl mask ssh.service ssh.socket
fi

# ── Activate common policy ────────────────────────────────────────────────────
systemctl daemon-reload
install -d -o root -g systemd-journal -m 2755 /var/log/journal
systemctl restart systemd-journald.service
journalctl --flush
/usr/lib/systemd/systemd-sysctl --strict --prefix=/net/ipv4 --prefix=/net/ipv6
systemctl enable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer
echo 'Checking unattended upgrades without installing updates...'
if ! timeout 300 unattended-upgrade --dry-run --debug > "$backup/unattended-dry-run.log" 2>&1; then
  tail -n 40 "$backup/unattended-dry-run.log" >&2
  false
fi

# Store expected settings and file hashes for drift detection. No secrets.
python3 - "$stage" "$PROFILE" "$KEEP_SSH" "$REMOVE_POSTFIX" "$JOURNAL_DAYS" \
  "$JOURNAL_MAX_MB" "$JOURNAL_RUNTIME_MB" "$UPDATE_MAX_AGE" "$TCP_PORTS" "$UDP_PORTS" <<'SAVE_POLICY'
import hashlib, json, os, pathlib, sys
stage = pathlib.Path(sys.argv[1])
_, _, profile, keep, remove, days, maximum, runtime, age, tcp, udp = sys.argv
files = {}
for source in stage.rglob('*'):
    if source.is_file() and source.parent != stage:
        target = pathlib.Path('/') / source.relative_to(stage)
        files[str(target)] = hashlib.sha256(target.read_bytes()).hexdigest()
policy = {'profile': profile, 'keep_ssh': keep == '1', 'remove_postfix': remove == '1',
          'update_max_age_hours': int(age), 'tcp_ports': list(map(int, tcp.split())),
          'udp_ports': list(map(int, udp.split())), 'files': files,
          'journal': {'Storage': 'persistent', 'Compress': 'yes', 'SystemMaxUse': maximum + 'M',
                      'SystemKeepFree': '128M', 'RuntimeMaxUse': runtime + 'M',
                      'MaxRetentionSec': days + 'day', 'RateLimitIntervalSec': '30s', 'RateLimitBurst': '10000'}}
target = pathlib.Path('/var/lib/lab-hardening/policy.json')
temporary = target.with_suffix('.tmp')
temporary.write_text(json.dumps(policy, indent=2) + '\n')
temporary.chmod(0o644)
os.replace(temporary, target)
SAVE_POLICY
systemctl enable --now lab-hardening-check.timer
if ! systemctl start lab-hardening-check.service; then
  journalctl -u lab-hardening-check.service -n 50 --no-pager >&2
  false
fi
cat /var/lib/lab-hardening/status.json
printf '\nShared hardening applied (%s). Backups: %s\n' "$PROFILE" "$backup"
echo 'Manual check: /usr/local/sbin/lab-hardening-check'
echo 'Local reports: /var/lib/lab-hardening/status.json and journalctl -u lab-hardening-check'
echo 'Application image updates, source-specific UFW rules and app health remain with the creator.'
LAB_HARDENING_GUEST
)
# ── End shared hardening block ────────────────────────────────────────────────
# END EMBEDDED lab-hardening-block.sh v1.1.1

# ── Final verification ────────────────────────────────────────────────────────
# Direct commands keep Bash failure handling active. WARN is successful; FAIL
# from common hardening or Immich verification stops all success reporting.
pct exec "$CT_ID" -- /usr/local/sbin/immich-verify --initial
UFW_POLICY_AFTER=$(pct exec "$CT_ID" -- python3 - <<'UFW_SNAPSHOT'
import hashlib, pathlib, subprocess
for path in ('/etc/ufw/user.rules', '/etc/ufw/user6.rules', '/etc/ufw/ufw.conf'):
    print(path, hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest())
for tool in ('iptables', 'ip6tables'):
    rules = subprocess.check_output([tool, '-w', '5', '-S'])
    print(tool, hashlib.sha256(rules).hexdigest())
UFW_SNAPSHOT
)
[[ $UFW_POLICY_AFTER == "$UFW_POLICY_BEFORE" ]] || {
  echo "ERROR: UFW rules changed after initial setup; CT $CT_ID is preserved for review." >&2
  false
}
echo "  Original UFW rule files and live IPv4/IPv6 filter rules are unchanged."
# Refresh status after all application checks; no packages/MOTD writes follow.
pct exec "$CT_ID" -- /usr/local/sbin/lab-hardening-check
HARDENING_STATUS=$(pct exec "$CT_ID" -- python3 -c 'import json; print(json.load(open("/var/lib/lab-hardening/status.json"))["status"])')
[[ $HARDENING_STATUS == OK || $HARDENING_STATUS == WARN ]] || {
  echo "ERROR: Common hardening did not pass; CT $CT_ID is preserved." >&2
  false
}

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
  HARDENING     $HARDENING_STATUS | Debian updates enabled; no automatic reboot
  AUTO-UPDATE   $AUTO_UPDATE | daily $UPDATE_TIME ($APP_TZ) (application images only)
  IMAGES        exact local IDs, Pull=never; old images retained for review

  RUN ON THE PROXMOX HOST
    pct enter $CT_ID
    pct exec $CT_ID -- /usr/local/bin/immich-maint.sh version

  RUN INSIDE THE CT
    /usr/local/sbin/immich-verify
    /usr/local/sbin/lab-hardening-check
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
echo "    Hardening: ${HARDENING_STATUS} | /var/lib/lab-hardening/status.json"
echo "    OS updates: automatic Debian packages; no automatic reboot; needrestart reports only."
echo "    Verify:   pct exec $CT_ID -- /usr/local/sbin/immich-verify"
echo "              pct exec $CT_ID -- /usr/local/sbin/lab-hardening-check"
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
echo "    PostgreSQL (5432), Valkey (6379), ML (3003) and the dynamic microservices listener are bound to 127.0.0.1."
if [[ "$PODMAN_FUSE_OVERLAY" -eq 1 ]]; then
  echo "    Backups: fuse=1 + fuse-overlayfs can deadlock under snapshot-mode vzdump/PBS (freezer)."
  echo "             Use stop-mode backups for this CT, or test PODMAN_FUSE_OVERLAY=0."
fi
echo "    Extra config (env vars, HW transcoding devices): edit ${QUADLET_FILE}, then systemctl daemon-reload && systemctl restart immich.service"
echo ""
