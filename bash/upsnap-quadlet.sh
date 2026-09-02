#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID=""                             # empty = auto-assign via pvesh; set e.g. CT_ID=120 to pin
HN="upsnap"
CPU=1
RAM=512
DISK=4
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# UpSnap / Podman + Quadlet
APP_PORT=8090                        # UpSnap binds this port on the CT interface (Network=host)
APP_TZ="Europe/Berlin"               # container timezone — cron schedules in UpSnap use it
TAGS="upsnap;podman;quadlet;lxc"

# UpSnap settings (become Environment= lines in the Quadlet unit)
# Reference: https://github.com/seriousm4x/UpSnap/blob/master/docker-compose.yml
UPSNAP_WEBSITE_TITLE="UpSnap"        # browser/page title
UPSNAP_INTERVAL="*/10 * * * * *"     # device ping interval, 6-field cron (seconds first)
UPSNAP_SCAN_RANGE=""                 # e.g. 192.168.1.0/24 ; blank = no scan-range preset (nmap discovery)
UPSNAP_SCAN_TIMEOUT="500ms"          # nmap --host-timeout for discovery
UPSNAP_PING_PRIVILEGED="true"        # true = raw ICMP (needs NET_RAW, granted below); false needs ping_group_range

# Images / versions
# UpSnap: pinned full version (default) from https://github.com/seriousm4x/UpSnap/releases
# or "latest" to track upstream. Major-only tags (5) are rejected.
APP_IMAGE_REPO="ghcr.io/seriousm4x/upsnap"
APP_TAG="5.5.0"                      # full version like 5.5.0, or "latest"
DEBIAN_VERSION=13

# Auto-update policy
# AUTO_UPDATE=0 (default): timer installed but disabled; manual updates via
#   upsnap-maint.sh update <tag> / auto-update
# AUTO_UPDATE=1: upsnap-update.timer re-pulls the CURRENT tag (pinned or latest)
#   daily at UPDATE_TIME and restarts only if the image ID changed; a failed
#   health check rolls back to the previous image.
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
APP_DIR="/opt/upsnap"
APP_IMAGE="${APP_IMAGE_REPO}:${APP_TAG}"
QUADLET_FILE="/etc/containers/systemd/upsnap.container"
QUADLET_SERVICE="upsnap.service"

# ── Custom configs created by this script ─────────────────────────────────────
#   /etc/containers/systemd/upsnap.container  (Quadlet unit — source of truth, holds UPSNAP_* env)
#   /opt/upsnap/.env                          (runtime state — read by maint script)
#   /opt/upsnap/data/                         (PocketBase SQLite DB, users, devices → /app/pb_data)
#   /usr/local/bin/upsnap-maint.sh            (maintenance helper)
#   /etc/systemd/system/upsnap-update.service
#   /etc/systemd/system/upsnap-update.timer
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/sysctl.d/99-hardening.conf

