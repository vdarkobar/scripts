#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID=""                             # empty = auto-assign via pvesh; set e.g. CT_ID=120 to pin
HN="docmost"
CPU=4
RAM=4096
DISK=16
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Docmost / Podman + Quadlet
APP_PORT=3000                        # Docmost binds this port on the CT interface (Network=host)
APP_TZ="Europe/Berlin"
APP_FQDN=""                          # e.g. docmost.example.com ; blank = local IP mode
                                     # set → APP_URL=https://FQDN (must match what users type — email links, redirects)
FILE_UPLOAD_SIZE_LIMIT="50mb"        # upstream default; raise client_max_body_size in NPM to match
DOCMOST_DISABLE_TELEMETRY=0          # 1 = DISABLE_TELEMETRY=true (upstream collects anonymous usage counts)
TAGS="docmost;podman;quadlet;lxc"

# Images / versions
# Docmost: full version (default) from https://hub.docker.com/r/docmost/docmost/tags
# or "latest" to track upstream. Floating minors (0.95) are rejected.
APP_IMAGE_REPO="docker.io/docmost/docmost"
APP_TAG="0.95.0"                     # full version like 0.95.0, or "latest"
# PostgreSQL: MAJOR.MINOR only (18.6). "latest" and major-only tags are rejected —
# a major jump (18 → 19) cannot start on the old data directory and needs
# pg_upgrade / dump+restore, which this script does not automate.
POSTGRES_IMAGE_REPO="docker.io/library/postgres"
POSTGRES_TAG="18.6"                  # MAJOR.MINOR like 18.6 (optional -trixie/-alpine suffix)
# Redis: full version (default) or "latest". Major-only tags (8) are rejected.
REDIS_IMAGE_REPO="docker.io/library/redis"
REDIS_TAG="8.10.1"                   # full version like 8.10.1, or "latest"
DEBIAN_VERSION=13

# Auto-update policy
# AUTO_UPDATE=0 (default): timer installed but disabled; manual updates via
#   docmost-maint.sh update <tag> / update-postgres <tag> / update-redis <tag>
# AUTO_UPDATE=1: docmost-update.timer re-pulls the CURRENT tags of all three
#   images daily at UPDATE_TIME and restarts only the services whose image ID
#   changed; a failed health check rolls back to the previous images.
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
APP_DIR="/opt/docmost"
APP_IMAGE="${APP_IMAGE_REPO}:${APP_TAG}"
POSTGRES_IMAGE="${POSTGRES_IMAGE_REPO}:${POSTGRES_TAG}"
REDIS_IMAGE="${REDIS_IMAGE_REPO}:${REDIS_TAG}"
APP_ENV_FILE="${APP_DIR}/docmost.env"
POSTGRES_ENV_FILE="${APP_DIR}/postgres.env"
QUADLET_FILE="/etc/containers/systemd/docmost.container"
QUADLET_SERVICE="docmost.service"
POSTGRES_QUADLET_FILE="/etc/containers/systemd/docmost-postgres.container"
POSTGRES_QUADLET_SERVICE="docmost-postgres.service"
REDIS_QUADLET_FILE="/etc/containers/systemd/docmost-redis.container"
REDIS_QUADLET_SERVICE="docmost-redis.service"
APP_URL=""
[[ -n "$APP_FQDN" ]] && APP_URL="https://${APP_FQDN}"

# ── Custom configs created by this script ─────────────────────────────────────
#   /etc/containers/systemd/docmost.container           (Quadlet unit — source of truth)
#   /etc/containers/systemd/docmost-postgres.container  (Quadlet unit — PostgreSQL, loopback only)
#   /etc/containers/systemd/docmost-redis.container     (Quadlet unit — Redis, loopback only)
#   /opt/docmost/docmost.env                            (APP_SECRET + DATABASE_URL — read by Quadlet, 0600)
#   /opt/docmost/postgres.env                           (POSTGRES_PASSWORD — read by Quadlet, 0600)
#   /opt/docmost/.env                                   (runtime state — read by maint script)
#   /opt/docmost/postgresdata/                          (PostgreSQL cluster → /var/lib/postgresql)
#   /opt/docmost/redis/                                 (Redis AOF/RDB → /data)
#   /opt/docmost/storage/                               (Docmost uploads/attachments → /app/data/storage)
#   /usr/local/bin/docmost-maint.sh                     (maintenance helper)
#   /etc/systemd/system/docmost-update.service
#   /etc/systemd/system/docmost-update.timer
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/sysctl.d/99-hardening.conf

