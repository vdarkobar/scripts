#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID=""                             # empty = auto-assign via pvesh; set e.g. CT_ID=120 to pin
HN="npm"
CPU=4
RAM=4096
DISK=8
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Nginx Proxy Manager / Podman + Quadlet
APP_PORT=81                          # admin UI — fixed by NPM. 80/443 are bound too (Network=host)
APP_TZ="Europe/Berlin"
TAGS="npm;podman;quadlet;lxc"

# Images / versions
APP_IMAGE_REPO="docker.io/jc21/nginx-proxy-manager"
APP_TAG="2.15.1"                     # pinned default; do not default to :latest
DEBIAN_VERSION=13

# Optional features / policy
INSTALL_CLOUDFLARED=0                # 1 = install cloudflared inside CT (token prompted)
NPM_DISABLE_IPV6=0                   # 1 = set DISABLE_IPV6=true for the NPM container

# Auto-update policy
# AUTO_UPDATE=0 (default): timer installed but disabled; manual updates via
#   npm-maint.sh update <tag>
# AUTO_UPDATE=1: timer re-pulls the CURRENT PINNED TAG on schedule and restarts
#   only if the image digest changed. :latest is never used.
AUTO_UPDATE=0

# Podman storage backend
# PODMAN_FUSE_OVERLAY=1: lab default so far — fuse=1 on the CT + fuse-overlayfs
#   as mount_program. Proxmox warns that FUSE mounts inside a CT can deadlock
#   when the CT is frozen, which snapshot-mode vzdump/PBS backups do.
# PODMAN_FUSE_OVERLAY=0: native overlayfs in the CT's user namespace (kernel
#   >= 5.11); no fuse=1, no mount_program, no freezer interaction. Verify after
#   install with: podman info --format '{{.Store.GraphDriverName}}' (overlay) and
#   run a snapshot-mode backup under load before adopting lab-wide.
#   NPM is the CT everything else depends on — validate this on a less critical CT first.
PODMAN_FUSE_OVERLAY=1

# Extra packages to install (space-separated or array)
EXTRA_PACKAGES=(
)

# Behavior
CLEANUP_ON_FAIL=1

# Derived
APP_DIR="/opt/npm"
APP_IMAGE="${APP_IMAGE_REPO}:${APP_TAG}"
QUADLET_FILE="/etc/containers/systemd/npm.container"
QUADLET_SERVICE="npm.service"

# ── Custom configs created by this script ─────────────────────────────────────
#   /etc/containers/systemd/npm.container        (Quadlet unit — source of truth)
#   /opt/npm/.env                                (runtime state — read by maint script)
#   /opt/npm/data/                               (NPM data — SQLite DB, nginx configs, access lists)
#   /opt/npm/letsencrypt/                        (certificates)
#   /usr/local/bin/npm-maint.sh                  (maintenance helper)
#   /etc/systemd/system/npm-update.service
#   /etc/systemd/system/npm-update.timer
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/35-cloudflared            (if INSTALL_CLOUDFLARED=1)
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
[[ "$INSTALL_CLOUDFLARED" =~ ^[01]$ ]] || { echo "  ERROR: INSTALL_CLOUDFLARED must be 0 or 1." >&2; exit 1; }
[[ "$NPM_DISABLE_IPV6" =~ ^[01]$ ]] || { echo "  ERROR: NPM_DISABLE_IPV6 must be 0 or 1." >&2; exit 1; }
[[ "$PODMAN_FUSE_OVERLAY" =~ ^[01]$ ]] || { echo "  ERROR: PODMAN_FUSE_OVERLAY must be 0 or 1." >&2; exit 1; }
[[ "$CLEANUP_ON_FAIL" =~ ^[01]$ ]] || { echo "  ERROR: CLEANUP_ON_FAIL must be 0 or 1." >&2; exit 1; }
# APP_IMAGE_REPO is interpolated into podman, sed, the Quadlet unit and .env.
[[ "$APP_IMAGE_REPO" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*[A-Za-z0-9]$ ]] || {
  echo "  ERROR: APP_IMAGE_REPO must look like registry/namespace/name (no tag, no spaces)." >&2
  exit 1
}
# NPM publishes plain semver tags (2.15.1). Floating tags like 2 or 2.15 are
# mutable and are rejected for the same reason :latest is.
[[ "$APP_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: APP_TAG must be a pinned version like 2.15.1 — ':latest' and floating tags are not permitted." >&2
  exit 1
}
[[ -e "/usr/share/zoneinfo/${APP_TZ}" ]] || { echo "  ERROR: APP_TZ not found in /usr/share/zoneinfo: $APP_TZ" >&2; exit 1; }
[[ "$APP_TZ" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)+$ ]] || { echo "  ERROR: APP_TZ contains invalid characters." >&2; exit 1; }
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

  NPM Quadlet LXC Creator — Configuration
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
  Admin port:        $APP_PORT (fixed by NPM)
  Database:          SQLite (embedded)
  Timezone:          $APP_TZ
  Disable IPv6 app:  $([ "$NPM_DISABLE_IPV6" -eq 1 ] && echo "yes" || echo "no")
  Cloudflare Tunnel: $([ "$INSTALL_CLOUDFLARED" -eq 1 ] && echo "yes" || echo "no")
  Listens on:        0.0.0.0:80, :443, :${APP_PORT} inside the CT (Network=host) — reachable from the whole LAN
  Podman storage:    $([ "$PODMAN_FUSE_OVERLAY" -eq 1 ] && echo "fuse-overlayfs (fuse=1)" || echo "native overlay (no FUSE)")
  Tags:              $TAGS
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled (re-pull pinned $APP_TAG)" || echo "disabled (pinned $APP_TAG, manual)")
  Cleanup on fail:   $CLEANUP_ON_FAIL (until first service start; CT preserved after that)
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/npm-quadlet.sh"
SCRIPT_LOCAL="/root/npm-quadlet.sh"
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