# ── Config validation ─────────────────────────────────────────────────────────
[[ "$HN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || { echo "  ERROR: HN is not a valid hostname: $HN" >&2; exit 1; }
[[ "$CPU" =~ ^[0-9]+$ ]] && (( CPU >= 1 )) || { echo "  ERROR: CPU must be a positive integer." >&2; exit 1; }
[[ "$RAM" =~ ^[0-9]+$ ]] && (( RAM >= 256 )) || { echo "  ERROR: RAM must be >= 256 MB." >&2; exit 1; }
[[ "$DISK" =~ ^[0-9]+$ ]] && (( DISK >= 1 )) || { echo "  ERROR: DISK must be >= 1 GB." >&2; exit 1; }
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }
[[ "$APP_PORT" =~ ^[0-9]+$ ]] || { echo "  ERROR: APP_PORT must be numeric." >&2; exit 1; }
(( APP_PORT >= 1 && APP_PORT <= 65535 )) || { echo "  ERROR: APP_PORT must be between 1 and 65535." >&2; exit 1; }
[[ "$AUTO_UPDATE" =~ ^[01]$ ]] || { echo "  ERROR: AUTO_UPDATE must be 0 or 1." >&2; exit 1; }
[[ "$PODMAN_FUSE_OVERLAY" =~ ^[01]$ ]] || { echo "  ERROR: PODMAN_FUSE_OVERLAY must be 0 or 1." >&2; exit 1; }
[[ "$CLEANUP_ON_FAIL" =~ ^[01]$ ]] || { echo "  ERROR: CLEANUP_ON_FAIL must be 0 or 1." >&2; exit 1; }
# Image repo is interpolated into podman, sed, the Quadlet unit and .env.
[[ "$APP_IMAGE_REPO" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*[A-Za-z0-9]$ ]] || {
  echo "  ERROR: APP_IMAGE_REPO must look like registry/namespace/name (no tag, no spaces)." >&2
  exit 1
}
# UpSnap: "latest" or full semver (5.3.1). Major-only tags (5) are rejected —
# they hide which line is running without the simplicity of "latest".
[[ "$APP_TAG" == "latest" || "$APP_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: APP_TAG must be 'latest' or a full version like 5.3.1 (major-only tags like 5 are not accepted)." >&2
  exit 1
}
[[ "$UPDATE_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "  ERROR: UPDATE_TIME must be HH:MM (24h), e.g. 03:00." >&2; exit 1; }
[[ -e "/usr/share/zoneinfo/${APP_TZ}" ]] || { echo "  ERROR: APP_TZ not found in /usr/share/zoneinfo: $APP_TZ" >&2; exit 1; }
[[ "$APP_TZ" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)+$ ]] || { echo "  ERROR: APP_TZ contains invalid characters." >&2; exit 1; }
# The following land in Environment= lines of the Quadlet unit (systemd quoting).
[[ "$UPSNAP_WEBSITE_TITLE" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]{0,63}$ ]] || {
  echo "  ERROR: UPSNAP_WEBSITE_TITLE must be 1-64 chars of letters, digits, spaces, dot, underscore or dash." >&2; exit 1;
}
[[ "$UPSNAP_INTERVAL" =~ ^[0-9*/,A-Za-z@-]+(\ [0-9*/,A-Za-z-]+){0,5}$ ]] || {
  echo "  ERROR: UPSNAP_INTERVAL must be a cron expression like '*/10 * * * * *' or '@every 10s'." >&2; exit 1;
}
if [[ -n "$UPSNAP_SCAN_RANGE" ]]; then
  [[ "$UPSNAP_SCAN_RANGE" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] \
    || { echo "  ERROR: UPSNAP_SCAN_RANGE must be IPv4 CIDR (e.g. 192.168.1.0/24): $UPSNAP_SCAN_RANGE" >&2; exit 1; }
fi
[[ "$UPSNAP_SCAN_TIMEOUT" =~ ^[0-9]+(ms|s|m)$ ]] || { echo "  ERROR: UPSNAP_SCAN_TIMEOUT must be a duration like 500ms or 2s." >&2; exit 1; }
[[ "$UPSNAP_PING_PRIVILEGED" =~ ^(true|false)$ ]] || { echo "  ERROR: UPSNAP_PING_PRIVILEGED must be true or false." >&2; exit 1; }
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

for cmd in pvesh pveam pct pvesm qm curl python3 ip awk grep sed sort paste seq readlink cp chmod dpkg head tr; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

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

# ── Show defaults & confirm ───────────────────────────────────────────────────
cat <<EOF2

  UpSnap Quadlet LXC Creator — Configuration
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
  App image:         $APP_IMAGE
  App port:          $APP_PORT
  Website title:     $UPSNAP_WEBSITE_TITLE
  Ping interval:     $UPSNAP_INTERVAL
  Scan range:        ${UPSNAP_SCAN_RANGE:-(not set — enter one on the Scan page later)}
  Scan timeout:      $UPSNAP_SCAN_TIMEOUT
  Privileged ping:   $UPSNAP_PING_PRIVILEGED
  Timezone:          $APP_TZ
  Listens on:        0.0.0.0:${APP_PORT} inside the CT (Network=host, required for WoL broadcast)
  Capabilities:      drop ALL, add NET_RAW (privileged ping + nmap discovery)
  Podman storage:    $([ "$PODMAN_FUSE_OVERLAY" -eq 1 ] && echo "fuse-overlayfs (fuse=1)" || echo "native overlay (no FUSE)")
  Tags:              $TAGS
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled — daily at ${UPDATE_TIME} (re-pull $APP_TAG)" || echo "disabled ($APP_TAG, manual)")
  Cleanup on fail:   $CLEANUP_ON_FAIL (until first service start; CT preserved after that)
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/upsnap-quadlet.sh"
SCRIPT_LOCAL="/root/upsnap-quadlet.sh"
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
# Unprivileged CT keeps CAP_NET_RAW in its bounding set (Proxmox only drops
# mac_admin/mac_override/sys_time/sys_module/sys_rawio), which is what rootful
# Podman needs to grant NET_RAW to the UpSnap container.
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

# ── Pull image ────────────────────────────────────────────────────────────────
echo "  Pulling UpSnap image: ${APP_IMAGE} ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman pull '${APP_IMAGE}'
"

# ── Prepare persistent paths ──────────────────────────────────────────────────
# UpSnap persistent state (all of it): /opt/upsnap/data → /app/pb_data
# (PocketBase SQLite DB: users, devices, cron jobs, settings). The container
# runs as root, so root-owned 0755 on the CT side is correct — no UID detection.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  install -d -m 0755 '${APP_DIR}'
  install -d -m 0755 '${APP_DIR}/data'
"

# ── Quadlet unit file ─────────────────────────────────────────────────────────
# Rootful Quadlet: /etc/containers/systemd/ — no linger, no --user flags needed.
# systemd daemon-reload triggers the Quadlet generator; upsnap.service is created
# as a transient unit and WantedBy=multi-user.target handles boot start.
# Network=host is REQUIRED here (not just lab convention): Wake-on-LAN magic
# packets are broadcast on the CT's real interface and nmap discovery needs the
# LAN segment. UPSNAP_HTTP_LISTEN sets the bind address instead of PublishPort=.
# Capabilities mirror upstream compose: drop ALL, add NET_RAW (privileged ICMP
# ping + nmap ARP scan). No secrets in the unit — UpSnap has none at install
# time; the admin account is created on first visit.
# Optional line, emitted only when a range is configured (an empty value would
# make UpSnap treat "" as the range). The leading newline keeps the unit tidy.
UPSNAP_SCAN_RANGE_LINE=""
[[ -n "$UPSNAP_SCAN_RANGE" ]] && UPSNAP_SCAN_RANGE_LINE=$'\n'"Environment=UPSNAP_SCAN_RANGE=${UPSNAP_SCAN_RANGE}"

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  mkdir -p /etc/containers/systemd

  cat > '${QUADLET_FILE}' <<EOF2
[Unit]
Description=UpSnap (Wake-on-LAN dashboard)
After=network-online.target
Wants=network-online.target

[Container]
Image=${APP_IMAGE}
ContainerName=upsnap
Network=host
DropCapability=ALL
AddCapability=NET_RAW
Environment=TZ=${APP_TZ}
Environment=UPSNAP_HTTP_LISTEN=0.0.0.0:${APP_PORT}
Environment=\"UPSNAP_WEBSITE_TITLE=${UPSNAP_WEBSITE_TITLE}\"
Environment=\"UPSNAP_INTERVAL=${UPSNAP_INTERVAL}\"
Environment=UPSNAP_SCAN_TIMEOUT=${UPSNAP_SCAN_TIMEOUT}
Environment=UPSNAP_PING_PRIVILEGED=${UPSNAP_PING_PRIVILEGED}${UPSNAP_SCAN_RANGE_LINE}
Volume=${APP_DIR}/data:/app/pb_data
LogDriver=journald

[Service]
Restart=always
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF2

  chmod 0644 '${QUADLET_FILE}'
"

# ── Runtime state file ────────────────────────────────────────────────────────
# .env is not read by Quadlet or systemd. It is the maint script's source of
# truth for the current image tag and policy flag. Keep it in sync with the
# Quadlet unit whenever the image is updated. UpSnap settings live in the unit.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > '${APP_DIR}/.env' <<EOF2
APP_IMAGE_REPO=${APP_IMAGE_REPO}
APP_TAG=${APP_TAG}
APP_IMAGE=${APP_IMAGE}
APP_PORT=${APP_PORT}
APP_TZ=${APP_TZ}
AUTO_UPDATE=${AUTO_UPDATE}
EOF2
  chmod 0600 '${APP_DIR}/.env'
"

# ── Maintenance script ────────────────────────────────────────────────────────
# update <tag>: pull → sed Image= in Quadlet file → sed .env → daemon-reload →
#   restart → /api/health check; rollback restores both files, daemon-reload,
#   restart with the previous image ID re-tagged.
# auto-update: re-pull the current tag (latest or pinned); restart only if the
#   image ID changed; same rollback.
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/upsnap-maint.sh && chmod 0755 /usr/local/bin/upsnap-maint.sh' <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR="${APP_DIR:-/opt/upsnap}"
QUADLET_FILE="/etc/containers/systemd/upsnap.container"
SERVICE="upsnap.service"
CONTAINER="upsnap"
ENV_FILE="${APP_DIR}/.env"

need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF2
  UpSnap Maintenance (Quadlet)
  ────────────────────────────
  Usage:
    $0 update <tag> [--yes]   # latest, or pin e.g. 5.3.1
    $0 auto-update            # re-pull current tag (only if AUTO_UPDATE=1)
    $0 version

  Notes:
    - update pulls the tag, updates the Quadlet unit and .env, restarts the service
    - auto-update is called by upsnap-update.timer; it never changes the tag
    - to switch between tracking and pinning: update latest / update <full version>
    - UpSnap settings (UPSNAP_*) live in ${QUADLET_FILE}: edit, then
      systemctl daemon-reload && systemctl restart ${SERVICE}
    - backup and restore are handled by PBS and PVE snapshots
    - take a PVE snapshot before manual updates: pct snapshot <CT_ID> pre-update-\$(date +%Y%m%d)
EOF2
}

[[ -d "$APP_DIR" ]]      || die "APP_DIR not found: $APP_DIR"
[[ -f "$ENV_FILE" ]]     || die "Missing env file: $ENV_FILE"
[[ -f "$QUADLET_FILE" ]] || die "Missing Quadlet unit: $QUADLET_FILE"

# One maintenance operation at a time — a manual update must not overlap the timer.
LOCK_FILE="/run/lock/upsnap-maint.lock"
mkdir -p /run/lock
exec 9>"$LOCK_FILE"
flock -n 9 || die "Another upsnap-maint.sh operation is already running."

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
  [[ "$port" =~ ^[0-9]+$ ]] && printf '%s' "$port" || printf '8090'
}

current_image() { env_val APP_IMAGE; }
current_repo()  { env_val APP_IMAGE_REPO; }
current_tag()   { local img; img="$(current_image)"; echo "${img##*:}"; }

running_image_id() {
  podman inspect --format '{{.Image}}' "$CONTAINER" 2>/dev/null || true
}

image_id_of() {
  podman image inspect --format '{{.Id}}' "$1" 2>/dev/null || true
}

# /api/health is PocketBase's built-in probe; 200 regardless of auth state.
wait_for_app() {
  local port code
  port="$(app_port)"
  for i in $(seq 1 45); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${port}/api/health" 2>/dev/null || echo 000)"
    [[ "$code" == "200" ]] && return 0
    sleep 2
  done
  return 1
}

confirm_or_exit() {
  echo ""
  echo "  IMPORTANT: Take a PVE snapshot before proceeding."
  echo "  Use: pct snapshot <CT_ID> pre-update-$(date +%Y%m%d)"
  echo ""
  read -r -p "  Continue? [y/N]: " confirm
  case "$confirm" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) echo "  Aborted."; return 1 ;;
  esac
}