# ── Config validation ─────────────────────────────────────────────────────────
[[ "$HN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || { echo "  ERROR: HN is not a valid hostname: $HN" >&2; exit 1; }
[[ "$CPU" =~ ^[0-9]+$ ]] && (( CPU >= 1 )) || { echo "  ERROR: CPU must be a positive integer." >&2; exit 1; }
[[ "$RAM" =~ ^[0-9]+$ ]] && (( RAM >= 1024 )) || { echo "  ERROR: RAM must be >= 1024 MB (Node app + PostgreSQL + Redis)." >&2; exit 1; }
[[ "$DISK" =~ ^[0-9]+$ ]] && (( DISK >= 4 )) || { echo "  ERROR: DISK must be >= 4 GB." >&2; exit 1; }
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }
[[ "$APP_PORT" =~ ^[0-9]+$ ]] || { echo "  ERROR: APP_PORT must be numeric." >&2; exit 1; }
(( APP_PORT >= 1 && APP_PORT <= 65535 )) || { echo "  ERROR: APP_PORT must be between 1 and 65535." >&2; exit 1; }
(( APP_PORT != 5432 && APP_PORT != 6379 )) || { echo "  ERROR: APP_PORT collides with PostgreSQL (5432) or Redis (6379) on the shared host network." >&2; exit 1; }
[[ "$AUTO_UPDATE" =~ ^[01]$ ]] || { echo "  ERROR: AUTO_UPDATE must be 0 or 1." >&2; exit 1; }
[[ "$DOCMOST_DISABLE_TELEMETRY" =~ ^[01]$ ]] || { echo "  ERROR: DOCMOST_DISABLE_TELEMETRY must be 0 or 1." >&2; exit 1; }
[[ "$PODMAN_FUSE_OVERLAY" =~ ^[01]$ ]] || { echo "  ERROR: PODMAN_FUSE_OVERLAY must be 0 or 1." >&2; exit 1; }
[[ "$CLEANUP_ON_FAIL" =~ ^[01]$ ]] || { echo "  ERROR: CLEANUP_ON_FAIL must be 0 or 1." >&2; exit 1; }
# Image repos are interpolated into podman, sed, the Quadlet units and .env.
for v in APP_IMAGE_REPO POSTGRES_IMAGE_REPO REDIS_IMAGE_REPO; do
  [[ "${!v}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*[A-Za-z0-9]$ ]] || {
    echo "  ERROR: $v must look like registry/namespace/name (no tag, no spaces)." >&2
    exit 1
  }
done
# Docmost: "latest" or full version (0.95.0, 0.96.0-beta-2). Floating minors (0.95) are rejected.
[[ "$APP_TAG" == "latest" || "$APP_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: APP_TAG must be 'latest' or a full version like 0.95.0 (floating tags like 0.95 are not accepted)." >&2
  exit 1
}
# PostgreSQL: MAJOR.MINOR (18.6), optional variant suffix. No "latest", no major-only:
# a silent major bump would leave a cluster the new binaries cannot open.
[[ "$POSTGRES_TAG" =~ ^[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || {
  echo "  ERROR: POSTGRES_TAG must be MAJOR.MINOR like 18.6 — 'latest' and major-only tags (18) are not accepted." >&2
  exit 1
}
# Redis: "latest" or full version (8.10.1). Major-only tags (8) are rejected.
[[ "$REDIS_TAG" == "latest" || "$REDIS_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: REDIS_TAG must be 'latest' or a full version like 8.10.1 (floating tags like 8 are not accepted)." >&2
  exit 1
}
[[ "$FILE_UPLOAD_SIZE_LIMIT" =~ ^[0-9]+(kb|mb|gb)$ ]] || { echo "  ERROR: FILE_UPLOAD_SIZE_LIMIT must look like 50mb or 1gb." >&2; exit 1; }
[[ "$UPDATE_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "  ERROR: UPDATE_TIME must be HH:MM (24h), e.g. 03:00." >&2; exit 1; }
[[ -e "/usr/share/zoneinfo/${APP_TZ}" ]] || { echo "  ERROR: APP_TZ not found in /usr/share/zoneinfo: $APP_TZ" >&2; exit 1; }
[[ "$APP_TZ" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)+$ ]] || { echo "  ERROR: APP_TZ contains invalid characters." >&2; exit 1; }
if [[ -n "$APP_FQDN" ]]; then
  [[ "$APP_FQDN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]] \
    || { echo "  ERROR: APP_FQDN is not a valid hostname: $APP_FQDN" >&2; exit 1; }
fi
[[ "$TAGS" =~ ^[A-Za-z0-9._-]+(;[A-Za-z0-9._-]+)*$ ]] || { echo "  ERROR: TAGS must be a semicolon-separated list without spaces." >&2; exit 1; }
for pkg in "${EXTRA_PACKAGES[@]}"; do
  [[ "$pkg" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || { echo "  ERROR: Invalid package name in EXTRA_PACKAGES: $pkg" >&2; exit 1; }
done

# ── Trap cleanup ──────────────────────────────────────────────────────────────
# rc is captured before the trap is reset; $LINENO is the failing line at top
# level (BASH_LINENO[0] is 0 outside a function). After CREATED=1, failing
# checks must use `false` rather than `exit 1` so this trap runs cleanup.
trap 'rc=$?;
  trap - ERR
  echo "  ERROR: failed (rc=$rc) near line ${LINENO:-?}" >&2
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

  Docmost Quadlet LXC Creator — Configuration
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
  PostgreSQL image:  $POSTGRES_IMAGE (127.0.0.1:5432)
  Redis image:       $REDIS_IMAGE (127.0.0.1:6379)
  App port:          $APP_PORT
  Upload limit:      $FILE_UPLOAD_SIZE_LIMIT
  Telemetry:         $([ "$DOCMOST_DISABLE_TELEMETRY" -eq 1 ] && echo "disabled" || echo "enabled (upstream default)")
  Timezone:          $APP_TZ
  FQDN:              $([ -n "$APP_FQDN" ] && echo "$APP_FQDN (APP_URL=https://${APP_FQDN})" || echo "(no public FQDN — APP_URL=http://<CT-IP>:${APP_PORT})")
  Listens on:        0.0.0.0:${APP_PORT} inside the CT (Network=host) — reachable from the whole LAN
  Podman storage:    $([ "$PODMAN_FUSE_OVERLAY" -eq 1 ] && echo "fuse-overlayfs (fuse=1)" || echo "native overlay (no FUSE)")
  Tags:              $TAGS
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled — daily at ${UPDATE_TIME} (re-pull ${APP_TAG} / ${POSTGRES_TAG} / ${REDIS_TAG})" || echo "disabled (${APP_TAG} / ${POSTGRES_TAG} / ${REDIS_TAG}, manual)")
  Cleanup on fail:   $CLEANUP_ON_FAIL (until first service start; CT preserved after that)
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/docmost-quadlet.sh"
SCRIPT_LOCAL="/root/docmost-quadlet.sh"
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

# ── Generate secrets ──────────────────────────────────────────────────────────
# DB_PASSWORD goes into DATABASE_URL unencoded, so it is alphanumeric only.
# APP_SECRET signs sessions/JWTs (upstream: >= 32 chars, openssl rand -hex 32).
set +o pipefail
DB_PASSWORD="$(head -c 4096 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 40)"
APP_SECRET="$(head -c 4096 /dev/urandom | tr -dc 'a-f0-9' | head -c 64)"
set -o pipefail
[[ ${#DB_PASSWORD} -eq 40 && ${#APP_SECRET} -eq 64 ]] || { echo "  ERROR: Failed to generate secrets." >&2; exit 1; }

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
[[ -n "$CT_IP" ]] || { echo "  ERROR: No IPv4 address acquired via DHCP within timeout." >&2; false; }
echo "  CT $CT_ID is up — IP: $CT_IP"

printf 'root:%s\n' "$PASSWORD" | pct exec "$CT_ID" -- chpasswd
unset PASSWORD PW1 PW2

# APP_URL must be the URL users actually open: Docmost builds absolute links
# (invites, password reset, share links) from it.
if [[ -z "$APP_URL" ]]; then
  APP_URL="http://${CT_IP}:${APP_PORT}"
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
[[ "$CGROUPS_VERSION" == "v2" ]] || { echo "  ERROR: Quadlet requires cgroup v2 inside the CT; podman reports '${CGROUPS_VERSION}'." >&2; false; }
GRAPH_DRIVER="$(pct exec "$CT_ID" -- podman info --format '{{.Store.GraphDriverName}}' 2>/dev/null || echo "?")"
[[ "$GRAPH_DRIVER" == "overlay" ]] || { echo "  ERROR: Podman storage driver is '${GRAPH_DRIVER}', expected overlay." >&2; false; }
echo "  Podman: cgroup ${CGROUPS_VERSION}, storage driver ${GRAPH_DRIVER}$([ "$PODMAN_FUSE_OVERLAY" -eq 1 ] && echo " (fuse-overlayfs)" || echo " (native)")"

# ── Pull images ───────────────────────────────────────────────────────────────
for img in "$POSTGRES_IMAGE" "$REDIS_IMAGE" "$APP_IMAGE"; do
  echo "  Pulling image: ${img} ..."
  pct exec "$CT_ID" -- bash -lc "
    set -euo pipefail
    podman pull '${img}'
  "
done

# ── Detect container UIDs/GIDs for bind mounts ────────────────────────────────
# Each image drops privileges to its own service user before touching the
# mount (postgres → postgres, redis → redis via gosu, docmost → node via USER).
# Bind mounts must be owned by those UIDs as seen from inside the LXC; read
# them from the images instead of hardcoding 999/1000.
POSTGRES_UID="$(pct exec "$CT_ID" -- podman run --rm --entrypoint sh "$POSTGRES_IMAGE" -c 'id -u postgres 2>/dev/null || id -u' 2>/dev/null | tr -d '\r')"
POSTGRES_GID="$(pct exec "$CT_ID" -- podman run --rm --entrypoint sh "$POSTGRES_IMAGE" -c 'id -g postgres 2>/dev/null || id -g' 2>/dev/null | tr -d '\r')"
REDIS_UID="$(pct exec "$CT_ID" -- podman run --rm --entrypoint sh "$REDIS_IMAGE" -c 'id -u redis 2>/dev/null || id -u' 2>/dev/null | tr -d '\r')"
REDIS_GID="$(pct exec "$CT_ID" -- podman run --rm --entrypoint sh "$REDIS_IMAGE" -c 'id -g redis 2>/dev/null || id -g' 2>/dev/null | tr -d '\r')"
DOCMOST_UID="$(pct exec "$CT_ID" -- podman run --rm --entrypoint sh "$APP_IMAGE" -c 'id -u node 2>/dev/null || id -u' 2>/dev/null | tr -d '\r')"
DOCMOST_GID="$(pct exec "$CT_ID" -- podman run --rm --entrypoint sh "$APP_IMAGE" -c 'id -g node 2>/dev/null || id -g' 2>/dev/null | tr -d '\r')"

for v in POSTGRES_UID POSTGRES_GID REDIS_UID REDIS_GID DOCMOST_UID DOCMOST_GID; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "  ERROR: Failed to detect numeric $v from container images." >&2; false; }
done
echo "  Bind-mount ownership: postgres=${POSTGRES_UID}:${POSTGRES_GID} redis=${REDIS_UID}:${REDIS_GID} docmost=${DOCMOST_UID}:${DOCMOST_GID}"

# ── Prepare persistent paths ──────────────────────────────────────────────────
# Docmost stack persistent state (all of it):
#   /opt/docmost/postgresdata/   PostgreSQL cluster (→ /var/lib/postgresql; PG18 puts
#                                PGDATA at <mount>/18/docker — initdb creates it)
#   /opt/docmost/redis/          Redis AOF + RDB (→ /data; BullMQ job queue state)
#   /opt/docmost/storage/        uploads, attachments, page exports (→ /app/data/storage)
# Only the top-level mount directories are created here; PostgreSQL and Redis
# initialize their own subdirectories on first start.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  install -d -m 0755 '${APP_DIR}'
  install -d -m 0750 -o ${POSTGRES_UID} -g ${POSTGRES_GID} '${APP_DIR}/postgresdata'
  install -d -m 0750 -o ${REDIS_UID}    -g ${REDIS_GID}    '${APP_DIR}/redis'
  install -d -m 0750 -o ${DOCMOST_UID}  -g ${DOCMOST_GID}  '${APP_DIR}/storage'
"

# ── Quadlet unit files ────────────────────────────────────────────────────────
# Rootful Quadlet: /etc/containers/systemd/ — no linger, no --user flags needed.
# systemd daemon-reload triggers the Quadlet generator; the three *.service
# units are created as transient units and WantedBy=multi-user.target handles
# boot start.
# Network=host bypasses Netavark NAT issues on Debian LXC. All three containers
# share the CT network stack, so PostgreSQL and Redis are told to listen on
# 127.0.0.1 only and Docmost reaches them there; PORT= tells Docmost which port
# to bind on the CT interface instead of PublishPort=.
# The backends carry a HealthCmd and Notify=healthy: systemd only marks them
# active once pg_isready / PING succeed, so Docmost's Requires=/After= really
# waits for a usable database instead of a merely started container (Docmost
# runs its migrations at startup and needs the DB immediately). With
# Notify=healthy the unit stays "activating" until the first healthy result,
# so TimeoutStartSec must exceed HealthStartPeriod plus initdb / AOF replay.
# Secrets live in docmost.env / postgres.env (0600) via EnvironmentFile=, so the
# unit files contain none and can stay 0644.
TELEMETRY_LINE=""
[[ "$DOCMOST_DISABLE_TELEMETRY" -eq 1 ]] && TELEMETRY_LINE="Environment=DISABLE_TELEMETRY=true"

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  mkdir -p /etc/containers/systemd

  cat > '${POSTGRES_QUADLET_FILE}' <<EOF2
[Unit]
Description=PostgreSQL for Docmost
After=network-online.target
Wants=network-online.target

[Container]
Image=${POSTGRES_IMAGE}
ContainerName=docmost-postgres
Network=host
Exec=postgres -c listen_addresses=127.0.0.1
Environment=TZ=${APP_TZ}
Environment=POSTGRES_DB=docmost
Environment=POSTGRES_USER=docmost
EnvironmentFile=${POSTGRES_ENV_FILE}
Volume=${APP_DIR}/postgresdata:/var/lib/postgresql
HealthCmd=pg_isready -h 127.0.0.1 -U docmost -d docmost
HealthInterval=10s
HealthTimeout=5s
HealthRetries=5
HealthStartPeriod=30s
Notify=healthy
LogDriver=journald

[Service]
Restart=always
TimeoutStartSec=180
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF2

  cat > '${REDIS_QUADLET_FILE}' <<EOF2
[Unit]
Description=Redis for Docmost (queues + realtime)
After=network-online.target
Wants=network-online.target

[Container]
Image=${REDIS_IMAGE}
ContainerName=docmost-redis
Network=host
Exec=redis-server --bind 127.0.0.1 --protected-mode yes --appendonly yes --maxmemory-policy noeviction --loglevel warning
Environment=TZ=${APP_TZ}
Volume=${APP_DIR}/redis:/data
HealthCmd=redis-cli -h 127.0.0.1 ping
HealthInterval=10s
HealthTimeout=5s
HealthRetries=5
HealthStartPeriod=10s
Notify=healthy
LogDriver=journald

[Service]
Restart=always
TimeoutStartSec=120
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF2

  cat > '${QUADLET_FILE}' <<EOF2
[Unit]
Description=Docmost
After=network-online.target ${POSTGRES_QUADLET_SERVICE} ${REDIS_QUADLET_SERVICE}
Wants=network-online.target
Requires=${POSTGRES_QUADLET_SERVICE} ${REDIS_QUADLET_SERVICE}

[Container]
Image=${APP_IMAGE}
ContainerName=docmost
Network=host
Environment=TZ=${APP_TZ}
Environment=PORT=${APP_PORT}
Environment=APP_URL=${APP_URL}
Environment=STORAGE_DRIVER=local
Environment=FILE_UPLOAD_SIZE_LIMIT=${FILE_UPLOAD_SIZE_LIMIT}
Environment=REDIS_URL=redis://127.0.0.1:6379
${TELEMETRY_LINE}
EnvironmentFile=${APP_ENV_FILE}
Volume=${APP_DIR}/storage:/app/data/storage
LogDriver=journald

[Service]
Restart=always
RestartSec=5
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF2

  chmod 0644 '${POSTGRES_QUADLET_FILE}' '${REDIS_QUADLET_FILE}' '${QUADLET_FILE}'
"

# ── Container credentials files ───────────────────────────────────────────────
# Read by Quadlet via EnvironmentFile= (podman --env-file). Written UNQUOTED —
# podman keeps quotes as part of the value. Streamed over stdin so credentials
# never appear in host or CT argv, and no temp file is created.
{
  printf '# Docmost container secrets — managed by docmost-quadlet.sh\n'
  printf 'APP_SECRET=%s\n' "$APP_SECRET"
  printf 'DATABASE_URL=postgresql://docmost:%s@127.0.0.1:5432/docmost?schema=public\n' "$DB_PASSWORD"
} | pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  umask 077
  cat > '${APP_ENV_FILE}'
  chmod 0600 '${APP_ENV_FILE}'
"

{
  printf '# PostgreSQL container secrets — managed by docmost-quadlet.sh\n'
  printf 'POSTGRES_PASSWORD=%s\n' "$DB_PASSWORD"
} | pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  umask 077
  cat > '${POSTGRES_ENV_FILE}'
  chmod 0600 '${POSTGRES_ENV_FILE}'
"
unset APP_SECRET DB_PASSWORD

# ── Runtime state file ────────────────────────────────────────────────────────
# .env is not read by Quadlet or systemd. It is the maint script's source of
# truth for current image tags and policy flags. Keep it in sync with the
# Quadlet units whenever an image is updated.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > '${APP_DIR}/.env' <<EOF2
APP_IMAGE_REPO=${APP_IMAGE_REPO}
APP_TAG=${APP_TAG}
APP_IMAGE=${APP_IMAGE}
POSTGRES_IMAGE_REPO=${POSTGRES_IMAGE_REPO}
POSTGRES_TAG=${POSTGRES_TAG}
POSTGRES_IMAGE=${POSTGRES_IMAGE}
REDIS_IMAGE_REPO=${REDIS_IMAGE_REPO}
REDIS_TAG=${REDIS_TAG}
REDIS_IMAGE=${REDIS_IMAGE}
APP_PORT=${APP_PORT}
APP_TZ=${APP_TZ}
APP_FQDN=${APP_FQDN}
APP_URL=${APP_URL}
AUTO_UPDATE=${AUTO_UPDATE}
EOF2
  chmod 0600 '${APP_DIR}/.env'
"

# ── Maintenance script ────────────────────────────────────────────────────────
# update <tag>:          Docmost — pull → sed Image= in Quadlet file → sed .env →
#   daemon-reload → restart → /api/health check; rollback restores both files,
#   daemon-reload, restart. Docmost migrations are forward-only: once a new
#   version has migrated the schema, the old image may not start — the PVE
#   snapshot taken before the update is the real rollback.
# update-postgres <tag>: same flow for the PostgreSQL unit, same MAJOR only
#   (minor releases share the data format; a major jump needs pg_upgrade).
#   Docmost is restarted afterwards (Requires= stops it with the DB).
# update-redis <tag>:    same flow for the Redis unit; Docmost restarted afterwards.
# auto-update:  re-pull ALL THREE current tags; restart only what changed
#   (+ Docmost whenever a backend changed); rollback re-tags the previous
#   image IDs and restarts.
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/docmost-maint.sh && chmod 0755 /usr/local/bin/docmost-maint.sh' <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR="${APP_DIR:-/opt/docmost}"
QUADLET_FILE="/etc/containers/systemd/docmost.container"
POSTGRES_QUADLET_FILE="/etc/containers/systemd/docmost-postgres.container"
REDIS_QUADLET_FILE="/etc/containers/systemd/docmost-redis.container"
SERVICE="docmost.service"
POSTGRES_SERVICE="docmost-postgres.service"
REDIS_SERVICE="docmost-redis.service"
CONTAINER="docmost"
POSTGRES_CONTAINER="docmost-postgres"
REDIS_CONTAINER="docmost-redis"
ENV_FILE="${APP_DIR}/.env"

need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF2
  Docmost Maintenance (Quadlet)
  ─────────────────────────────
  Usage:
    $0 update <tag> [--yes]            # Docmost:    latest, or pin e.g. 0.96.0
    $0 update-postgres <tag> [--yes]   # PostgreSQL: MAJOR.MINOR only, same major (e.g. 18.7)
    $0 update-redis <tag> [--yes]      # Redis:      latest, or pin e.g. 8.10.2
    $0 auto-update                     # re-pull all current tags (only if AUTO_UPDATE=1)
    $0 version

  Notes:
    - update pulls the tag, updates the Quadlet unit and .env, restarts the service
    - Docmost runs DB migrations on start; they are forward-only. Rolling the image
      back after a migrated start may fail — restore the PVE snapshot in that case.
    - PostgreSQL major upgrades (18 → 19) are NOT automated: dump/restore or
      pg_upgrade manually, then set the new tag.
    - auto-update is called by docmost-update.timer; it never changes the tags
    - to switch between tracking and pinning: update latest / update <full tag>
    - backup and restore are handled by PBS and PVE snapshots
    - take a PVE snapshot before manual updates: pct snapshot <CT_ID> pre-update-\$(date +%Y%m%d)
EOF2
}

[[ -d "$APP_DIR" ]]               || die "APP_DIR not found: $APP_DIR"
[[ -f "$ENV_FILE" ]]              || die "Missing env file: $ENV_FILE"
[[ -f "$QUADLET_FILE" ]]          || die "Missing Quadlet unit: $QUADLET_FILE"
[[ -f "$POSTGRES_QUADLET_FILE" ]] || die "Missing Quadlet unit: $POSTGRES_QUADLET_FILE"
[[ -f "$REDIS_QUADLET_FILE" ]]    || die "Missing Quadlet unit: $REDIS_QUADLET_FILE"

# One maintenance operation at a time — a manual update must not overlap the timer.
LOCK_FILE="/run/lock/docmost-maint.lock"
mkdir -p /run/lock
exec 9>"$LOCK_FILE"
flock -n 9 || die "Another docmost-maint.sh operation is already running."

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
  [[ "$port" =~ ^[0-9]+$ ]] && printf '%s' "$port" || printf '3000'
}

current_image()  { env_val APP_IMAGE; }
current_repo()   { env_val APP_IMAGE_REPO; }
current_tag()    { local img; img="$(current_image)"; echo "${img##*:}"; }
postgres_image() { env_val POSTGRES_IMAGE; }
postgres_repo()  { env_val POSTGRES_IMAGE_REPO; }
postgres_tag()   { local img; img="$(postgres_image)"; echo "${img##*:}"; }
redis_image()    { env_val REDIS_IMAGE; }
redis_repo()     { env_val REDIS_IMAGE_REPO; }
redis_tag()      { local img; img="$(redis_image)"; echo "${img##*:}"; }

running_image_id() {
  podman inspect --format '{{.Image}}' "$1" 2>/dev/null || true
}

image_id_of() {
  podman image inspect --format '{{.Id}}' "$1" 2>/dev/null || true
}

# /api/health returns 200 only after migrations ran and the app is serving.
# Long loop: migrations on a big workspace can take a while.
wait_for_app() {
  local port code
  port="$(app_port)"
  for i in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${port}/api/health" 2>/dev/null || echo 000)"
    [[ "$code" == "200" ]] && return 0
    sleep 2
  done
  return 1
}

wait_for_postgres() {
  for i in $(seq 1 30); do
    if podman exec "$POSTGRES_CONTAINER" pg_isready -h 127.0.0.1 -U docmost -d docmost >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_redis() {
  local pong
  for i in $(seq 1 20); do
    pong="$(podman exec "$REDIS_CONTAINER" redis-cli -h 127.0.0.1 ping 2>/dev/null || true)"
    [[ "$pong" == "PONG" ]] && return 0
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

# update <tag> [--yes] — switch Docmost to "latest" or a pinned version
update_app() {
  local new_tag="" skip_confirm=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) skip_confirm=1; shift ;;
      *) new_tag="$1"; shift ;;
    esac
  done

  local old_tag repo old_image new_image old_id tmp_env tmp_quadlet
  [[ -n "$new_tag" ]] || die "Usage: docmost-maint.sh update <tag>"
  [[ "$new_tag" == "latest" || "$new_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] \
    || die "Invalid tag: $new_tag — use 'latest' or a full version like 0.96.0."

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

  # Pre-update guard: a Docmost restart re-runs migrations; refuse if the DB is not there.
  wait_for_postgres || die "PostgreSQL is not ready — fix ${POSTGRES_SERVICE} before updating Docmost."

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
      echo "  CRITICAL: rollback to ${old_image} did not become healthy (schema may already be migrated). Restore the CT from the PVE snapshot / PBS." >&2
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

  echo "  Waiting for Docmost (migrations may take a moment) ..."
  if ! wait_for_app; then
    trap - ERR
    rollback
    die "Docmost did not become healthy after update."
  fi

  trap - ERR
  cleanup
  if [[ -n "$old_id" && "$old_id" != "$(image_id_of "$new_image")" ]]; then
    podman rmi "$old_id" >/dev/null 2>&1 || true
  fi
  echo "  OK: Docmost updated to $new_tag"
}

# update-postgres <tag> [--yes] — move PostgreSQL to another minor of the SAME major
update_postgres() {
  local new_tag="" skip_confirm=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) skip_confirm=1; shift ;;
      *) new_tag="$1"; shift ;;
    esac
  done

  local old_tag repo old_image new_image old_id tmp_env tmp_quadlet old_major new_major
  [[ -n "$new_tag" ]] || die "Usage: docmost-maint.sh update-postgres <tag>"
  [[ "$new_tag" =~ ^[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] \
    || die "Invalid tag: $new_tag — PostgreSQL needs MAJOR.MINOR like 18.7 ('latest' and major-only tags are not permitted)."

  old_tag="$(postgres_tag)"
  repo="$(postgres_repo)"
  [[ -n "$repo" ]] || die "Could not read POSTGRES_IMAGE_REPO from .env"
  old_image="$(postgres_image)"
  new_image="${repo}:${new_tag}"
  old_major="${old_tag%%.*}"
  new_major="${new_tag%%.*}"
  # Guard: the data directory format changes between majors; the new binaries
  # would refuse to start on the old cluster and rollback would be the only outcome.
  [[ "$old_major" == "$new_major" ]] \
    || die "Major upgrade ${old_major} → ${new_major} is not automated. Dump/restore or pg_upgrade manually, then set the tag."
  old_id="$(image_id_of "$old_image")"
  tmp_env="$(mktemp)"
  tmp_quadlet="$(mktemp)"

  echo "  Current PostgreSQL tag: $old_tag"
  echo "  Target  PostgreSQL tag: $new_tag"

  if [[ "$skip_confirm" -eq 0 ]]; then
    confirm_or_exit || { rm -f "$tmp_env" "$tmp_quadlet"; exit 0; }
  fi

  cp -a "$ENV_FILE"              "$tmp_env"
  cp -a "$POSTGRES_QUADLET_FILE" "$tmp_quadlet"

  cleanup() { rm -f "$tmp_env" "$tmp_quadlet"; }
  rollback() {
    echo "  !! PostgreSQL update failed — rolling back and restarting ..." >&2
    cp -a "$tmp_env"     "$ENV_FILE"
    cp -a "$tmp_quadlet" "$POSTGRES_QUADLET_FILE"
    [[ -n "$old_id" ]] && podman tag "$old_id" "$old_image" >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl restart "$POSTGRES_SERVICE" || true
    systemctl restart "$SERVICE" || true
    rm -f "$tmp_env" "$tmp_quadlet"
    if wait_for_postgres && wait_for_app; then
      echo "  Rollback complete — ${old_image} is healthy again." >&2
    else
      echo "  CRITICAL: rollback to ${old_image} did not become healthy. Restore the CT from the PVE snapshot / PBS." >&2
    fi
  }
  trap rollback ERR

  echo "  Pulling target image ..."
  podman pull "$new_image"

  sed -i "s|^Image=.*|Image=${new_image}|" "$POSTGRES_QUADLET_FILE"
  sed -i \
    -e "s|^POSTGRES_TAG=.*|POSTGRES_TAG=$new_tag|" \
    -e "s|^POSTGRES_IMAGE=.*|POSTGRES_IMAGE=$new_image|" \
    "$ENV_FILE"

  # Requires= stops Docmost together with PostgreSQL; start it again explicitly.
  echo "  Reloading Quadlet and restarting PostgreSQL + Docmost ..."
  systemctl daemon-reload
  systemctl restart "$POSTGRES_SERVICE"
  systemctl restart "$SERVICE"

  echo "  Waiting for PostgreSQL and Docmost ..."
  if ! wait_for_postgres || ! wait_for_app; then
    trap - ERR
    rollback
    die "Stack did not become healthy after PostgreSQL update."
  fi

  trap - ERR
  cleanup
  if [[ -n "$old_id" && "$old_id" != "$(image_id_of "$new_image")" ]]; then
    podman rmi "$old_id" >/dev/null 2>&1 || true
  fi
  echo "  OK: PostgreSQL updated to $new_tag"
}

# update-redis <tag> [--yes] — switch Redis to "latest" or a pinned version
update_redis() {
  local new_tag="" skip_confirm=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) skip_confirm=1; shift ;;
      *) new_tag="$1"; shift ;;
    esac
  done

  local old_tag repo old_image new_image old_id tmp_env tmp_quadlet
  [[ -n "$new_tag" ]] || die "Usage: docmost-maint.sh update-redis <tag>"
  [[ "$new_tag" == "latest" || "$new_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] \
    || die "Invalid tag: $new_tag — use 'latest' or a full version like 8.10.2."

  old_tag="$(redis_tag)"
  repo="$(redis_repo)"
  [[ -n "$repo" ]] || die "Could not read REDIS_IMAGE_REPO from .env"
  old_image="$(redis_image)"
  new_image="${repo}:${new_tag}"
  old_id="$(image_id_of "$old_image")"
  tmp_env="$(mktemp)"
  tmp_quadlet="$(mktemp)"

  echo "  Current Redis tag: $old_tag"
  echo "  Target  Redis tag: $new_tag"

  if [[ "$skip_confirm" -eq 0 ]]; then
    confirm_or_exit || { rm -f "$tmp_env" "$tmp_quadlet"; exit 0; }
  fi

  cp -a "$ENV_FILE"           "$tmp_env"
  cp -a "$REDIS_QUADLET_FILE" "$tmp_quadlet"

  cleanup() { rm -f "$tmp_env" "$tmp_quadlet"; }
  rollback() {
    echo "  !! Redis update failed — rolling back and restarting ..." >&2
    cp -a "$tmp_env"     "$ENV_FILE"
    cp -a "$tmp_quadlet" "$REDIS_QUADLET_FILE"
    [[ -n "$old_id" ]] && podman tag "$old_id" "$old_image" >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl restart "$REDIS_SERVICE" || true
    systemctl restart "$SERVICE" || true
    rm -f "$tmp_env" "$tmp_quadlet"
    if wait_for_redis && wait_for_app; then
      echo "  Rollback complete — ${old_image} is healthy again." >&2
    else
      echo "  CRITICAL: rollback to ${old_image} did not become healthy. Restore the CT from the PVE snapshot / PBS." >&2
    fi
  }
  trap rollback ERR

  echo "  Pulling target image ..."
  podman pull "$new_image"

  sed -i "s|^Image=.*|Image=${new_image}|" "$REDIS_QUADLET_FILE"
  sed -i \
    -e "s|^REDIS_TAG=.*|REDIS_TAG=$new_tag|" \
    -e "s|^REDIS_IMAGE=.*|REDIS_IMAGE=$new_image|" \
    "$ENV_FILE"

  echo "  Reloading Quadlet and restarting Redis + Docmost ..."
  systemctl daemon-reload
  systemctl restart "$REDIS_SERVICE"
  systemctl restart "$SERVICE"

  echo "  Waiting for Redis and Docmost ..."
  if ! wait_for_redis || ! wait_for_app; then
    trap - ERR
    rollback
    die "Stack did not become healthy after Redis update."
  fi

  trap - ERR
  cleanup
  if [[ -n "$old_id" && "$old_id" != "$(image_id_of "$new_image")" ]]; then
    podman rmi "$old_id" >/dev/null 2>&1 || true
  fi
  echo "  OK: Redis updated to $new_tag"
}

# auto-update — re-pull all three current tags; restart only what changed
auto_update_app() {
  if [[ "$(env_flag AUTO_UPDATE)" != "1" ]]; then
    echo "  Auto-update disabled in ${ENV_FILE}; nothing to do."
    return 0
  fi

  local pg_image pg_old_id pg_new_id rd_image rd_old_id rd_new_id app_image app_old_id app_new_id
  pg_image="$(postgres_image)"
  rd_image="$(redis_image)"
  app_image="$(current_image)"
  [[ -n "$pg_image" ]]  || die "Could not read POSTGRES_IMAGE from .env"
  [[ -n "$rd_image" ]]  || die "Could not read REDIS_IMAGE from .env"
  [[ -n "$app_image" ]] || die "Could not read APP_IMAGE from .env"
  pg_old_id="$(running_image_id "$POSTGRES_CONTAINER")"
  rd_old_id="$(running_image_id "$REDIS_CONTAINER")"
  app_old_id="$(running_image_id "$CONTAINER")"

  echo "  Auto-update: re-pulling ${pg_image} ..."
  podman pull "$pg_image"
  pg_new_id="$(image_id_of "$pg_image")"
  [[ -n "$pg_new_id" ]] || die "Could not inspect pulled image ${pg_image}"

  echo "  Auto-update: re-pulling ${rd_image} ..."
  podman pull "$rd_image"
  rd_new_id="$(image_id_of "$rd_image")"
  [[ -n "$rd_new_id" ]] || die "Could not inspect pulled image ${rd_image}"

  echo "  Auto-update: re-pulling ${app_image} ..."
  podman pull "$app_image"
  app_new_id="$(image_id_of "$app_image")"
  [[ -n "$app_new_id" ]] || die "Could not inspect pulled image ${app_image}"

  local pg_changed=0 rd_changed=0 app_changed=0
  [[ -z "$pg_old_id"  || "$pg_new_id"  != "$pg_old_id"  ]] && pg_changed=1
  [[ -z "$rd_old_id"  || "$rd_new_id"  != "$rd_old_id"  ]] && rd_changed=1
  [[ -z "$app_old_id" || "$app_new_id" != "$app_old_id" ]] && app_changed=1

  if [[ "$pg_changed" -eq 0 && "$rd_changed" -eq 0 && "$app_changed" -eq 0 ]]; then
    echo "  OK: all images are already current — no restart needed."
    return 0
  fi

  rollback() {
    echo "  !! Auto-update failed — restoring previous images and restarting ..." >&2
    [[ "$pg_changed"  -eq 1 && -n "$pg_old_id"  ]] && podman tag "$pg_old_id"  "$pg_image"  >/dev/null 2>&1 || true
    [[ "$rd_changed"  -eq 1 && -n "$rd_old_id"  ]] && podman tag "$rd_old_id"  "$rd_image"  >/dev/null 2>&1 || true
    [[ "$app_changed" -eq 1 && -n "$app_old_id" ]] && podman tag "$app_old_id" "$app_image" >/dev/null 2>&1 || true
    [[ "$pg_changed" -eq 1 ]] && { systemctl restart "$POSTGRES_SERVICE" || true; }
    [[ "$rd_changed" -eq 1 ]] && { systemctl restart "$REDIS_SERVICE" || true; }
    systemctl restart "$SERVICE" || true
    if wait_for_postgres && wait_for_redis && wait_for_app; then
      echo "  Rollback complete — previous images are healthy again." >&2
    else
      echo "  CRITICAL: rollback did not become healthy (Docmost schema may already be migrated). Restore the CT from the PVE snapshot / PBS." >&2
    fi
  }
  trap rollback ERR

  if [[ "$pg_changed" -eq 1 ]]; then
    echo "  PostgreSQL image changed — restarting ${POSTGRES_SERVICE} ..."
    systemctl restart "$POSTGRES_SERVICE"
  fi
  if [[ "$rd_changed" -eq 1 ]]; then
    echo "  Redis image changed — restarting ${REDIS_SERVICE} ..."
    systemctl restart "$REDIS_SERVICE"
  fi
  # Docmost restarts when its own image changed, or after a backend restart
  # (Requires= already stopped it, and it must reconnect to the new backend).
  echo "  Restarting ${SERVICE} ..."
  systemctl restart "$SERVICE"

  echo "  Waiting for PostgreSQL, Redis and Docmost ..."
  if ! wait_for_postgres || ! wait_for_redis || ! wait_for_app; then
    trap - ERR
    rollback
    die "Stack did not become healthy after auto-update."
  fi

  trap - ERR
  [[ "$pg_changed"  -eq 1 && -n "$pg_old_id"  ]] && podman rmi "$pg_old_id"  >/dev/null 2>&1 || true
  [[ "$rd_changed"  -eq 1 && -n "$rd_old_id"  ]] && podman rmi "$rd_old_id"  >/dev/null 2>&1 || true
  [[ "$app_changed" -eq 1 && -n "$app_old_id" ]] && podman rmi "$app_old_id" >/dev/null 2>&1 || true
  echo "  OK: Docmost stack refreshed (Docmost changed: ${app_changed}, PostgreSQL changed: ${pg_changed}, Redis changed: ${rd_changed})"
}

need_root
cmd="${1:-}"
case "$cmd" in
  update)          shift; update_app "$@" ;;
  update-postgres) shift; update_postgres "$@" ;;
  update-redis)    shift; update_redis "$@" ;;
  auto-update)     auto_update_app ;;
  version)
    echo "Configured Docmost image:    $(current_image)"
    echo "Running Docmost image ID:    $(running_image_id "$CONTAINER")"
    echo "Docmost digest:              $(podman image inspect --format '{{index .RepoDigests 0}}' "$(current_image)" 2>/dev/null || echo n/a)"
    echo "Configured PostgreSQL image: $(postgres_image)"
    echo "Running PostgreSQL image ID: $(running_image_id "$POSTGRES_CONTAINER")"
    echo "PostgreSQL server version:   $(podman exec "$POSTGRES_CONTAINER" psql -U docmost -d docmost -tAc 'show server_version' 2>/dev/null || echo n/a)"
    echo "Configured Redis image:      $(redis_image)"
    echo "Running Redis image ID:      $(running_image_id "$REDIS_CONTAINER")"
    echo "AUTO_UPDATE=$(env_flag AUTO_UPDATE)"
    ;;
  ""|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
MAINT
echo "  Maintenance script deployed: /usr/local/bin/docmost-maint.sh"

# ── Start via Quadlet ─────────────────────────────────────────────────────────
# daemon-reload triggers the Quadlet generator which produces docmost.service,
# docmost-postgres.service and docmost-redis.service as transient systemd units.
# WantedBy=multi-user.target handles boot restarts. Transient units cannot be
# systemctl-enabled; daemon-reload is sufficient. Starting docmost.service pulls
# in both backends via Requires= and waits for their health checks (Notify=healthy).
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

for svc in "$POSTGRES_QUADLET_SERVICE" "$REDIS_QUADLET_SERVICE" "$QUADLET_SERVICE"; do
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
    'podman ps --filter name=^docmost$ --filter name=^docmost-postgres$ --filter name=^docmost-redis$ --format "{{.Names}}" 2>/dev/null | wc -l' \
    2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge 3 ]] && break
  sleep 2
done
pct exec "$CT_ID" -- bash -lc 'podman ps' || true

if [[ "$RUNNING" -lt 3 ]]; then
  echo "  ERROR: Expected 3 containers running (docmost, docmost-postgres, docmost-redis), found $RUNNING" >&2
  VERIFY_FAIL=1
else
  echo "  Container count OK ($RUNNING running)"
fi

if pct exec "$CT_ID" -- sh -lc 'podman exec docmost-postgres pg_isready -h 127.0.0.1 -U docmost -d docmost >/dev/null 2>&1' 2>/dev/null; then
  echo "  PostgreSQL accepts connections on 127.0.0.1:5432"
else
  echo "  ERROR: PostgreSQL did not answer pg_isready on 127.0.0.1:5432" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u docmost-postgres.service --no-pager -n 50" >&2
  VERIFY_FAIL=1
fi

RD_PONG="$(pct exec "$CT_ID" -- sh -lc 'podman exec docmost-redis redis-cli -h 127.0.0.1 ping 2>/dev/null' 2>/dev/null || true)"
if [[ "$RD_PONG" == "PONG" ]]; then
  echo "  Redis responds on 127.0.0.1:6379 (PONG)"
else
  echo "  ERROR: Redis did not answer PING on 127.0.0.1:6379" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u docmost-redis.service --no-pager -n 50" >&2
  VERIFY_FAIL=1
fi

# Network=host: the backends must be bound to loopback only, otherwise the DB
# and Redis are reachable by every host on the LAN with no auth in front of them.
EXPOSED_BACKENDS="$(pct exec "$CT_ID" -- sh -lc 'ss -Hltn 2>/dev/null | awk "\$4 ~ /:(5432|6379)\$/ && \$4 !~ /^127\\.0\\.0\\.1:/ {print \$4}"' 2>/dev/null || true)"
if [[ -z "$EXPOSED_BACKENDS" ]]; then
  echo "  PostgreSQL and Redis listen on loopback only"
else
  echo "  ERROR: backend port(s) bound beyond loopback: ${EXPOSED_BACKENDS}" >&2
  echo "  Check: pct exec $CT_ID -- ss -ltnp" >&2
  VERIFY_FAIL=1
fi

DM_HEALTHY=0
for i in $(seq 1 90); do
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc "curl -s -o /dev/null -w '%{http_code}' --max-time 3 'http://127.0.0.1:${APP_PORT}/api/health' 2>/dev/null" 2>/dev/null || echo 000)"
  case "$HTTP_CODE" in
    200)
      DM_HEALTHY=1
      break
      ;;
  esac
  sleep 2
done

if [[ "$DM_HEALTHY" -eq 1 ]]; then
  echo "  Docmost health check passed (HTTP $HTTP_CODE)"
else
  echo "  ERROR: Docmost /api/health did not return 200 on port ${APP_PORT}" >&2
  echo "  Check: pct exec $CT_ID -- systemctl status docmost.service" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u docmost.service --no-pager -n 80" >&2
  VERIFY_FAIL=1
fi

# Docmost migrates the schema on first start; an empty public schema means the
# app came up without a working DATABASE_URL (or migrations failed silently).
TABLE_COUNT="$(pct exec "$CT_ID" -- sh -lc "podman exec docmost-postgres psql -U docmost -d docmost -tAc \"select count(*) from pg_tables where schemaname='public'\" 2>/dev/null" 2>/dev/null | tr -d '[:space:]' || true)"
if [[ "$TABLE_COUNT" =~ ^[0-9]+$ ]] && (( TABLE_COUNT > 0 )); then
  echo "  Database migrated (${TABLE_COUNT} tables in schema public)"
else
  echo "  ERROR: No tables found in the docmost database — migrations did not run" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u docmost.service --no-pager -n 80" >&2
  VERIFY_FAIL=1
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
  cat > /etc/systemd/system/docmost-update.service <<EOF2
[Unit]
Description=Docmost auto-update maintenance run
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/docmost-maint.sh auto-update
EOF2

  cat > /etc/systemd/system/docmost-update.timer <<EOF2
[Unit]
Description=Docmost auto-update timer

[Timer]
OnCalendar=*-*-* ${UPDATE_TIME}:00
Persistent=true

[Install]
WantedBy=timers.target
EOF2

  systemctl daemon-reload
"
if [[ "$AUTO_UPDATE" -eq 1 ]]; then
  pct exec "$CT_ID" -- bash -lc 'systemctl enable --now docmost-update.timer'
  echo "  Auto-update timer enabled"
else
  pct exec "$CT_ID" -- bash -lc 'systemctl disable --now docmost-update.timer >/dev/null 2>&1 || true'
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
printf '\\n  Docmost (Podman/Quadlet)\\n'
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
running=\$(podman ps --filter name=^docmost$ --filter name=^docmost-postgres$ --filter name=^docmost-redis$ --format '{{.Names}}' 2>/dev/null | wc -l)
svc_status=\$(systemctl is-active docmost.service 2>/dev/null); svc_status=\${svc_status:-unknown}
pg_status=\$(systemctl is-active docmost-postgres.service 2>/dev/null); pg_status=\${pg_status:-unknown}
rd_status=\$(systemctl is-active docmost-redis.service 2>/dev/null); rd_status=\${rd_status:-unknown}
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
image=\$(awk -F= '/^APP_IMAGE=/{print \$2}' /opt/docmost/.env 2>/dev/null | tail -n1)
pg_image=\$(awk -F= '/^POSTGRES_IMAGE=/{print \$2}' /opt/docmost/.env 2>/dev/null | tail -n1)
rd_image=\$(awk -F= '/^REDIS_IMAGE=/{print \$2}' /opt/docmost/.env 2>/dev/null | tail -n1)
auto=\$(awk -F= '/^AUTO_UPDATE=/{print \$2}' /opt/docmost/.env 2>/dev/null | tail -n1)
fqdn=\$(awk -F= '/^APP_FQDN=/{print \$2}' /opt/docmost/.env 2>/dev/null | tail -n1)
port=\$(awk -F= '/^APP_PORT=/{print \$2}' /opt/docmost/.env 2>/dev/null | tail -n1)
port=\${port:-3000}
printf '  Containers: docmost + docmost-postgres + docmost-redis (%s running)\\n' \"\$running\"
printf '  Services:   docmost (%s) | postgres (%s) | redis (%s)\\n' \"\$svc_status\" \"\$pg_status\" \"\$rd_status\"
printf '  Image:      %s\\n' \"\${image:-n/a}\"
printf '  PostgreSQL: %s (127.0.0.1:5432)\\n' \"\${pg_image:-n/a}\"
printf '  Redis:      %s (127.0.0.1:6379)\\n' \"\${rd_image:-n/a}\"
printf '  Policy:     %s\\n' \"\$([ \"\$auto\" = '1' ] && echo 'auto-update daily (re-pull current tags)' || echo 'manual updates only')\"
printf '  Data:       /opt/docmost/storage  postgresdata  redis\\n'
printf '  Secrets:    /opt/docmost/docmost.env  postgres.env\\n'
printf '  Logs:       journalctl -u docmost.service -f\\n'
printf '  Maintain:   /usr/local/bin/docmost-maint.sh [update|update-postgres|update-redis|auto-update|version]\\n'
printf '  Updates:    systemctl status docmost-update.timer\\n'
if [ -n \"\$fqdn\" ]; then
  printf '  Web UI:     https://%s/\\n' \"\$fqdn\"
fi
printf '  Web UI:     http://%s:%s/\\n' \"\${ip:-n/a}\" \"\$port\"
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
DM_DESC_LINK="http://${CT_IP}:${APP_PORT}/"
if [[ -n "$APP_FQDN" ]]; then
  DM_DESC_LINK="https://${APP_FQDN}/"
fi
DM_DESC="<a href='${DM_DESC_LINK}' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Docmost</a>
<details><summary>Details</summary>Docmost (Podman/Quadlet) on Debian ${DEBIAN_VERSION} LXC
Tag: ${APP_TAG} | PostgreSQL: ${POSTGRES_TAG} | Redis: ${REDIS_TAG}
Created by docmost-quadlet.sh</details>"
pct set "$CT_ID" --description "$DM_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "    CT: $CT_ID | IP: ${CT_IP} | Web UI: http://${CT_IP}:${APP_PORT}/"
if [[ -n "$APP_FQDN" ]]; then
  echo "    Public:  https://${APP_FQDN}/"
fi
echo "    APP_URL: ${APP_URL}  (first visit creates the admin account + workspace)"
echo "    Image:   ${APP_IMAGE}"
echo "    Backends: ${POSTGRES_IMAGE} (127.0.0.1:5432) | ${REDIS_IMAGE} (127.0.0.1:6379)"
echo "    Quadlet: ${QUADLET_FILE}"
echo "             ${POSTGRES_QUADLET_FILE}"
echo "             ${REDIS_QUADLET_FILE}"
echo "    Secrets: ${APP_ENV_FILE}  (APP_SECRET, DATABASE_URL)"
echo "             ${POSTGRES_ENV_FILE}  (POSTGRES_PASSWORD)"
echo "    Data:    ${APP_DIR}/storage  ${APP_DIR}/postgresdata  ${APP_DIR}/redis"
echo "    Policy:  $([ "$AUTO_UPDATE" -eq 1 ] && echo "auto-update daily at ${UPDATE_TIME} (re-pull ${APP_TAG} / ${POSTGRES_TAG} / ${REDIS_TAG})" || echo "manual updates only (${APP_TAG} / ${POSTGRES_TAG} / ${REDIS_TAG})")"
echo ""
echo "    pct exec $CT_ID -- systemctl status docmost.service"
echo "    pct exec $CT_ID -- journalctl -u docmost.service --no-pager -n 50"
echo "    pct exec $CT_ID -- /usr/local/bin/docmost-maint.sh update <tag>           # latest, or pin e.g. 0.96.0"
echo "    pct exec $CT_ID -- /usr/local/bin/docmost-maint.sh update-postgres <tag>  # same major only, e.g. 18.7"
echo "    pct exec $CT_ID -- /usr/local/bin/docmost-maint.sh update-redis <tag>     # latest, or pin e.g. 8.10.2"
echo "    pct exec $CT_ID -- /usr/local/bin/docmost-maint.sh auto-update            # re-pull current tags now (if AUTO_UPDATE=1)"
echo "    pct exec $CT_ID -- /usr/local/bin/docmost-maint.sh version"
echo "    Backup/restore: use PBS or PVE snapshots (take one before every Docmost update — migrations are forward-only)"
echo ""
echo "    NPM reverse proxy: http | ${CT_IP}:${APP_PORT} — enable WebSockets (realtime editing); set client_max_body_size >= ${FILE_UPLOAD_SIZE_LIMIT}"
if [[ -z "$APP_FQDN" ]]; then
  echo "    When you put it behind a domain, set Environment=APP_URL=https://<fqdn> in ${QUADLET_FILE},"
  echo "    update APP_URL/APP_FQDN in ${APP_DIR}/.env, then: systemctl daemon-reload && systemctl restart docmost.service"
fi
echo "    Port ${APP_PORT} listens on all CT interfaces (Network=host) — restrict with the PVE firewall if needed."
echo "    Health probe: curl -s http://${CT_IP}:${APP_PORT}/api/health"
echo "    Mail is not configured (MAIL_DRIVER defaults to log): invites/password resets are printed to the journal."
echo "    Add MAIL_* variables to ${APP_ENV_FILE} and restart docmost.service to enable SMTP/Postmark."
echo "    Health checks: podman ps shows (healthy) for postgres/redis; systemd waits for that before starting Docmost."
if [[ "$PODMAN_FUSE_OVERLAY" -eq 1 ]]; then
  echo "    Backups: fuse=1 + fuse-overlayfs can deadlock under snapshot-mode vzdump/PBS (freezer)."
  echo "             Use stop-mode backups for this CT, or test PODMAN_FUSE_OVERLAY=0."
fi
echo ""