# ── Cloudflare Tunnel token ───────────────────────────────────────────────────
# Input is hidden (it is a credential) and later streamed into the CT over
# stdin — it never appears in host argv.
TUNNEL_TOKEN=""
if [[ "$INSTALL_CLOUDFLARED" -eq 1 ]]; then
  echo "  Cloudflare Tunnel token is required."
  echo "  Get it from: Zero Trust dashboard → Networks → Tunnels"
  echo "  Token looks like: eyJhIjoiNjk2... (input is hidden; length is echoed for sanity)"
  echo ""
  while true; do
    read -r -s -p "  Tunnel token: " TUNNEL_TOKEN <&8; echo
    [[ -z "$TUNNEL_TOKEN" ]] && { echo "  Token cannot be empty."; continue; }
    [[ "$TUNNEL_TOKEN" =~ [[:space:]] ]] && { echo "  Token cannot contain whitespace."; continue; }
    [[ "$TUNNEL_TOKEN" =~ [\"\'$\`\\] ]] && { echo '  Token cannot contain quotes, $, backtick or backslash.'; continue; }
    echo "  Token length: ${#TUNNEL_TOKEN} characters"
    if [[ ! "$TUNNEL_TOKEN" =~ ^eyJ ]]; then
      read -r -p "  Token format looks unusual (should usually start with 'eyJ'). Continue? [y/N]: " cf_confirm <&8
      case "$cf_confirm" in
        [yY][eE][sS]|[yY]) ;;
        *) continue ;;
      esac
    fi
    break
  done
  echo ""
fi

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
echo "  Pulling NPM image: ${APP_IMAGE} ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman pull '${APP_IMAGE}'
"

# ── Prepare persistent paths ──────────────────────────────────────────────────
# NPM persistent state (SQLite mode):
#   /opt/npm/data/          — database.sqlite, nginx configs, access lists, custom pages
#   /opt/npm/letsencrypt/   — certificates
# NPM runs as root inside the container; no ownership handling needed.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  install -d -m 0755 '${APP_DIR}'
  install -d -m 0755 '${APP_DIR}/data' '${APP_DIR}/letsencrypt'
"

# ── Quadlet unit file ─────────────────────────────────────────────────────────
# Rootful Quadlet: /etc/containers/systemd/ — no linger, no --user flags needed.
# systemd daemon-reload triggers the Quadlet generator; npm.service is created
# as a transient unit and WantedBy=multi-user.target handles boot start.
# Network=host bypasses Netavark NAT issues on Debian LXC; NPM binds 80/443/81
# directly on the CT interface. No DB_MYSQL_* env vars — NPM defaults to
# embedded SQLite at /data/database.sqlite. No secrets in this unit file.
DISABLE_IPV6_LINE=""
[[ "$NPM_DISABLE_IPV6" -eq 1 ]] && DISABLE_IPV6_LINE="Environment=DISABLE_IPV6=true"

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  mkdir -p /etc/containers/systemd

  cat > '${QUADLET_FILE}' <<EOF2
[Unit]
Description=Nginx Proxy Manager
After=network-online.target
Wants=network-online.target

[Container]
Image=${APP_IMAGE}
ContainerName=npm
Network=host
Environment=TZ=${APP_TZ}
${DISABLE_IPV6_LINE}
Volume=${APP_DIR}/data:/data
Volume=${APP_DIR}/letsencrypt:/etc/letsencrypt
LogDriver=journald

[Service]
Restart=always
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF2

  chmod 0644 '${QUADLET_FILE}'
"

# ── Runtime state file ────────────────────────────────────────────────────────
# .env is not read by Quadlet or systemd. It is the maint script's source of
# truth for current image tag and policy flags. Keep it in sync with the
# Quadlet unit whenever the image is updated.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > '${APP_DIR}/.env' <<EOF2
APP_IMAGE_REPO=${APP_IMAGE_REPO}
APP_TAG=${APP_TAG}
APP_IMAGE=${APP_IMAGE}
APP_PORT=${APP_PORT}
APP_TZ=${APP_TZ}
NPM_DISABLE_IPV6=${NPM_DISABLE_IPV6}
AUTO_UPDATE=${AUTO_UPDATE}
EOF2
  chmod 0600 '${APP_DIR}/.env'
"

# ── Maintenance script ────────────────────────────────────────────────────────
# update <tag>: pull → sed Image= in Quadlet file → sed .env → daemon-reload →
#   restart → health check; rollback restores both files, daemon-reload, restart.
# auto-update:  re-pull the CURRENT PINNED TAG; restart only if the image ID
#   changed; rollback re-tags the previous image ID and restarts.
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/npm-maint.sh && chmod 0755 /usr/local/bin/npm-maint.sh' <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR="${APP_DIR:-/opt/npm}"
QUADLET_FILE="/etc/containers/systemd/npm.container"
SERVICE="npm.service"
CONTAINER="npm"
ENV_FILE="${APP_DIR}/.env"

need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF2
  NPM Maintenance (Quadlet)
  ─────────────────────────
  Usage:
    $0 update <tag> [--yes]   # e.g. 2.15.2 — pinned version required, no :latest
    $0 auto-update            # re-pull current pinned tag (only if AUTO_UPDATE=1)
    $0 version

  Notes:
    - update pulls the pinned tag, updates the Quadlet unit and .env, restarts the service
    - auto-update is called by npm-update.timer; it never changes the tag
    - :latest and floating tags (2, 2.15) are not permitted — always specify X.Y.Z
    - backup and restore are handled by PBS and PVE snapshots
    - take a PVE snapshot before manual updates: pct snapshot <CT_ID> pre-update-\$(date +%Y%m%d)
EOF2
}

