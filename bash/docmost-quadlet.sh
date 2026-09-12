#!/usr/bin/env bash
set -Eeo pipefail
umask 022
export LC_ALL=C
# Safety revision: 2026-09-11. Fresh Proxmox CT creator; maintenance runs inside the CT.
# Verification fix: privileged PostgreSQL settings are checked as postgres.
# Hardening integration: 2026-09-12; supplied lab-hardening-block.sh v1.1, unchanged.

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

# Shared hardening v1.1 — Debian 13 service LXC, no forwarding
# These are the tested LXC defaults. Docmost needs no policy exception.
HARDENING_PROFILE="lxc"
HARDENING_RP_FILTER=1
HARDENING_KEEP_SSH=0                 # 0 = remove CT SSH server; 1 = preserve it
HARDENING_REMOVE_POSTFIX=1           # Docmost mail uses its app configuration, not local Postfix
HARDENING_JOURNAL_DAYS=14
HARDENING_JOURNAL_MAX_MB=256
HARDENING_JOURNAL_RUNTIME_MB=64
HARDENING_UPDATE_MAX_AGE_HOURS=72
# Creator-only "auto" resolves to the final APP_PORT after prompts.
# Otherwise use a complete space-separated list; "" means inventory-only.
# If preserving SSH, include its actual listening port in a complete TCP list.
# These lists check unexpected external listeners; they do not add UFW rules
# or establish application readiness. Loopback PostgreSQL/Redis are excluded.
HARDENING_TCP_PORTS="auto"
HARDENING_UDP_PORTS="68"             # net0 uses DHCPv4; add 546 only if DHCPv6 is actually used

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
#   /etc/update-motd.d/25-lab-hardening
#   /etc/sysctl.d/99-hardening.conf
#   /etc/apt/apt.conf.d/99-lab-hardening
#   /etc/needrestart/conf.d/99-lab-hardening.conf
#   /etc/systemd/journald.conf.d/99-lab-hardening.conf
#   /etc/systemd/system/apt-daily{,-upgrade}.service.d/90-lab-readiness.conf
#   /etc/systemd/system/lab-hardening-check.{service,timer}
#   /usr/local/sbin/lab-apt-wait-online
#   /usr/local/sbin/lab-hardening-check
#   /etc/systemd/system/ssh.{service,socket}             (masks when SSH is removed)
#   /var/lib/lab-hardening/{policy.json,status.json,last-index-refresh,check.lock}
#   /var/backups/lab-hardening/<run>/                   (configuration copies and dry-run log)

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

# Validate common tunables before creating a CT; the unchanged block validates
# them again in the guest. Port lists are checked after "auto" is resolved.
[[ $HARDENING_PROFILE == lxc || $HARDENING_PROFILE == auto ]] \
  || { echo "ERROR: HARDENING_PROFILE must be lxc (or its auto alias)." >&2; exit 1; }
[[ $HARDENING_RP_FILTER =~ ^(1|2|auto)$ && $HARDENING_KEEP_SSH =~ ^(0|1|auto)$ && $HARDENING_REMOVE_POSTFIX =~ ^[01]$ ]] \
  || { echo "ERROR: Invalid hardening rp_filter or service-removal flag." >&2; exit 1; }
for policy_var in HARDENING_JOURNAL_DAYS HARDENING_JOURNAL_MAX_MB HARDENING_JOURNAL_RUNTIME_MB HARDENING_UPDATE_MAX_AGE_HOURS; do
  [[ ${!policy_var} =~ ^[1-9][0-9]{0,3}$ ]] \
    || { echo "ERROR: $policy_var must be 1..9999." >&2; exit 1; }
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

for cmd in pveversion pvesh pveam pct pvesm qm curl python3 ip awk grep sed sort paste seq readlink cp chmod dpkg head tr flock mktemp mv rm tail bash stat timeout; do
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