# update <tag> [--yes] — switch UpSnap to "latest" or a pinned version
update_app() {
  local new_tag="" skip_confirm=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) skip_confirm=1; shift ;;
      *) new_tag="$1"; shift ;;
    esac
  done

  local old_tag repo old_image new_image old_id tmp_env tmp_quadlet
  [[ -n "$new_tag" ]] || die "Usage: upsnap-maint.sh update <tag>"
  [[ "$new_tag" == "latest" || "$new_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] \
    || die "Invalid tag: $new_tag — use 'latest' or a full version like 5.3.1."

  old_tag="$(current_tag)"
  repo="$(current_repo)"
  [[ -n "$repo" ]] || die "Could not read APP_IMAGE_REPO from .env"
  old_image="$(current_image)"
  new_image="${repo}:${new_tag}"
  # Capture the current image ID before pulling: if new_tag == old_tag, the pull
  # moves the tag and the old ref would otherwise resolve to the NEW image on rollback.
  old_id="$(image_id_of "$old_image")"
  tmp_env="$(mktemp)"
  tmp_quadlet="$(mktemp)"

  echo "  Current tag: $old_tag"
  echo "  Target  tag: $new_tag"

  if [[ "$skip_confirm" -eq 0 ]]; then
    confirm_or_exit || { rm -f "$tmp_env" "$tmp_quadlet"; exit 0; }
  fi

  cp -a "$ENV_FILE"     "$tmp_env"
  cp -a "$QUADLET_FILE" "$tmp_quadlet"

  cleanup() { rm -f "$tmp_env" "$tmp_quadlet"; }
  rollback() {
    echo "  !! Update failed — rolling back and restarting ..." >&2
    cp -a "$tmp_env"     "$ENV_FILE"
    cp -a "$tmp_quadlet" "$QUADLET_FILE"
    [[ -n "$old_id" ]] && podman tag "$old_id" "$old_image" >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl restart "$SERVICE" || true
    rm -f "$tmp_env" "$tmp_quadlet"
    if wait_for_app; then
      echo "  Rollback complete — ${old_image} is healthy again." >&2
    else
      echo "  CRITICAL: rollback to ${old_image} did not become healthy. Restore the CT from the PVE snapshot / PBS." >&2
    fi
  }
  trap rollback ERR

  echo "  Pulling target image ..."
  podman pull "$new_image"

  sed -i "s|^Image=.*|Image=${new_image}|" "$QUADLET_FILE"
  sed -i \
    -e "s|^APP_TAG=.*|APP_TAG=$new_tag|" \
    -e "s|^APP_IMAGE=.*|APP_IMAGE=$new_image|" \
    "$ENV_FILE"

  echo "  Reloading Quadlet and restarting service ..."
  systemctl daemon-reload
  systemctl restart "$SERVICE"

  echo "  Waiting for UpSnap ..."
  if ! wait_for_app; then
    trap - ERR
    rollback
    die "UpSnap did not become healthy after update."
  fi

  trap - ERR
  cleanup
  if [[ -n "$old_id" && "$old_id" != "$(image_id_of "$new_image")" ]]; then
    podman rmi "$old_id" >/dev/null 2>&1 || true
  fi
  echo "  OK: UpSnap updated to $new_tag"
}

# auto-update — re-pull the current tag (latest or pinned); restart only if changed
auto_update_app() {
  if [[ "$(env_flag AUTO_UPDATE)" != "1" ]]; then
    echo "  Auto-update disabled in ${ENV_FILE}; nothing to do."
    return 0
  fi

  local image old_id new_id
  image="$(current_image)"
  [[ -n "$image" ]] || die "Could not read APP_IMAGE from .env"
  old_id="$(running_image_id)"

  echo "  Auto-update: re-pulling ${image} ..."
  podman pull "$image"
  new_id="$(image_id_of "$image")"
  [[ -n "$new_id" ]] || die "Could not inspect pulled image ${image}"

  if [[ -n "$old_id" && "$new_id" == "$old_id" ]]; then
    echo "  OK: ${image} is already current — no restart needed."
    return 0
  fi

  rollback() {
    echo "  !! Auto-update failed — restoring previous image and restarting ..." >&2
    [[ -n "$old_id" ]] && podman tag "$old_id" "$image" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE" || true
    if wait_for_app; then
      echo "  Rollback complete — previous image is healthy again." >&2
    else
      echo "  CRITICAL: rollback did not become healthy. Restore the CT from the PVE snapshot / PBS." >&2
    fi
  }
  trap rollback ERR

  echo "  Image changed — restarting ${SERVICE} ..."
  systemctl restart "$SERVICE"

  echo "  Waiting for UpSnap ..."
  if ! wait_for_app; then
    trap - ERR
    rollback
    die "UpSnap did not become healthy after auto-update."
  fi

  trap - ERR
  [[ -n "$old_id" ]] && podman rmi "$old_id" >/dev/null 2>&1 || true
  echo "  OK: UpSnap refreshed to the current ${image}"
}

need_root
cmd="${1:-}"
case "$cmd" in
  update)      shift; update_app "$@" ;;
  auto-update) auto_update_app ;;
  version)
    # With "latest" the tag carries no version info; the digest identifies the build.
    echo "Configured image: $(current_image)"
    echo "Running image ID: $(running_image_id)"
    echo "Image digest:     $(podman image inspect --format '{{index .RepoDigests 0}}' "$(current_image)" 2>/dev/null || echo n/a)"
    echo "AUTO_UPDATE=$(env_flag AUTO_UPDATE)"
    ;;
  ""|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