[[ -d "$APP_DIR" ]]      || die "APP_DIR not found: $APP_DIR"
[[ -f "$ENV_FILE" ]]     || die "Missing env file: $ENV_FILE"
[[ -f "$QUADLET_FILE" ]] || die "Missing Quadlet unit: $QUADLET_FILE"

# One maintenance operation at a time — a manual update must not overlap the timer.
LOCK_FILE="/run/lock/npm-maint.lock"
mkdir -p /run/lock
exec 9>"$LOCK_FILE"
flock -n 9 || die "Another npm-maint.sh operation is already running."

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
  [[ "$port" =~ ^[0-9]+$ ]] && printf '%s' "$port" || printf '81'
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

# /api/ is answered by the Node backend (200 + JSON) only when it is actually up;
# / on port 81 is the static admin SPA and returns 200 even with a dead backend.
wait_for_app() {
  local port code
  port="$(app_port)"
  for i in $(seq 1 45); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${port}/api/" 2>/dev/null || echo 000)"
    [[ "$code" == "200" ]] && return 0
    sleep 2
  done
  return 1
}

# update <tag> [--yes] — switch to a pinned version
update_app() {
  local new_tag="" skip_confirm=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) skip_confirm=1; shift ;;
      *) new_tag="$1"; shift ;;
    esac
  done

  local old_tag repo old_image new_image old_id tmp_env tmp_quadlet
  [[ -n "$new_tag" ]] || die "Usage: npm-maint.sh update <tag>"
  [[ "$new_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] \
    || die "Invalid tag: $new_tag — pinned version required (e.g. 2.15.2), ':latest' is not permitted."

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
    echo ""
    echo "  IMPORTANT: Take a PVE snapshot before proceeding."
    echo "  Use: pct snapshot <CT_ID> pre-update-$(date +%Y%m%d)"
    echo ""
    read -r -p "  Continue? [y/N]: " confirm
    case "$confirm" in
      [yY][eE][sS]|[yY]) ;;
      *) echo "  Aborted."; rm -f "$tmp_env" "$tmp_quadlet"; exit 0 ;;
    esac
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

  echo "  Waiting for NPM ..."
  if ! wait_for_app; then
    trap - ERR
    rollback
    die "NPM did not become healthy after update."
  fi

  trap - ERR
  cleanup
  if [[ -n "$old_id" && "$old_id" != "$(image_id_of "$new_image")" ]]; then
    podman rmi "$old_id" >/dev/null 2>&1 || true
  fi
  echo "  OK: NPM updated to $new_tag"
}

