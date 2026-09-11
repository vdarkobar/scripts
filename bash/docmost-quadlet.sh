#!/usr/bin/env bash
set -Eeo pipefail
umask 022
export LC_ALL=C
# Safety revision: 2026-09-11. Fresh Proxmox CT creator; maintenance runs inside the CT.
# Verification fix: privileged PostgreSQL settings are checked as postgres.

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
# floating tags are rejected. Floating minors (0.95) are rejected.
APP_IMAGE_REPO="docker.io/docmost/docmost"
APP_TAG="0.95.0"                     # full version like 0.95.0
# PostgreSQL: MAJOR.MINOR only (18.6). "latest" and major-only tags are rejected —
# a major jump (18 → 19) cannot start on the old data directory and needs
# pg_upgrade / dump+restore, which this script does not automate.
POSTGRES_IMAGE_REPO="docker.io/library/postgres"
POSTGRES_TAG="18.6"                  # MAJOR.MINOR like 18.6 (optional -trixie/-alpine suffix)
# Redis: pinned full version. Major-only tags (8) are rejected.
REDIS_IMAGE_REPO="docker.io/library/redis"
REDIS_TAG="8.10.1"                   # full version like 8.10.1
DEBIAN_VERSION=13

# Auto-update policy
# AUTO_UPDATE=0 (default): timer installed but disabled; manual updates via
#   docmost-maint.sh update <tag> / update-postgres <tag> / update-redis <tag>
# AUTO_UPDATE=1: docmost-update.timer re-pulls the CURRENT tags of all three
#   images daily at UPDATE_TIME and restarts only the services whose image ID
#   changed; stateful failures retain the target after startup.
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
INITIAL_WAIT_SECONDS=180
UPDATE_WAIT_SECONDS=1800             # permit migrations; a timeout does not stop the app
# Bare IPs (192.168.1.20) or network CIDRs (192.168.1.0/24).
# Empty array prompts before CT creation; pressing Enter allows any source
# on APP_PORT (IPv4/IPv6). UFW stays enabled. Set client/NPM sources to restrict.
UFW_ALLOWED_SOURCES=()
SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/docmost-quadlet.sh"
SCRIPT_LOCAL="/root/docmost-quadlet.sh"

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
#   /usr/local/sbin/docmost-ufw-check                  (service-start firewall guard)
#   /etc/default/ufw, /etc/ufw/ufw.conf               (in-CT IPv4/IPv6 policy)
#   /etc/ufw/user.rules, /etc/ufw/user6.rules         (configured source allows)
#   /opt/docmost/postgres-init/10-docmost.sh        (restricted application role bootstrap)
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
[[ "$CPU" =~ ^(0|[1-9][0-9]*)$ ]] && (( CPU >= 1 )) || { echo "  ERROR: CPU must be a positive integer." >&2; exit 1; }
[[ "$RAM" =~ ^(0|[1-9][0-9]*)$ ]] && (( RAM >= 1024 )) || { echo "  ERROR: RAM must be >= 1024 MB (Node app + PostgreSQL + Redis)." >&2; exit 1; }
[[ "$DISK" =~ ^(0|[1-9][0-9]*)$ ]] && (( DISK >= 4 )) || { echo "  ERROR: DISK must be >= 4 GB." >&2; exit 1; }
[[ "$DEBIAN_VERSION" == 13 ]] || { echo "  ERROR: This creator requires Debian 13." >&2; exit 1; }
[[ "$APP_PORT" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "  ERROR: APP_PORT must be numeric." >&2; exit 1; }
(( APP_PORT >= 1024 && APP_PORT <= 65535 )) || { echo "  ERROR: APP_PORT must be between 1024 and 65535." >&2; exit 1; }
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
# Docmost: pinned full version (0.95.0, 0.96.0-beta-2). Floating minors (0.95) are rejected.
[[ "$APP_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: APP_TAG must be a pinned full version like 0.95.0 (floating tags like 0.95 are not accepted)." >&2
  exit 1
}
# PostgreSQL: MAJOR.MINOR (18.6), optional variant suffix. No "latest", no major-only:
# a silent major bump would leave a cluster the new binaries cannot open.
[[ "$POSTGRES_TAG" =~ ^18\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || {
  echo "  ERROR: POSTGRES_TAG must be MAJOR.MINOR like 18.6 — 'latest' and major-only tags (18) are not accepted." >&2
  exit 1
}
# Redis: pinned full version (8.10.1). Major-only tags (8) are rejected.
[[ "$REDIS_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: REDIS_TAG must be a pinned full version like 8.10.1 (floating tags like 8 are not accepted)." >&2
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


for wait_var in INITIAL_WAIT_SECONDS UPDATE_WAIT_SECONDS; do
  [[ ${!wait_var} =~ ^[1-9][0-9]{1,4}$ ]] && (( ${!wait_var} >= 30 && ${!wait_var} <= 86400 )) \
    || { echo "ERROR: $wait_var must be 30..86400 seconds." >&2; exit 1; }
done
[[ $UPDATE_TIME =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "ERROR: Invalid UPDATE_TIME." >&2; exit 1; }

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

trap 'rc=130;
  trap - ERR INT TERM HUP
  echo "  Interrupted (rc=$rc)" >&2
  echo "  Command: $BASH_COMMAND" >&2
  if [[ "${CLEANUP_ON_FAIL:-0}" -eq 1 && "${CREATED:-0}" -eq 1 ]]; then
    echo "  Cleanup: stopping/destroying CT ${CT_ID} ..." >&2
    pct stop "${CT_ID}" >/dev/null 2>&1 || true
    pct destroy "${CT_ID}" >/dev/null 2>&1 || true
  fi
  exit "$rc"
' INT TERM HUP

# ── Preflight — root & commands ───────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pvesh pveam pct pvesm qm curl python3 ip awk grep sed sort paste seq readlink cp chmod dpkg head tr flock mktemp mv rm tail bash stat timeout; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

# pveam lists templates for more than one CPU architecture. Selecting only by
# Debian version can pick an ARM64 rootfs on an AMD64 host (or vice versa),
# which creates successfully but fails when LXC executes /sbin/init.
# Serialize this creator before assigning an ID or checking its hostname.
exec 7>/run/lock/docmost-creator.lock
flock -n 7 || { echo "ERROR: Another docmost creator is running." >&2; exit 1; }

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
  Listens on:        0.0.0.0:${APP_PORT} inside the CT (Network=host) — access follows the UFW source choice below
  Podman storage:    $([ "$PODMAN_FUSE_OVERLAY" -eq 1 ] && echo "fuse-overlayfs (fuse=1)" || echo "native overlay (no FUSE)")
  Tags:              $TAGS
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled — daily at ${UPDATE_TIME} (re-pull ${APP_TAG} / ${POSTGRES_TAG} / ${REDIS_TAG})" || echo "disabled (${APP_TAG} / ${POSTGRES_TAG} / ${REDIS_TAG}, manual)")
  Cleanup on fail:   $CLEANUP_ON_FAIL (disarmed before first persistent start)
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
      [[ ! -e $SCRIPT_LOCAL ]] || SCRIPT_LOCAL="/root/docmost-quadlet-downloaded.$$.sh"
      DOWNLOAD_TEMP=$(mktemp /root/docmost-download.XXXXXX)
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

PG_ADMIN_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"

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
pct push "$CT_ID" "$tmp" /usr/local/sbin/docmost-ufw-check --perms 0755
rm -f -- "$tmp"
pct exec "$CT_ID" -- /usr/local/sbin/docmost-ufw-check

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


# ── Resolve immutable runtime images ──────────────────────────────────────────
for component in POSTGRES REDIS APP; do
  reference_var=${component}_IMAGE
  resolved=$(pct exec "$CT_ID" -- podman image inspect --format '{{.Id}}' "${!reference_var}")
  resolved=${resolved#sha256:}
  [[ $resolved =~ ^[a-f0-9]{64}$ ]] || { echo "ERROR: Invalid image ID for $component." >&2; false; }
  printf -v "${component}_IMAGE_ID" 'sha256:%s' "$resolved"
done

# ── Detect container UIDs/GIDs for bind mounts ────────────────────────────────
# Each image drops privileges to its own service user before touching the
# mount (postgres → postgres, redis → redis via gosu, docmost → node via USER).
# Bind mounts must be owned by those UIDs as seen from inside the LXC; read
# them from the images instead of hardcoding 999/1000.
POSTGRES_UID="$(pct exec "$CT_ID" -- podman run --rm --pull=never --network none --entrypoint sh "$POSTGRES_IMAGE_ID" -c 'id -u postgres' 2>/dev/null | tr -d '\r')"
POSTGRES_GID="$(pct exec "$CT_ID" -- podman run --rm --pull=never --network none --entrypoint sh "$POSTGRES_IMAGE_ID" -c 'id -g postgres' 2>/dev/null | tr -d '\r')"
REDIS_UID="$(pct exec "$CT_ID" -- podman run --rm --pull=never --network none --entrypoint sh "$REDIS_IMAGE_ID" -c 'id -u redis' 2>/dev/null | tr -d '\r')"
REDIS_GID="$(pct exec "$CT_ID" -- podman run --rm --pull=never --network none --entrypoint sh "$REDIS_IMAGE_ID" -c 'id -g redis' 2>/dev/null | tr -d '\r')"
DOCMOST_UID="$(pct exec "$CT_ID" -- podman run --rm --pull=never --network none --entrypoint sh "$APP_IMAGE_ID" -c 'id -u node' 2>/dev/null | tr -d '\r')"
DOCMOST_GID="$(pct exec "$CT_ID" -- podman run --rm --pull=never --network none --entrypoint sh "$APP_IMAGE_ID" -c 'id -g node' 2>/dev/null | tr -d '\r')"

for v in POSTGRES_UID POSTGRES_GID REDIS_UID REDIS_GID DOCMOST_UID DOCMOST_GID; do
  [[ "${!v}" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "  ERROR: Failed to detect numeric $v from container images." >&2; false; }
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
  install -d -m 0755 '${APP_DIR}' '${APP_DIR}/postgres-init'
  install -d -m 0750 -o ${POSTGRES_UID} -g ${POSTGRES_GID} '${APP_DIR}/postgresdata'
  install -d -m 0750 -o ${REDIS_UID}    -g ${REDIS_GID}    '${APP_DIR}/redis'
  install -d -m 0750 -o ${DOCMOST_UID}  -g ${DOCMOST_GID}  '${APP_DIR}/storage'
"


# ── PostgreSQL restricted application role ─────────────────────────────────────
# The bootstrap administrator and the application use separate credentials.
tmp=$(mktemp)
cat > "$tmp" <<'POSTGRES_INIT'
#!/usr/bin/env bash
set -euo pipefail
[[ ${DOCMOST_DB_PASSWORD:-} =~ ^[A-Za-z0-9]{40}$ ]] || { echo "Invalid application bootstrap secret." >&2; exit 1; }
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
CREATE ROLE docmost LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD '${DOCMOST_DB_PASSWORD}';
ALTER DATABASE docmost OWNER TO docmost;
GRANT ALL ON SCHEMA public TO docmost;
SQL
POSTGRES_INIT
pct push "$CT_ID" "$tmp" "${APP_DIR}/postgres-init/10-docmost.sh" --perms 0755
rm -f -- "$tmp"

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
# LabTag=${POSTGRES_TAG}
# LabImage=${POSTGRES_IMAGE}
Image=${POSTGRES_IMAGE_ID}
Pull=never
ContainerName=docmost-postgres
Network=host
Exec=postgres -c listen_addresses=127.0.0.1
Environment=TZ=${APP_TZ}
Environment=POSTGRES_DB=docmost
Environment=POSTGRES_USER=postgres
EnvironmentFile=${POSTGRES_ENV_FILE}
Volume=${APP_DIR}/postgresdata:/var/lib/postgresql
Volume=${APP_DIR}/postgres-init:/docker-entrypoint-initdb.d:ro
HealthCmd=pg_isready -h 127.0.0.1 -U docmost -d docmost
HealthInterval=10s
HealthTimeout=5s
HealthRetries=5
HealthStartPeriod=30s
Notify=healthy
StopTimeout=110
LogDriver=journald

[Service]
Restart=always
RestartSec=5
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
# LabTag=${REDIS_TAG}
# LabImage=${REDIS_IMAGE}
Image=${REDIS_IMAGE_ID}
Pull=never
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
StopTimeout=50
LogDriver=journald

[Service]
Restart=always
RestartSec=5
TimeoutStartSec=120
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF2

  cat > '${QUADLET_FILE}' <<EOF2
[Unit]
Description=Docmost
After=network-online.target ufw.service ${POSTGRES_QUADLET_SERVICE} ${REDIS_QUADLET_SERVICE}
Wants=network-online.target
Requires=ufw.service
Requires=${POSTGRES_QUADLET_SERVICE} ${REDIS_QUADLET_SERVICE}

[Container]
# LabTag=${APP_TAG}
# LabImage=${APP_IMAGE}
Image=${APP_IMAGE_ID}
Pull=never
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
StopTimeout=50
LogDriver=journald

[Service]
ExecStartPre=/usr/local/sbin/docmost-ufw-check
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
  printf 'POSTGRES_PASSWORD=%s\n' "$PG_ADMIN_PASSWORD"
  printf 'DOCMOST_DB_PASSWORD=%s\n' "$DB_PASSWORD"
  printf 'POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256\n'
  printf 'POSTGRES_HOST_AUTH_METHOD=scram-sha-256\n'
} | pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  umask 077
  cat > '${POSTGRES_ENV_FILE}'
  chmod 0600 '${POSTGRES_ENV_FILE}'
"
unset APP_SECRET DB_PASSWORD PG_ADMIN_PASSWORD

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
APP_IMAGE_ID=${APP_IMAGE_ID}
POSTGRES_IMAGE_REPO=${POSTGRES_IMAGE_REPO}
POSTGRES_TAG=${POSTGRES_TAG}
POSTGRES_IMAGE=${POSTGRES_IMAGE}
POSTGRES_IMAGE_ID=${POSTGRES_IMAGE_ID}
REDIS_IMAGE_REPO=${REDIS_IMAGE_REPO}
REDIS_TAG=${REDIS_TAG}
REDIS_IMAGE=${REDIS_IMAGE}
REDIS_IMAGE_ID=${REDIS_IMAGE_ID}
APP_PORT=${APP_PORT}
APP_TZ=${APP_TZ}
APP_FQDN=${APP_FQDN}
APP_URL=${APP_URL}
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
APP_DIR=/opt/docmost
ENV_FILE=$APP_DIR/.env
UNIT_DIR=/etc/containers/systemd
MAIN_SERVICE=docmost.service
LOCK=/run/lock/docmost-maint.lock
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
    POSTGRES) CONTAINER=docmost-postgres; KIND=postgres; IMAGE_RECOVERY=0 ;;
    REDIS) CONTAINER=docmost-redis; KIND=redis; IMAGE_RECOVERY=0 ;;
    APP) CONTAINER=docmost; KIND=app; IMAGE_RECOVERY=0 ;;
    *) die "Unknown component: $COMPONENT" ;;
  esac
  SERVICE=$CONTAINER.service
  UNIT=$UNIT_DIR/$CONTAINER.container
}
valid_tag() {
  case $1 in
    POSTGRES) [[ $2 =~ ^18\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] ;;
    REDIS) [[ $2 =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] ;;
    APP) [[ $2 =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] ;;
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
            "http://127.0.0.1:${STATE[APP_PORT]}/api/health") || code=000
          [[ $code =~ ^200$ ]] && value=1
          ;;
        postgres)
          timeout 5 podman exec "$container" pg_isready -q -h 127.0.0.1 -U docmost -d docmost && value=1
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
    path="$APP_DIR/postgresdata/18/docker"
    [[ $(cat "$path/PG_VERSION") == 18 ]] || die "On-disk PostgreSQL major does not match."
    uid=$(podman run --rm --pull=never --network none --entrypoint sh "$id" -c 'id -u postgres')
    gid=$(podman run --rm --pull=never --network none --entrypoint sh "$id" -c 'id -g postgres')
    [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ && $(stat -c '%u:%g' "$path") == "$uid:$gid" ]] \
      || die "PostgreSQL UID/GID differs from existing data; no recursive chown is attempted."
    version=$(podman run --rm --pull=never --network none --entrypoint postgres "$id" --version)
    [[ $version == "postgres (PostgreSQL) 18."* ]] || die "Candidate PostgreSQL binary has the wrong major."
  fi

  case $COMPONENT in
    APP) path="$APP_DIR/storage"; actual=node ;;
    REDIS) path="$APP_DIR/redis"; actual=redis ;;
    *) return 0 ;;
  esac
  uid=$(podman run --rm --pull=never --network none --entrypoint sh "$id" -c "id -u $actual")
  gid=$(podman run --rm --pull=never --network none --entrypoint sh "$id" -c "id -g $actual")
  [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ && $(stat -c '%u:%g' "$path") == "$uid:$gid" ]] \
    || die "Candidate service UID/GID differs from persistent-directory ownership."
}
pre_update_checks() {

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
        systemctl start "$MAIN_SERVICE" && wait_service docmost app "${STATE[UPDATE_WAIT_SECONDS]}" || restored=0
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

    old_variant=""; new_variant=""
    [[ $OLD_TAG != *-* ]] || old_variant=${OLD_TAG#*-}
    [[ $target != *-* ]] || new_variant=${target#*-}
    [[ $old_variant == "$new_variant" ]] || die "PostgreSQL image variant change requires migration review."
  fi

  if [[ $COMPONENT == APP ]]; then
    [[ ${OLD_TAG%%.*} == ${target%%.*} ]] || die "Application major changes require a separate migration review."
  fi
  /usr/local/sbin/docmost-ufw-check || die "Restore active UFW filtering before maintenance."
  actual=$(podman inspect --format '{{.Image}}' "$CONTAINER") || die "Cannot inspect running image."
  [[ $(image_id "$actual") == "$OLD_ID" ]] || die "Running/configured image mismatch; inspect the service."
  wait_service "$CONTAINER" "$KIND" 30 || die "$SERVICE is unhealthy before update."
  if [[ $COMPONENT != APP ]]; then
    wait_service docmost app 30 || die "Application is unhealthy before backend update."
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
    :
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
  WORK=$(mktemp -d /run/docmost-update.XXXXXX)
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
      wait_service docmost app "${STATE[UPDATE_WAIT_SECONDS]}" || die "Application did not recover after backend update."
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

[[ $EUID == 0 ]] || die "Run as root inside the docmost CT."
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
  update|update-postgres|update-redis)
    (( $# <= 2 )) || die "Usage: $0 $cmd [tag] [--yes]"
    if (( YES == 0 )); then
      exec 8</dev/tty || die "Interactive terminal or --yes is required."
    fi
    case $cmd in
      update-postgres) update_component POSTGRES "${2:-}" ;;
      update-redis) update_component REDIS "${2:-}" ;;
      update) update_component APP "${2:-}" ;;
    esac
    ;;
  auto-update)
    (( $# == 1 )) || die "auto-update takes no tag."
    [[ ${STATE[AUTO_UPDATE]} == 1 ]] || { printf '  Auto-update is disabled.\n'; exit 0; }
    YES=1
    for component in POSTGRES REDIS APP; do
      update_component "$component"
    done
    ;;
  check)
    (( $# <= 2 )) && [[ ${2:-} == "" || ${2:-} == --initial ]] || die "Usage: $0 check [--initial]"
    /usr/local/sbin/docmost-ufw-check
    budget=${STATE[UPDATE_WAIT_SECONDS]}
    [[ ${2:-} != --initial ]] || budget=${STATE[INITIAL_WAIT_SECONDS]}
    for component in POSTGRES REDIS APP; do
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
    for component in POSTGRES REDIS APP; do
      select_component "$component"; load_unit
      printf '  %s\n    tag: %s\n    configured ID: %s\n    running ID: ' "$CONTAINER" "$OLD_TAG" "$OLD_ID"
      podman inspect --format '{{.Image}}' "$CONTAINER" || true
    done
    ;;
  --help|-h|'')
    printf 'Usage: %s update [tag] [--yes] | update-postgres [tag] [--yes] | update-redis [tag] [--yes] | auto-update | check [--initial] | version\n' "$0"
    printf '  Exact image IDs; one component per operation; PBS/PVE handles data recovery.\n'
    printf '  Fresh-creator helper: do not replace an older deployed helper without migrating its control files.\n'
    ;;
  *) die "Unknown command: $cmd" ;;
esac
MAINT
pct push "$CT_ID" "$tmp" /usr/local/bin/docmost-maint.sh --perms 0755
rm -f -- "$tmp"

# ── Start via Quadlet ─────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -s -- docmost-postgres docmost-redis docmost <<'QUADLET_VALIDATE'
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
pct exec "$CT_ID" -- /usr/local/sbin/docmost-ufw-check
# Preserve the CT even if the first persistent start fails partway through.
CLEANUP_ON_FAIL=0
pct exec "$CT_ID" -- systemctl start docmost.service

# Destructive cleanup was disarmed before the first persistent service start.

# ── Verification ──────────────────────────────────────────────────────────────
sleep 30
if ! pct exec "$CT_ID" -- /usr/local/bin/docmost-maint.sh check --initial; then
  echo "ERROR: Initial readiness/image/firewall verification failed; CT $CT_ID is preserved." >&2
  exit 1
fi
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
if [[ "$TABLE_COUNT" =~ ^(0|[1-9][0-9]*)$ ]] && (( TABLE_COUNT > 0 )); then
  echo "  Database migrated (${TABLE_COUNT} tables in schema public)"
else
  echo "  ERROR: No tables found in the docmost database — migrations did not run" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u docmost.service --no-pager -n 80" >&2
  VERIFY_FAIL=1
fi


# Verify credentials and the effective database, not only pg_isready.
if ! pct exec "$CT_ID" -- python3 - <<'DATABASE_VERIFY'
import pathlib, subprocess, urllib.parse
app = "docmost"
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
encoded_password = urllib.parse.urlsplit(appenv["DATABASE_URL"]).password
if not encoded_password:
    raise SystemExit("Database verification failed: DATABASE_URL has no password")
password = urllib.parse.unquote(encoded_password)
def sql(statement, secret):
    command = ["podman", "exec", "-i", container, "bash", "-c",
               'IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql -X -w -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5432 -U "$1" -d "$1" -tAc "$2"',
               "check", app, statement]
    return subprocess.run(command, input=secret+"\n", text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
def verify_result(label, result, expected):
    if result.returncode or result.stdout.strip() != expected:
        detail = result.stderr.strip() if result.returncode else f"expected {expected!r}, got {result.stdout.strip()!r}"
        # Show the failing check and PostgreSQL error, but never credentials.
        for value in sorted({*appenv.values(), *pgenv.values(), password, encoded_password}, key=len, reverse=True):
            if value:
                detail = detail.replace(value, "[redacted]")
        raise SystemExit(f"Database verification failed [{label}]: {detail or 'query failed without diagnostic output'}")
    print(f"  Database check passed: {label}", flush=True)
verify_result("TCP password authentication", sql("SELECT 1", password), "1")
if sql("SELECT 1", "deliberately-wrong").returncode == 0:
    raise SystemExit("PostgreSQL accepted an incorrect TCP password")
print("  Database check passed: incorrect TCP password rejected", flush=True)
checks = [
    ("restricted application role", "SELECT rolcanlogin AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication AND NOT rolbypassrls FROM pg_roles WHERE rolname='docmost'", "t"),
    ("database ownership", "SELECT pg_get_userbyid(datdba)='docmost' FROM pg_database WHERE datname='docmost'", "t"),
    ("schema migrations", "SELECT count(*)>0 FROM pg_tables WHERE schemaname='public'", "t"),
]
for label, query, expected in checks:
    verify_result(label, sql(query, password), expected)
# SHOW data_directory and pg_hba_file_rules require elevated read privileges.
# Use the existing bootstrap administrator over its local Unix socket; the
# application keeps NOSUPERUSER and receives no extra roles or permissions.
admin_checks = [
    ("persistent data directory", "SHOW data_directory", "/var/lib/postgresql/18/docker"),
    ("SCRAM host authentication rules", "SELECT count(*)=0 FROM pg_hba_file_rules WHERE error IS NOT NULL OR (type LIKE 'host%' AND auth_method <> 'scram-sha-256')", "t"),
]
for label, query, expected in admin_checks:
    result = subprocess.run(["podman", "exec", container, "psql", "-X", "-w", "-v", "ON_ERROR_STOP=1",
                             "-h", "/var/run/postgresql", "-p", "5432", "-U", "postgres", "-d", app, "-tAc", query],
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    verify_result(label, result, expected)
print("  Database credentials, authentication, role, persistent path and schema verified.")
DATABASE_VERIFY
then
  VERIFY_FAIL=1
fi

if (( VERIFY_FAIL == 1 )); then
  echo "" >&2
  echo "  FATAL: Core verification failed — CT $CT_ID is preserved but the install is incomplete." >&2
  echo "  Inspect the named check above; preserve the CT and its data while resolving the failure." >&2
  exit 1
fi

# ── Auto-update timer (policy-driven) ─────────────────────────────────────────
pct exec "$CT_ID" -- bash -s -- "$UPDATE_TIME" <<'TIMER_INSTALL'
set -euo pipefail
cat > /etc/systemd/system/docmost-update.service <<EOF2
[Unit]
Description=docmost image maintenance
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/docmost-maint.sh auto-update
TimeoutStartSec=infinity
TimeoutStopSec=180
EOF2
cat > /etc/systemd/system/docmost-update.timer <<EOF2
[Unit]
Description=docmost daily image maintenance
[Timer]
OnCalendar=*-*-* $1:00
Persistent=true
[Install]
WantedBy=timers.target
EOF2
systemctl daemon-reload
TIMER_INSTALL
if [[ $AUTO_UPDATE == 1 ]]; then
  pct exec "$CT_ID" -- systemctl enable --now docmost-update.timer
else
  pct exec "$CT_ID" -- systemctl disable --now docmost-update.timer
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


cat <<OPERATIONS

  DOCMOST — OPERATIONS

  CONTAINER     $HN | CT $CT_ID | $CT_IP
  WEB/ADMIN     http://$CT_IP:$APP_PORT/
  ALLOWED FROM  $FIREWALL_ACCESS_LABEL
  FIREWALL      UFW inside the CT, IPv4 and IPv6; no PVE firewall dependency
  AUTO-UPDATE   $AUTO_UPDATE | daily $UPDATE_TIME ($APP_TZ)
  IMAGES        exact local IDs, Pull=never; old images retained for review

  RUN ON THE PROXMOX HOST
    pct enter $CT_ID
    pct exec $CT_ID -- /usr/local/bin/docmost-maint.sh version

  RUN INSIDE THE CT
    /usr/local/bin/docmost-maint.sh check
    /usr/local/bin/docmost-maint.sh update $APP_TAG
    ufw status verbose
    journalctl -u docmost.service --no-pager -n 80

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
echo "    pct exec $CT_ID -- /usr/local/bin/docmost-maint.sh update <tag>           # pin e.g. 0.96.0"
echo "    pct exec $CT_ID -- /usr/local/bin/docmost-maint.sh update-postgres <tag>  # same major only, e.g. 18.7"
echo "    pct exec $CT_ID -- /usr/local/bin/docmost-maint.sh update-redis <tag>     # pin e.g. 8.10.2"
echo "    pct exec $CT_ID -- /usr/local/bin/docmost-maint.sh auto-update            # re-pull current tags now (if AUTO_UPDATE=1)"
echo "    pct exec $CT_ID -- /usr/local/bin/docmost-maint.sh version"
echo "    Backup/restore: use PBS or PVE snapshots (take one before every Docmost update — migrations are forward-only)"
echo ""
echo "    NPM reverse proxy: http | ${CT_IP}:${APP_PORT} — enable WebSockets (realtime editing); set client_max_body_size >= ${FILE_UPLOAD_SIZE_LIMIT}"
if [[ -z "$APP_FQDN" ]]; then
  echo "    When you put it behind a domain, set Environment=APP_URL=https://<fqdn> in ${QUADLET_FILE},"
  echo "    update APP_URL/APP_FQDN in ${APP_DIR}/.env, then: systemctl daemon-reload && systemctl restart docmost.service"
fi
echo "    Port ${APP_PORT} listens on all CT interfaces (Network=host) — access follows the UFW source choice shown above."
echo "    Health probe: curl -s http://${CT_IP}:${APP_PORT}/api/health"
echo "    Mail is not configured (MAIL_DRIVER defaults to log): invites/password resets are printed to the journal."
echo "    Add MAIL_* variables to ${APP_ENV_FILE} and restart docmost.service to enable SMTP/Postmark."
echo "    Health checks: podman ps shows (healthy) for postgres/redis; systemd waits for that before starting Docmost."
if [[ "$PODMAN_FUSE_OVERLAY" -eq 1 ]]; then
  echo "    Backups: fuse=1 + fuse-overlayfs can deadlock under snapshot-mode vzdump/PBS (freezer)."
  echo "             Use stop-mode backups for this CT, or test PODMAN_FUSE_OVERLAY=0."
fi
echo ""