MAINT
echo "  Maintenance script deployed: /usr/local/bin/upsnap-maint.sh"

# ── Start via Quadlet ─────────────────────────────────────────────────────────
# daemon-reload triggers the Quadlet generator which produces upsnap.service as
# a transient systemd unit. WantedBy=multi-user.target handles boot restarts.
# Transient units cannot be systemctl-enabled; daemon-reload is sufficient.
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

if pct exec "$CT_ID" -- systemctl is-active --quiet "$QUADLET_SERVICE" 2>/dev/null; then
  echo "  Quadlet service is active: ${QUADLET_SERVICE}"
else
  echo "  ERROR: ${QUADLET_SERVICE} is not active" >&2
  echo "  Check: pct exec $CT_ID -- systemctl status ${QUADLET_SERVICE}" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u ${QUADLET_SERVICE} --no-pager -n 50" >&2
  VERIFY_FAIL=1
fi

RUNNING=0
for i in $(seq 1 60); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc 'podman ps --filter name=^upsnap$ --format "{{.Names}}" 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge 1 ]] && break
  sleep 2
done
pct exec "$CT_ID" -- bash -lc 'podman ps' || true

if [[ "$RUNNING" -lt 1 ]]; then
  echo "  ERROR: upsnap container is not running" >&2
  VERIFY_FAIL=1