# ── Final hardening listener policy ───────────────────────────────────────────
# All prompts are complete. Pass the chosen application port to the common
# block; never include the loopback-only PostgreSQL/Redis backend ports.
[[ $HARDENING_TCP_PORTS != auto ]] || HARDENING_TCP_PORTS="$APP_PORT"
for port in $HARDENING_TCP_PORTS $HARDENING_UDP_PORTS; do
  if [[ ! $port =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
    echo "ERROR: Hardening ports must be space-separated numbers from 1 to 65535." >&2
    exit 1
  fi
done

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
# The late common block backs up UFW defaults and disables its sysctl loader.
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
  for chain in INPUT FORWARD; do
    rules=$("$tool" -w 5 -S "$chain")
    grep -qx -- "-P $chain DROP" <<< "$rules"
  done
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

# ── Initial application readiness ────────────────────────────────────────────
sleep 30
if ! pct exec "$CT_ID" -- /usr/local/bin/docmost-maint.sh check --initial; then
  echo "ERROR: Initial readiness/image/firewall verification failed; CT $CT_ID is preserved." >&2
  false
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

# ── Shared hardening integration ─────────────────────────────────────────────
# No package cleanup or MOTD replacement may follow this stage. Preserve the
# CT for any hardening/final-verification failure, including ERR/INT/TERM/HUP.
CLEANUP_ON_FAIL=0
# Capture persistent user rules before the block. The block checks baseline
# UFW filtering; the creator additionally proves its selected rules survive.
UFW_RULES_BEFORE="$(pct exec "$CT_ID" -- sha256sum /etc/ufw/user.rules /etc/ufw/user6.rules)"

# BEGIN VERBATIM lab-hardening-block.sh v1.1
#!/usr/bin/env bash
# ── Shared Debian 13 LXC hardening block ───────────────────────────────────────
# Version: 1.1 (2026-09-12; LXC-only scope)
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
        addr = addr.strip('[]').split('%', 1)[0]
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
# END VERBATIM lab-hardening-block.sh v1.1

# ── Final verification ────────────────────────────────────────────────────────
# WARN (reviewed restart needed) is successful; FAIL stops the creator via ERR.
pct exec "$CT_ID" -- /usr/local/sbin/lab-hardening-check
pct exec "$CT_ID" -- /usr/local/bin/docmost-maint.sh check --initial
UFW_RULES_AFTER="$(pct exec "$CT_ID" -- sha256sum /etc/ufw/user.rules /etc/ufw/user6.rules)"
[[ $UFW_RULES_AFTER == "$UFW_RULES_BEFORE" ]] || {
  echo "ERROR: UFW user rules changed during hardening; CT $CT_ID is preserved." >&2
  false
}
pct exec "$CT_ID" -- bash -s -- "$APP_PORT" "${UFW_ALLOWED_SOURCES[@]}" <<'UFW_FINAL_VERIFY'
set -euo pipefail
export LC_ALL=C
port=$1; shift
/usr/local/sbin/docmost-ufw-check
for source in "$@"; do
  tool=iptables; prefix=ufw
  if [[ $source == *:* ]]; then tool=ip6tables; prefix=ufw6; fi
  "$tool" -w 5 -C "$prefix-user-input" -s "$source" -p tcp -m tcp --dport "$port" -j ACCEPT
done
printf '  UFW user rule files unchanged; selected TCP source allows verified.\n'
UFW_FINAL_VERIFY

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
  false
fi

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
  IMAGE UPDATES $AUTO_UPDATE | daily $UPDATE_TIME ($APP_TZ)
  OS UPDATES    Debian automatic updates; no automatic reboot; needrestart reports only
  HARDENING     v1.1 | boot/hourly drift checks; see status.json for OK/WARN
  IMAGES        exact local IDs, Pull=never; old images retained for review

  RUN ON THE PROXMOX HOST
    pct enter $CT_ID
    pct exec $CT_ID -- /usr/local/bin/docmost-maint.sh version

  RUN INSIDE THE CT
    /usr/local/bin/docmost-maint.sh check
    /usr/local/sbin/lab-hardening-check
    cat /var/lib/lab-hardening/status.json
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
echo "    Hardening: pct exec $CT_ID -- /usr/local/sbin/lab-hardening-check (WARN requires review, not an automatic restart)"
echo "    Reports: /var/lib/lab-hardening/status.json | journalctl -u lab-hardening-check.service"
echo "    Mail is not configured (MAIL_DRIVER defaults to log): invites/password resets are printed to the journal."
echo "    Add MAIL_* variables to ${APP_ENV_FILE} and restart docmost.service to enable SMTP/Postmark."
echo "    Health checks: podman ps shows (healthy) for postgres/redis; systemd waits for that before starting Docmost."
if [[ "$PODMAN_FUSE_OVERLAY" -eq 1 ]]; then
  echo "    Backups: fuse=1 + fuse-overlayfs can deadlock under snapshot-mode vzdump/PBS (freezer)."
  echo "             Use stop-mode backups for this CT, or test PODMAN_FUSE_OVERLAY=0."
fi
echo ""