# auto-update — re-pull the current pinned tag; restart only if the image changed
auto_update_app() {
  if [[ "$(env_flag AUTO_UPDATE)" != "1" ]]; then
    echo "  Auto-update disabled in ${ENV_FILE}; nothing to do."
    return 0
  fi

  local image old_id new_id
  image="$(current_image)"
  [[ -n "$image" ]] || die "Could not read APP_IMAGE from .env"
  old_id="$(running_image_id)"

  echo "  Auto-update: re-pulling pinned ${image} ..."
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

  echo "  Image changed — restarting service ..."
  systemctl restart "$SERVICE"

  echo "  Waiting for NPM ..."
  if ! wait_for_app; then
    trap - ERR
    rollback
    die "NPM did not become healthy after auto-update."
  fi

  trap - ERR
  [[ -n "$old_id" ]] && podman rmi "$old_id" >/dev/null 2>&1 || true
  echo "  OK: NPM refreshed on ${image}"
}

need_root
cmd="${1:-}"
case "$cmd" in
  update)      shift; update_app "$@" ;;
  auto-update) auto_update_app ;;
  version)
    echo "Configured image: $(current_image)"
    echo "Running image ID: $(running_image_id)"
    echo "AUTO_UPDATE=$(env_flag AUTO_UPDATE)"
    ;;
  ""|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
MAINT
echo "  Maintenance script deployed: /usr/local/bin/npm-maint.sh"

# ── Start via Quadlet ─────────────────────────────────────────────────────────
# daemon-reload triggers the Quadlet generator which produces npm.service
# as a transient systemd unit. WantedBy=multi-user.target handles boot restarts.
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

if pct exec "$CT_ID" -- systemctl is-active --quiet "${QUADLET_SERVICE}" 2>/dev/null; then
  echo "  Quadlet service is active: ${QUADLET_SERVICE}"
else
  echo "  ERROR: ${QUADLET_SERVICE} is not active" >&2
  echo "  Check: pct exec $CT_ID -- systemctl status npm.service" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u npm.service --no-pager -n 50" >&2
  VERIFY_FAIL=1
fi

RUNNING=0
for i in $(seq 1 60); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc \
    'podman ps --filter name=^npm$ --format "{{.Names}}" 2>/dev/null | wc -l' \
    2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge 1 ]] && break
  sleep 2
done
pct exec "$CT_ID" -- bash -lc 'podman ps' || true

if [[ "$RUNNING" -lt 1 ]]; then
  echo "  ERROR: Expected 1 container running, found $RUNNING" >&2
  VERIFY_FAIL=1
else
  echo "  Container count OK ($RUNNING running)"
fi