else
  echo "  Container running: upsnap"
fi

# NET_RAW is the whole point (WoL + privileged ping + nmap). If the unprivileged
# CT could not pass it through, UpSnap starts but every device shows offline.
if pct exec "$CT_ID" -- sh -lc 'podman inspect --format "{{.EffectiveCaps}}" upsnap 2>/dev/null | grep -q CAP_NET_RAW' 2>/dev/null; then
  echo "  Container has CAP_NET_RAW (privileged ping / nmap / WoL)"
else
  echo "  ERROR: CAP_NET_RAW is missing from the upsnap container's effective capabilities" >&2
  echo "  Check: pct exec $CT_ID -- podman inspect --format '{{.EffectiveCaps}}' upsnap" >&2
  VERIFY_FAIL=1
fi

US_HEALTHY=0
for i in $(seq 1 45); do
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc "curl -s -o /dev/null -w '%{http_code}' --max-time 3 'http://127.0.0.1:${APP_PORT}/api/health' 2>/dev/null" 2>/dev/null || echo 000)"
  case "$HTTP_CODE" in
    200)
      US_HEALTHY=1
      break
      ;;
  esac
  sleep 2
done

if [[ "$US_HEALTHY" -eq 1 ]]; then
  echo "  UpSnap health check passed (HTTP $HTTP_CODE)"