NPM_HEALTHY=0
for i in $(seq 1 90); do
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc "curl -s -o /dev/null -w '%{http_code}' --max-time 3 'http://127.0.0.1:${APP_PORT}/api/' 2>/dev/null" 2>/dev/null || echo 000)"
  case "$HTTP_CODE" in
    200)
      NPM_HEALTHY=1
      break
      ;;
  esac
  sleep 2
done

if [[ "$NPM_HEALTHY" -eq 1 ]]; then
  echo "  NPM API health check passed (HTTP $HTTP_CODE)"
else
  echo "  ERROR: NPM backend /api/ did not return 200 on port ${APP_PORT}" >&2
  echo "  Check: pct exec $CT_ID -- systemctl status npm.service" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u npm.service --no-pager -n 80" >&2
  VERIFY_FAIL=1
fi

if (( VERIFY_FAIL == 1 )); then
  echo "" >&2
  echo "  FATAL: Core verification failed — CT $CT_ID is preserved but the install is incomplete." >&2
  echo "  Inspect the container and fix manually, or destroy and re-run." >&2
  exit 1
fi

# ── Cloudflare Tunnel (optional) ──────────────────────────────────────────────
if [[ "$INSTALL_CLOUDFLARED" -eq 1 && -n "$TUNNEL_TOKEN" ]]; then
  echo "  Installing Cloudflare Tunnel ..."

  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y curl gnupg ca-certificates

    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg \
      -o /usr/share/keyrings/cloudflare-public-v2.gpg

    echo "deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main" \
      > /etc/apt/sources.list.d/cloudflared.list

    apt-get update -qq
    apt-get install -y cloudflared
    cloudflared --version
  '

  # Token streamed over stdin — not in host argv. cloudflared itself stores it
  # in the unit it writes (/etc/systemd/system/cloudflared.service); that is
  # its design and is root-only inside the CT.
  printf '%s\n' "$TUNNEL_TOKEN" | pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    IFS= read -r token
    cloudflared service install "$token"
  '
  unset TUNNEL_TOKEN

  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    systemctl daemon-reload
    systemctl enable cloudflared
    systemctl start cloudflared
  '

  sleep 3
  if pct exec "$CT_ID" -- systemctl is-active --quiet cloudflared 2>/dev/null; then
    echo "  Cloudflared service is running"
  else
    echo "  WARNING: Cloudflared service may not be running — check: pct exec $CT_ID -- journalctl -u cloudflared" >&2
  fi

  pct set "$CT_ID" --tags "${TAGS};cloudflared"
fi

# ── Auto-update timer (policy-driven) ─────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/npm-update.service <<EOF2
[Unit]
Description=NPM auto-update maintenance run
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/npm-maint.sh auto-update
EOF2

  cat > /etc/systemd/system/npm-update.timer <<EOF2
[Unit]
Description=NPM auto-update timer

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
  pct exec "$CT_ID" -- bash -lc 'systemctl enable --now npm-update.timer'
  echo "  Auto-update timer enabled"
else
  pct exec "$CT_ID" -- bash -lc 'systemctl disable --now npm-update.timer >/dev/null 2>&1 || true'
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
printf '\\n  Nginx Proxy Manager (Podman/Quadlet)\\n'
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
running=\$(podman ps --filter name=^npm$ --format '{{.Names}}' 2>/dev/null | wc -l)
svc_status=\$(systemctl is-active npm.service 2>/dev/null); svc_status=\${svc_status:-unknown}
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
image=\$(awk -F= '/^APP_IMAGE=/{print \$2}' /opt/npm/.env 2>/dev/null | tail -n1)
auto=\$(awk -F= '/^AUTO_UPDATE=/{print \$2}' /opt/npm/.env 2>/dev/null | tail -n1)
port=\$(awk -F= '/^APP_PORT=/{print \$2}' /opt/npm/.env 2>/dev/null | tail -n1)
port=\${port:-81}
printf '  Container: npm (%s running)\\n' \"\$running\"
printf '  Service:   npm.service (%s)\\n' \"\$svc_status\"
printf '  Image:     %s\\n' \"\${image:-n/a}\"
printf '  Database:  SQLite (embedded)\\n'
printf '  Policy:    %s\\n' \"\$([ \"\$auto\" = '1' ] && echo 'auto-update (re-pull pinned tag)' || echo 'pinned (manual)')\"
printf '  Data:      /opt/npm/data  /opt/npm/letsencrypt\\n'
printf '  Logs:      journalctl -u npm.service -f\\n'
printf '  Maintain:  /usr/local/bin/npm-maint.sh [update|auto-update|version]\\n'
printf '  Updates:   systemctl status npm-update.timer\\n'
printf '  Admin UI:  http://%s:%s/\\n' \"\${ip:-n/a}\" \"\$port\"
printf '  Proxy:     :80 / :443 on %s\\n' \"\${ip:-n/a}\"
MOTD

  cat > /etc/update-motd.d/99-footer <<'MOTD'