else
  echo "  ERROR: UpSnap /api/health did not return 200 on port ${APP_PORT}" >&2
  echo "  Check: pct exec $CT_ID -- systemctl status ${QUADLET_SERVICE}" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u ${QUADLET_SERVICE} --no-pager -n 80" >&2
  VERIFY_FAIL=1
fi

# Discovery needs nmap inside the image (bundled upstream since v4). Missing
# nmap only breaks the Scan page, so this is a warning, not a failure.
if pct exec "$CT_ID" -- sh -lc 'podman exec upsnap sh -c "command -v nmap" >/dev/null 2>&1' 2>/dev/null; then
  echo "  nmap present in image (network discovery available)"
else
  echo "  WARNING: nmap not found in the UpSnap image — the Scan page will not work; WoL/ping unaffected" >&2
fi

if (( VERIFY_FAIL == 1 )); then
  echo "" >&2
  echo "  FATAL: Core verification failed — CT $CT_ID is preserved but the install is incomplete." >&2
  echo "  Inspect the container and fix manually, or destroy and re-run." >&2
  exit 1
fi

# ── Auto-update timer (policy-driven) ─────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > /etc/systemd/system/upsnap-update.service <<EOF2
[Unit]
Description=UpSnap auto-update maintenance run
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/upsnap-maint.sh auto-update
EOF2

  cat > /etc/systemd/system/upsnap-update.timer <<EOF2
[Unit]
Description=UpSnap auto-update timer

[Timer]
OnCalendar=*-*-* ${UPDATE_TIME}:00
Persistent=true

[Install]
WantedBy=timers.target
EOF2

  systemctl daemon-reload
"
if [[ "$AUTO_UPDATE" -eq 1 ]]; then
  pct exec "$CT_ID" -- bash -lc 'systemctl enable --now upsnap-update.timer'
  echo "  Auto-update timer enabled"
else
  pct exec "$CT_ID" -- bash -lc 'systemctl disable --now upsnap-update.timer >/dev/null 2>&1 || true'
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
printf '\\n  UpSnap (Podman/Quadlet)\\n'
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
running=\$(podman ps --filter name=^upsnap$ --format '{{.Names}}' 2>/dev/null | wc -l)
svc_status=\$(systemctl is-active upsnap.service 2>/dev/null); svc_status=\${svc_status:-unknown}
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
image=\$(awk -F= '/^APP_IMAGE=/{print \$2}' /opt/upsnap/.env 2>/dev/null | tail -n1)
auto=\$(awk -F= '/^AUTO_UPDATE=/{print \$2}' /opt/upsnap/.env 2>/dev/null | tail -n1)
port=\$(awk -F= '/^APP_PORT=/{print \$2}' /opt/upsnap/.env 2>/dev/null | tail -n1)
port=\${port:-8090}
printf '  Container:  upsnap (%s running)\\n' \"\$running\"
printf '  Service:    upsnap.service (%s)\\n' \"\$svc_status\"
printf '  Image:      %s\\n' \"\${image:-n/a}\"
printf '  Policy:     %s\\n' \"\$([ \"\$auto\" = '1' ] && echo 'auto-update daily (re-pull current tag)' || echo 'manual updates only')\"
printf '  Settings:   /etc/containers/systemd/upsnap.container (UPSNAP_* env)\\n'
printf '  Data:       /opt/upsnap/data (PocketBase)\\n'
printf '  Logs:       journalctl -u upsnap.service -f\\n'
printf '  Maintain:   /usr/local/bin/upsnap-maint.sh [update|auto-update|version]\\n'
printf '  Updates:    systemctl status upsnap-update.timer\\n'
printf '  Web UI:     http://%s:%s/\\n' \"\${ip:-n/a}\" \"\$port\"
printf '  PB Admin:   http://%s:%s/_/\\n' \"\${ip:-n/a}\" \"\$port\"
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
US_DESC="<a href='http://${CT_IP}:${APP_PORT}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>UpSnap</a>
<details><summary>Details</summary>UpSnap (Podman/Quadlet) — Wake-on-LAN dashboard on Debian ${DEBIAN_VERSION} LXC
Tag: ${APP_TAG} | LAN/VPN only
Created by upsnap-quadlet.sh</details>"
pct set "$CT_ID" --description "$US_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── First superuser link ──────────────────────────────────────────────────────
# Since UpSnap 5.4.0 the first superuser is created out-of-band: PocketBase
# prints a one-time /_/#/pbinstal/<token> link to the server log (fixes a
# first-visit takeover on reachable instances). The link is logged with the
# bind address, so rewrite the host to the CT IP. Best-effort: if the pattern
# ever changes, the summary falls back to the journalctl command.
SETUP_LINK="$(pct exec "$CT_ID" -- sh -lc 'journalctl -u upsnap.service --no-pager -o cat 2>/dev/null | grep -oE "https?://[^ ]+/_/#/pbinstal/[A-Za-z0-9._-]+" | tail -n1' 2>/dev/null || true)"
[[ -n "$SETUP_LINK" ]] && SETUP_LINK="$(printf '%s' "$SETUP_LINK" | sed -E "s#^https?://[^/]+#http://${CT_IP}:${APP_PORT}#")"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "    CT: $CT_ID | IP: ${CT_IP} | Web UI: http://${CT_IP}:${APP_PORT}/"
echo "    PB Admin: http://${CT_IP}:${APP_PORT}/_/"
echo "    Image:    ${APP_IMAGE}"
echo "    Quadlet:  ${QUADLET_FILE}  (UPSNAP_* settings live here)"
echo "    Data:     ${APP_DIR}/data  (PocketBase DB — users, devices, cron jobs)"
echo "    Policy:   $([ "$AUTO_UPDATE" -eq 1 ] && echo "auto-update daily at ${UPDATE_TIME} (re-pull ${APP_TAG})" || echo "manual updates only (${APP_TAG})")"
echo ""
echo "    pct exec $CT_ID -- systemctl status upsnap.service"
echo "    pct exec $CT_ID -- journalctl -u upsnap.service --no-pager -n 50"
echo "    pct exec $CT_ID -- /usr/local/bin/upsnap-maint.sh update <tag>   # latest, or pin e.g. 5.3.1"
echo "    pct exec $CT_ID -- /usr/local/bin/upsnap-maint.sh auto-update    # re-pull current tag now (if AUTO_UPDATE=1)"
echo "    pct exec $CT_ID -- /usr/local/bin/upsnap-maint.sh version"
echo "    Backup/restore: use PBS or PVE snapshots"
echo ""
if [[ -n "$SETUP_LINK" ]]; then
  echo "    FIRST SUPERUSER (one-time link, valid until used):"
  echo "      ${SETUP_LINK}"
  echo "    Then open the Web UI and click Done."
else
  echo "    FIRST SUPERUSER: open the one-time link from the server log, then click Done in the Web UI:"
  echo "      pct exec $CT_ID -- journalctl -u upsnap.service --no-pager -o cat | grep pbinstal"
  echo "      (replace the 0.0.0.0 host in the link with ${CT_IP})"
fi
echo ""
echo "    Do NOT expose UpSnap to the internet — the per-device shutdown command runs as a"
echo "    shell inside the container; use a VPN."
echo "    Port ${APP_PORT} listens on all CT interfaces (Network=host, required for WoL)."
if [[ -z "$UPSNAP_SCAN_RANGE" ]]; then
  echo "    Network discovery: set a range on the Scan page, or UPSNAP_SCAN_RANGE in the unit + daemon-reload + restart."
fi
if [[ "$PODMAN_FUSE_OVERLAY" -eq 1 ]]; then
  echo "    Backups: fuse=1 + fuse-overlayfs can deadlock under snapshot-mode vzdump/PBS (freezer)."
  echo "             Use stop-mode backups for this CT, or test PODMAN_FUSE_OVERLAY=0."
fi
echo ""