#!/bin/sh
printf '  ────────────────────────────────────\\n\\n'
MOTD

  chmod +x /etc/update-motd.d/*
"

if [[ "$INSTALL_CLOUDFLARED" -eq 1 ]]; then
  pct exec "$CT_ID" -- bash -lc 'cat > /etc/update-motd.d/35-cloudflared && chmod +x /etc/update-motd.d/35-cloudflared' <<'MOTD'
#!/bin/sh
if command -v cloudflared >/dev/null 2>&1; then
  status=$(systemctl is-active cloudflared 2>/dev/null); status=${status:-unknown}
  printf '  Tunnel:    cloudflared (%s)\n' "$status"
fi
MOTD
fi

pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Proxmox UI description ────────────────────────────────────────────────────
CF_NOTE=""
[[ "$INSTALL_CLOUDFLARED" -eq 1 ]] && CF_NOTE=" + Cloudflare Tunnel"
NPM_DESC="<a href='http://${CT_IP}:${APP_PORT}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>NPM Admin</a>
<details><summary>Details</summary>Nginx Proxy Manager (Podman/Quadlet, SQLite)${CF_NOTE} on Debian ${DEBIAN_VERSION} LXC
Tag: ${APP_TAG}
Created by npm-quadlet.sh</details>"
pct set "$CT_ID" --description "$NPM_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "    CT: $CT_ID | IP: ${CT_IP} | Admin: http://${CT_IP}:${APP_PORT}/"
echo "    Image:   ${APP_IMAGE}"
echo "    DB:      SQLite (embedded at /data/database.sqlite)"
echo "    Quadlet: ${QUADLET_FILE}"
echo "    Data:    ${APP_DIR}/data  ${APP_DIR}/letsencrypt"
echo "    Policy:  $([ "$AUTO_UPDATE" -eq 1 ] && echo "auto-update (re-pull pinned ${APP_TAG})" || echo "pinned (manual)")"
if [[ "$INSTALL_CLOUDFLARED" -eq 1 ]]; then
  echo "    Tunnel:  cloudflared installed — pct exec $CT_ID -- systemctl status cloudflared"
fi
echo ""
echo "    pct exec $CT_ID -- systemctl status npm.service"
echo "    pct exec $CT_ID -- journalctl -u npm.service --no-pager -n 50"
echo "    pct exec $CT_ID -- /usr/local/bin/npm-maint.sh update <tag>  # e.g. 2.15.2 — no :latest"
echo "    pct exec $CT_ID -- /usr/local/bin/npm-maint.sh auto-update   # re-pull pinned tag (if AUTO_UPDATE=1)"
echo "    pct exec $CT_ID -- /usr/local/bin/npm-maint.sh version"
echo "    Backup/restore: use PBS or PVE snapshots"
echo ""
echo "    First visit to the admin UI opens the setup wizard to create the admin account."
echo "    Proxy hosts (from another CT): http | <ct-ip>:<port> | enable Websockets Support where needed"
echo "    Ports 80, 443 and ${APP_PORT} listen on all CT interfaces (Network=host) — restrict ${APP_PORT} with the PVE firewall if needed."
echo "    2.15.x note: Debian Trixie base + new Certbot — verify DNS-challenge cert renewals after upgrading from 2.14."
if [[ "$PODMAN_FUSE_OVERLAY" -eq 1 ]]; then
  echo "    Backups: fuse=1 + fuse-overlayfs can deadlock under snapshot-mode vzdump/PBS (freezer)."
  echo "             Use stop-mode backups for this CT, or test PODMAN_FUSE_OVERLAY=0 (on a less critical CT first)."
fi
echo ""
