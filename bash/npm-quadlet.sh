#!/usr/bin/env bash
set -Eeo pipefail
umask 022
export LC_ALL=C
# Safety revision: 2026-09-13 r3; corrected shared hardening v1.1.2; Podman process-verifier fix retained. Fresh Proxmox CT creator; maintenance runs inside the CT.

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


# Service verification and in-CT firewall
INITIAL_WAIT_SECONDS=180
UPDATE_WAIT_SECONDS=1800             # permit migrations; a timeout does not stop the app
# Bare IPs (192.168.1.20) or network CIDRs (192.168.1.0/24).
# Empty arrays prompt separately before CT creation; Enter allows any source
# on that prompt's ports (IPv4/IPv6). UFW stays enabled in either case.
# Admin TCP 81: administrator devices or management/VPN subnets.
UFW_ALLOWED_SOURCES=()
# Proxy TCP 80/443: LAN/VPN clients or the source IP of a tunnel connector.
# Pre-filled arrays skip their own prompt. To preselect any source, use
# ("0.0.0.0/0" "::/0"). Installing cloudflared does not change these choices.
NPM_PUBLIC_SOURCES=()
UPDATE_TIME="03:00"                  # daily at CT local time
SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/npm-quadlet.sh"
SCRIPT_LOCAL="/root/npm-quadlet.sh"

# Shared hardening: this creator supports non-routing Debian 13 LXCs only.
HARDENING_PROFILE="lxc"              # service LXC, including Network=host; no router/VPS mode
HARDENING_RP_FILTER=1                # 1=strict; 2=loose for reviewed asymmetric paths
HARDENING_KEEP_SSH=0                 # 0=remove SSH; use the Proxmox console/pct exec
HARDENING_REMOVE_POSTFIX=1           # 1=remove Postfix; NPM does not need a local mail server
HARDENING_JOURNAL_DAYS=14
HARDENING_JOURNAL_MAX_MB=256
HARDENING_JOURNAL_RUNTIME_MB=64
HARDENING_UPDATE_MAX_AGE_HOURS=72
# "auto" is creator-only: resolve TCP to 80 443 and the finalized APP_PORT.
# A custom list replaces auto; include all intended external listeners/Streams.
# Empty means inventory-only for that protocol, NOT deny-all or a firewall rule.
# Lists do not open UFW ports, prove listeners exist, or prove application health.
# If KEEP_SSH=1, supply an explicit TCP list including the actual SSH port(s);
# SSH access also requires its own reviewed UFW policy, separate from NPM access.
HARDENING_TCP_PORTS="auto"
HARDENING_UDP_PORTS="68 546"          # DHCPv4/v6 clients; ip6=manual does not exclude UDP 546
# Optional cloudflared uses HTTP/2 transport; QUIC's random UDP sockets conflict
# with this strict listener policy. Only published application tunnels, no VPN.
CLOUDFLARED_METRICS_PORT=20241        # loopback-only; never added to the external lists

# Derived
APP_DIR="/opt/npm"
APP_IMAGE="${APP_IMAGE_REPO}:${APP_TAG}"
QUADLET_FILE="/etc/containers/systemd/npm.container"
QUADLET_SERVICE="npm.service"

# ── Custom configs created by this script ─────────────────────────────────────
#   /usr/local/sbin/npm-ufw-check                  (service-start firewall guard)
#   /usr/local/sbin/npm-listener-check             (post-start listener verification)
#   /etc/ufw/npm-expected-sources.conf              (expected TCP port/source pairs)
#   /etc/default/ufw, /etc/ufw/ufw.conf               (in-CT IPv4/IPv6 policy)
#   /etc/ufw/user.rules, /etc/ufw/user6.rules         (configured source allows)
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
#   /usr/local/sbin/npm-prepare-backend           (image-specific loopback adaptation)
#   /usr/local/sbin/npm-health-check              (JSON API contract)
#   /usr/local/sbin/npm-state-check               (read-only mounts/SQLite/process checks)
#   /opt/npm/runtime/<image-id>/index.js           (read-only mount over /app/index.js)
#   /opt/npm/runtime/<image-id>/provenance.json    (source and generated file hashes)
#   /opt/npm/hardening-settings.json              (exact settings for disposable repeat test)
#   /opt/npm/ufw-before-hardening.*               (persistent/effective policy checkpoint)
#   /etc/sysctl.d/99-hardening.conf
#   /etc/apt/apt.conf.d/99-lab-hardening
#   /etc/needrestart/conf.d/99-lab-hardening.conf
#   /etc/systemd/journald.conf.d/99-lab-hardening.conf
#   /etc/systemd/system/apt-daily{,-upgrade}.service.d/90-lab-readiness.conf
#   /etc/systemd/system/lab-hardening-check.{service,timer}
#   /usr/local/sbin/lab-{apt-wait-online,hardening-check,postfix-check}
#   /etc/update-motd.d/25-lab-hardening
#   /var/lib/lab-hardening/                       (policy, reports, lock, index-refresh stamp)
#   /var/backups/lab-hardening/<run>/             (common configuration backups)
#   /etc/systemd/system/ssh.{service,socket}      (masks when SSH is removed)
#   /etc/systemd/system/postfix*.{service,socket,path} (masks when Postfix is removed)
#   /etc/cloudflared/token                       (0600; optional)
#   /etc/systemd/system/cloudflared.service       (optional native tunnel service)
#   /etc/apt/sources.list.d/cloudflared.list       (optional)
#   /usr/share/keyrings/cloudflare-public-v2.gpg  (optional)

# ── Config validation ─────────────────────────────────────────────────────────
[[ "$HN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || { echo "  ERROR: HN is not a valid hostname: $HN" >&2; exit 1; }
[[ "$CPU" =~ ^(0|[1-9][0-9]*)$ ]] && (( CPU >= 1 )) || { echo "  ERROR: CPU must be a positive integer." >&2; exit 1; }
[[ "$RAM" =~ ^(0|[1-9][0-9]*)$ ]] && (( RAM >= 256 )) || { echo "  ERROR: RAM must be >= 256 MB." >&2; exit 1; }
[[ "$DISK" =~ ^(0|[1-9][0-9]*)$ ]] && (( DISK >= 1 )) || { echo "  ERROR: DISK must be >= 1 GB." >&2; exit 1; }
[[ "$DEBIAN_VERSION" == 13 ]] || { echo "  ERROR: This creator requires Debian 13." >&2; exit 1; }
[[ "$APP_PORT" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "  ERROR: APP_PORT must be numeric." >&2; exit 1; }
(( APP_PORT == 81 )) || { echo "  ERROR: NPM admin port is fixed at 81." >&2; exit 1; }
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


for wait_var in INITIAL_WAIT_SECONDS UPDATE_WAIT_SECONDS; do
  [[ ${!wait_var} =~ ^[1-9][0-9]{1,4}$ ]] && (( ${!wait_var} >= 30 && ${!wait_var} <= 86400 )) \
    || { echo "ERROR: $wait_var must be 30..86400 seconds." >&2; exit 1; }
done
[[ $UPDATE_TIME =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "ERROR: Invalid UPDATE_TIME." >&2; exit 1; }

[[ $HARDENING_PROFILE == lxc ]] || { echo "ERROR: This creator requires HARDENING_PROFILE=lxc." >&2; exit 1; }
[[ $HARDENING_RP_FILTER =~ ^[12]$ && $HARDENING_KEEP_SSH =~ ^[01]$ && $HARDENING_REMOVE_POSTFIX =~ ^[01]$ ]] \
  || { echo "ERROR: Invalid hardening flag." >&2; exit 1; }
for setting in HARDENING_JOURNAL_DAYS HARDENING_JOURNAL_MAX_MB HARDENING_JOURNAL_RUNTIME_MB HARDENING_UPDATE_MAX_AGE_HOURS; do
  [[ ${!setting} =~ ^[1-9][0-9]{0,3}$ ]] || { echo "ERROR: $setting must be 1..9999." >&2; exit 1; }
done
for setting in HARDENING_TCP_PORTS HARDENING_UDP_PORTS; do
  [[ $setting != HARDENING_TCP_PORTS || ${!setting} != auto ]] || continue
  [[ ${!setting} != *[$'\t\r\n']* ]] || { echo "ERROR: $setting must use spaces between ports." >&2; exit 1; }
  for port in ${!setting}; do
    [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )) \
      || { echo "ERROR: $setting needs port numbers 1..65535." >&2; exit 1; }
  done
done
if [[ $HARDENING_KEEP_SSH == 1 && $HARDENING_TCP_PORTS == auto ]]; then
  echo "ERROR: Retained SSH requires an explicit TCP inventory and a separately reviewed SSH access policy." >&2
  exit 1
fi
[[ $CLOUDFLARED_METRICS_PORT =~ ^[1-9][0-9]{3,4}$ ]] && (( CLOUDFLARED_METRICS_PORT >= 1024 && CLOUDFLARED_METRICS_PORT <= 65535 && CLOUDFLARED_METRICS_PORT != 3000 )) \
  || { echo "ERROR: CLOUDFLARED_METRICS_PORT must be 1024..65535, excluding NPM backend 3000." >&2; exit 1; }

# ── Trap cleanup ──────────────────────────────────────────────────────────────
STAGE="preflight"
# ShellCheck does not track simultaneous assignments at trap entry.
# shellcheck disable=SC2154
trap 'rc=$? failed_line=$LINENO failed_command=$BASH_COMMAND
  trap - ERR
  IFS= read -r failed_command <<< "$failed_command" || true
  case "$failed_command" in *token*|*TOKEN*|*PASSWORD*|*chpasswd*) failed_command="credential delivery (redacted)" ;; esac
  printf "  ERROR: stage=%s rc=%s near host line %s; command: %.180s\n" "${STAGE:-unknown}" "$rc" "$failed_line" "$failed_command" >&2
  echo "  See the preceding guest error for the original failure." >&2
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
  echo "  Stage: ${STAGE:-unknown}; CT ${CT_ID:-unassigned}" >&2
  if [[ "${CLEANUP_ON_FAIL:-0}" -eq 1 && "${CREATED:-0}" -eq 1 ]]; then
    echo "  Cleanup: stopping/destroying CT ${CT_ID} ..." >&2
    pct stop "${CT_ID}" >/dev/null 2>&1 || true
    pct destroy "${CT_ID}" >/dev/null 2>&1 || true
  fi
  exit "$rc"
' INT TERM HUP

# ── Preflight — root & commands ───────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pveversion pvesh pveam pct pvesm qm curl python3 ip awk grep sed sort paste seq readlink cp chmod dpkg head tr flock mktemp mv rm tail bash stat timeout sha256sum cmp; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

# Verified Proxmox-only boundary: do not forward the host SSH login marker.
# The unchanged standalone block still rejects SSH removal in a real guest SSH session.
pveversion >/dev/null
unset SSH_CONNECTION

# pveam lists templates for more than one CPU architecture. Selecting only by
# Debian version can pick an ARM64 rootfs on an AMD64 host (or vice versa),
# which creates successfully but fails when LXC executes /sbin/init.
# Serialize this creator before assigning an ID or checking its hostname.
exec 7>/run/lock/npm-creator.lock
flock -n 7 || { echo "ERROR: Another npm creator is running." >&2; exit 1; }

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
# failed install) — preserve it and use a new HN and CT ID.
EXISTING_CT="$(pct list 2>/dev/null | awk -v h="$HN" 'NR>1 && $NF==h {print $1}' | head -n1)"
if [[ -n "$EXISTING_CT" ]]; then
  echo "  ERROR: A CT with hostname '${HN}' already exists on this node (CT ${EXISTING_CT})." >&2
  echo "  Preserve that CT. For a fresh installation choose a new hostname and unused CT ID." >&2
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
  Hardening:         v1.1.2 | lxc | rp_filter=$HARDENING_RP_FILTER
  Listener policy:   TCP=$HARDENING_TCP_PORTS | UDP=$HARDENING_UDP_PORTS
  Timezone:          $APP_TZ
  Disable IPv6 app:  $([ "$NPM_DISABLE_IPV6" -eq 1 ] && echo "yes" || echo "no")
  Cloudflare Tunnel: $([ "$INSTALL_CLOUDFLARED" -eq 1 ] && echo "yes" || echo "no")
  Listens on:        0.0.0.0:80, :443, :${APP_PORT} inside the CT (Network=host)
  Firewall sources: admin TCP ${APP_PORT} and proxy TCP 80/443 are selected separately below
  Podman storage:    $([ "$PODMAN_FUSE_OVERLAY" -eq 1 ] && echo "fuse-overlayfs (fuse=1)" || echo "native overlay (no FUSE)")
  Tags:              $TAGS
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled (re-pull pinned $APP_TAG)" || echo "disabled (pinned $APP_TAG, manual)")
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
      [[ ! -e $SCRIPT_LOCAL ]] || SCRIPT_LOCAL="/root/npm-quadlet-downloaded.$$.sh"
      DOWNLOAD_TEMP=$(mktemp /root/npm-download.XXXXXX)
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
# Administrator access and proxy traffic have independent source lists.
# Enter without sources opens only the ports named in that prompt.
FIREWALL_ACCESS_LABEL=""
if (( ${#UFW_ALLOWED_SOURCES[@]} == 0 )); then
  cat <<FIREWALL_HELP
  Firewall access for NPM administration on TCP $APP_PORT:
  Enter administrator device IPs or management/VPN subnets.
  This choice applies only to the admin interface. Proxy TCP 80/443 is separate.

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
  if ! read -r -p "  Admin sources (space-separated) [Enter = any]: " firewall_input <&8; then
    echo "ERROR: Firewall input interrupted; no access policy selected." >&2
    exit 1
  fi
  read -r -a UFW_ALLOWED_SOURCES <<< "$firewall_input"
  if (( ${#UFW_ALLOWED_SOURCES[@]} == 0 )); then
    UFW_ALLOWED_SOURCES=("0.0.0.0/0" "::/0")
    FIREWALL_ACCESS_LABEL="Any source (IPv4 and IPv6)"
  fi
fi

NPM_PUBLIC_ACCESS_LABEL=""
if (( ${#NPM_PUBLIC_SOURCES[@]} == 0 )); then
  cat <<FIREWALL_HELP

  Firewall access for NPM proxy traffic on TCP 80 and 443:
  Enter LAN/VPN client IPs or subnets, or the source IP of your tunnel connector.
  For direct public internet access, press Enter to allow any source.
  This choice does not change access to the admin interface on TCP $APP_PORT.

    One device:       192.168.1.20
    Whole subnet:     192.168.1.0/24
    Multiple sources: 192.168.1.20 192.168.2.0/24
    IPv6 examples:    fd00::20 or fd00::/64

  CIDR format: network-address/prefix-length
  Example: 192.168.1.0/24 covers the 192.168.1.x subnet.
  Use the network address (no host bits); replace examples with your addresses.
  If cloudflared runs in this CT and uses localhost, loopback is already allowed.
  Select any additional devices/networks that should reach NPM directly.

  Press Enter to allow any source on TCP 80/443 (IPv4 and IPv6).
  UFW stays enabled. Any source includes the internet if this CT is reachable.

FIREWALL_HELP
  if ! read -r -p "  Proxy sources (space-separated) [Enter = any]: " firewall_input <&8; then
    echo "ERROR: Firewall input interrupted; no proxy access policy selected." >&2
    exit 1
  fi
  read -r -a NPM_PUBLIC_SOURCES <<< "$firewall_input"
  if (( ${#NPM_PUBLIC_SOURCES[@]} == 0 )); then
    NPM_PUBLIC_SOURCES=("0.0.0.0/0" "::/0")
    NPM_PUBLIC_ACCESS_LABEL="Any source (IPv4 and IPv6)"
  fi
fi
if ! python3 - "${UFW_ALLOWED_SOURCES[@]}" "${NPM_PUBLIC_SOURCES[@]}" <<'FIREWALL_VALIDATE'
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
NPM_PUBLIC_ACCESS_LABEL="${NPM_PUBLIC_ACCESS_LABEL:-${NPM_PUBLIC_SOURCES[*]}}"
echo "  UFW admin TCP $APP_PORT allowed sources: $FIREWALL_ACCESS_LABEL"
echo "  UFW proxy TCP 80/443 allowed sources: $NPM_PUBLIC_ACCESS_LABEL"

# Finalize the creator-only auto setting after prompts, before dispatch.
[[ $HARDENING_TCP_PORTS != auto ]] || HARDENING_TCP_PORTS="80 443 $APP_PORT"
echo "  Hardening external inventory: TCP=[$HARDENING_TCP_PORTS] UDP=[$HARDENING_UDP_PORTS]"

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

STAGE="CT creation"
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
for _ in $(seq 1 60); do
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

STAGE="OS prerequisites"
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

STAGE="UFW prerequisites"
# ── UFW inside the CT ─────────────────────────────────────────────────────────
# Fresh CT only. Network=host uses this CT's INPUT chain.
pct exec "$CT_ID" -- bash -s -- "$APP_PORT" "${UFW_ALLOWED_SOURCES[@]}" <<'UFWSETUP'
set -euo pipefail
export LC_ALL=C
port=$1; shift
(( $# > 0 )) || { echo "ERROR: No allowed source addresses."; false; }
iptables -w 5 -S INPUT >/dev/null
ip6tables -w 5 -S INPUT >/dev/null
# Preserve template rule files; never reset UFW.
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

pct exec "$CT_ID" -- bash -s -- "${NPM_PUBLIC_SOURCES[@]}" <<'NPM_PUBLIC_RULES'
set -euo pipefail
for source in "$@"; do
  for port in 80 443; do
    ufw allow in proto tcp from "$source" to any port "$port"
    tool=iptables; prefix=ufw
    if [[ $source == *:* ]]; then tool=ip6tables; prefix=ufw6; fi
    "$tool" -w 5 -C "$prefix-user-input" -s "$source" -p tcp -m tcp --dport "$port" -j ACCEPT
  done
done
NPM_PUBLIC_RULES

# Persist the selected policy as data for service-start and maintenance checks.
# This file records expected allows; editing it does not apply UFW rules.
tmp=$(mktemp)
{
  printf '# Expected NPM inbound TCP allows: port source\n'
  printf '# Keep this file and UFW rules aligned when changing access.\n'
  printf '# This file is parsed as data, never sourced as a shell script.\n'
  for source in "${UFW_ALLOWED_SOURCES[@]}"; do
    printf '%s %s\n' "$APP_PORT" "$source"
  done
  for source in "${NPM_PUBLIC_SOURCES[@]}"; do
    printf '80 %s\n443 %s\n' "$source" "$source"
  done
} > "$tmp"
pct push "$CT_ID" "$tmp" /etc/ufw/npm-expected-sources.conf --perms 0644
rm -f -- "$tmp"

tmp=$(mktemp)
cat > "$tmp" <<'UFWCHECK'
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
# Startup guard: active filtering and default-deny in both address families.
# Also verify every saved port/source allow. This is not an exhaustive audit
# of additional rules or network reachability; test from client hosts too.
trap 'printf "ERROR: NPM firewall check failed near line %s. Inspect ufw status verbose and /etc/ufw/npm-expected-sources.conf.\n" "$LINENO" >&2' ERR
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
# NPM proxies connections; kernel routing is never required here.
for path in /proc/sys/net/ipv4/ip_forward /proc/sys/net/{ipv4,ipv6}/conf/*/forwarding; do
  [[ -r $path && $(cat "$path") == 0 ]] || { echo "ERROR: Forwarding enabled/unavailable: $path" >&2; exit 1; }
done
policy=/etc/ufw/npm-expected-sources.conf
[[ -r $policy ]] || { printf 'ERROR: Missing firewall policy: %s\n' "$policy" >&2; exit 1; }
declare -A seen=()
while read -r port source extra || [[ -n ${port:-} ]]; do
  [[ -n $port && $port != \#* ]] || continue
  if [[ ! $port =~ ^(80|81|443)$ || -z $source || -n $extra || ! $source =~ ^[0-9A-Fa-f.:/]+$ ]]; then
    printf 'ERROR: Invalid port/source row in %s.\n' "$policy" >&2
    exit 1
  fi
  tool=/usr/sbin/iptables; prefix=ufw
  if [[ $source == *:* ]]; then tool=/usr/sbin/ip6tables; prefix=ufw6; fi
  if ! "$tool" -w 5 -C "$prefix-user-input" -s "$source" -p tcp -m tcp --dport "$port" -j ACCEPT; then
    printf 'ERROR: Missing expected UFW allow: TCP %s from %s.\n' "$port" "$source" >&2
    exit 1
  fi
  seen[$port]=1
done < "$policy"
for port in 80 81 443; do
  [[ ${seen[$port]:-0} == 1 ]] || { printf 'ERROR: No expected sources recorded for TCP %s.\n' "$port" >&2; exit 1; }
done
UFWCHECK
pct push "$CT_ID" "$tmp" /usr/local/sbin/npm-ufw-check --perms 0755
rm -f -- "$tmp"
pct exec "$CT_ID" -- /usr/local/sbin/npm-ufw-check

tmp=$(mktemp)
cat > "$tmp" <<'LISTENERCHECK'
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
# Called only after the app starts, never from ExecStartPre.
# Argument: NPM_DISABLE_IPV6 (0 = verify IPv4 and IPv6; 1 = IPv4 only).
(( $# == 1 )) && [[ $1 =~ ^[01]$ ]] || { echo "Usage: $0 <NPM_DISABLE_IPV6: 0|1>" >&2; exit 1; }
for family in 4 6; do
  [[ $family != 6 || $1 == 0 ]] || continue
  listeners=$(ss -H -ltn"$family") || { echo "ERROR: Cannot inspect IPv$family TCP listeners." >&2; exit 1; }
  for port in 80 81 443; do
    if ! awk -v family="$family" -v port="$port" '
      $4 == "0.0.0.0:" port && family == 4 {found=1}
      ($4 == "[::]:" port || $4 == "*:" port) && family == 6 {found=1}
      END {exit !found}
    ' <<< "$listeners"; then
      printf 'ERROR: Missing NPM wildcard IPv%s TCP listener on port %s. Check ss -ltnp and journalctl -u npm.service.\n' "$family" "$port" >&2
      exit 1
    fi
  done
done
# The internal Node API must exist on IPv4 loopback and nowhere else.
listeners=$(ss -H -ltn)
awk '
  $4 ~ /:3000$/ {if ($4 != "127.0.0.1:3000") bad=1; else found=1}
  END {exit (!found || bad)}
' <<< "$listeners" || { echo "ERROR: NPM backend 3000 must listen only on 127.0.0.1." >&2; exit 1; }
LISTENERCHECK
pct push "$CT_ID" "$tmp" /usr/local/sbin/npm-listener-check --perms 0755
rm -f -- "$tmp"

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

STAGE="image pull"
# ── Pull image ────────────────────────────────────────────────────────────────
echo "  Pulling NPM image: ${APP_IMAGE} ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman pull '${APP_IMAGE}'
"


# ── Resolve immutable runtime images ──────────────────────────────────────────
# This one-component loop retains the existing maintenance flow.
# shellcheck disable=SC2043
for component in APP; do
  reference_var=${component}_IMAGE
  resolved=$(pct exec "$CT_ID" -- podman image inspect --format '{{.Id}}' "${!reference_var}")
  resolved=${resolved#sha256:}
  [[ $resolved =~ ^[a-f0-9]{64}$ ]] || { echo "ERROR: Invalid image ID for $component." >&2; false; }
  printf -v "${component}_IMAGE_ID" 'sha256:%s' "$resolved"
done

# ── Prepare persistent paths ──────────────────────────────────────────────────
# NPM persistent state (SQLite mode):
#   /opt/npm/data/          — database.sqlite, nginx configs, access lists, custom pages
#   /opt/npm/letsencrypt/   — certificates
# The inspected default PUID/PGID is 0:0. The image prepares its own subdirectories;
# post-start checks verify the real process identities and persistent ownership.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  install -d -m 0755 '${APP_DIR}'
  install -d -m 0755 '${APP_DIR}/data' '${APP_DIR}/letsencrypt'
"

# ── NPM image compatibility and application verification helpers ──────────────
# The v2.15.1 source binds its private Node API on all addresses, with no bind
# setting. Generate a read-only /app/index.js mount with only the host argument
# added. Preserve /init, with-contenv, UID setup, migrations and timers.
# The helper verifies the actual image source hashes against the reviewed tag.
# New image IDs are re-extracted before update; changed startup code needs review.
# Source: https://github.com/NginxProxyManager/nginx-proxy-manager/tree/v2.15.1
STAGE="NPM image compatibility"
# Preserve image and startup evidence even if compatibility validation fails.
CLEANUP_ON_FAIL=0

tmp=$(mktemp)
cat > "$tmp" <<'NPM_PREPARE_BACKEND_PY'
#!/usr/bin/python3
"""Generate/check the reviewed, image-specific loopback API adaptation.

Generation runs only an image inspection process with no network or app data.
The stock /init, s6 environment loading, UID setup, migrations and timers remain.
Unknown source hashes require review; this is not a generic source-code rewriter.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile

os.environ['LC_ALL'] = 'C'
os.environ['PATH'] = '/usr/sbin:/usr/bin:/sbin:/bin'
REVIEWED_SOURCE = 'NginxProxyManager/nginx-proxy-manager v2.15.1 (76f09db)'
EXPECTED = {
    "/app/index.js": "7711aba15d15bfc4e5ceedcc87bbc816e896ba422a20cd1fce25836551743e95",
    "/app/routes/main.js": "9e16728d7e3d616285a9bf7d1b460ba6999353b85c53e69dc192c4157aceabd7",
    "/app/lib/config.js": "82a93ab3adea95433a7b08384167dbc186e2543e6ef4a749f1c3e896a2ce76fd",
    "/app/setup.js": "bddb5731dc2325a0c17fabe131137410851cbdd43819a0e3f5ddae2fc18d38f5",
    "/app/migrate.js": "4fc6c7c1bcdb153d309fee3632d87d69d880e95484c56b46e36063a0c0807598",
    "/usr/bin/common.sh": "32d29efe6fb3c1ba7643911dcbede92b1b2e22a0440c16104619c853c590486a",
    "/etc/nginx/conf.d/production.conf": "677812ddd009eefe3e53fcb102c83dedd711a53e984d4654228e89a3abf87cc5",
    "/etc/s6-overlay/s6-rc.d/backend/run": "85a1c192c3f7883e8714a91e4b52bc5f9b5177c4631832ed73d66b01d3dd3c80",
    "/etc/s6-overlay/s6-rc.d/nginx/run": "de26824e601aba96cddf6bac877705d61c75ffacddbd53bdffdbcc04f3481b79",
    "/etc/s6-overlay/s6-rc.d/prepare/up": "9e4336c0b67f921f23ab49e6a475f7aad370df7c2e3766f83d17414036b66739",
    "/etc/s6-overlay/s6-rc.d/prepare/00-all.sh": "4d52492bdfbc070f328e624c2b78513d7644a5ccbcab7d419e90be38867d66a3",
    "/etc/s6-overlay/s6-rc.d/prepare/10-usergroup.sh": "2fefd29ff0be63a912cc2b03ea86e09bb9fd5ac254be18dd7f01ad3744e37707",
    "/etc/s6-overlay/s6-rc.d/prepare/20-paths.sh": "5479548f4711d95448364815858532146ba80eef4075e9dddac689ee0b985a30",
    "/etc/s6-overlay/s6-rc.d/prepare/30-ownership.sh": "49d0da0077e76b742741f7dc069a1bd0005c2696cd99e7351cb877ba43aeaf8d",
    "/etc/s6-overlay/s6-rc.d/prepare/40-dynamic.sh": "44be52f29662c066612be88f83b5c83846df2fa3342b0868d01f69074100e38a",
    "/etc/s6-overlay/s6-rc.d/prepare/50-ipv6.sh": "7e9645fce5385b81eb13fc0c563a884fb5fd41a8a2e9eed3e8edb2220c9c0a09",
    "/etc/s6-overlay/s6-rc.d/prepare/60-secrets.sh": "2176fbbbede65d2cf6102a4b253d341f45436a0b8a478ddf023e94293c21fa9f"
}
PATCHED_SHA256 = 'f9e5a7a4ec9269fe0dadae64da03a88fcccdceab0a2594cfc0b057620451fde3'

def run(args):
    return subprocess.run(args, check=True, capture_output=True, timeout=90).stdout

def digest(data):
    return hashlib.sha256(data).hexdigest()

try:
    check_only = len(sys.argv) == 3 and sys.argv[1] == '--check'
    if not check_only and len(sys.argv) != 2:
        raise ValueError('Usage: npm-prepare-backend [--check] sha256:<image-id>')
    image = sys.argv[-1]
    if os.geteuid() != 0 or not re.fullmatch(r'sha256:[a-f0-9]{64}', image):
        raise ValueError('Root and an immutable image ID are required.')
    parent = Path('/opt/npm/runtime')
    directory = parent / image.removeprefix('sha256:')
    target = directory / 'index.js'
    provenance = directory / 'provenance.json'
    if check_only:
        for path in [parent, directory, target, provenance]:
            info = path.lstat()
            if path.is_symlink() or info.st_uid != 0 or info.st_mode & 0o022:
                raise ValueError(f'Unsafe startup adaptation ownership/type: {path}')
        record = json.loads(provenance.read_text())
        if (record.get('image_id') != image or record.get('source_hashes') != EXPECTED
                or record.get('generated_sha256') != PATCHED_SHA256
                or digest(target.read_bytes()) != PATCHED_SHA256):
            raise ValueError('Startup adaptation or provenance drifted.')
        print('NPM loopback startup adaptation verified: ' + image)
        raise SystemExit(0)

    config = json.loads(run(['podman', 'image', 'inspect', image]))[0]['Config']
    env = dict(item.split('=', 1) for item in config.get('Env', []) if '=' in item)
    if (config.get('Entrypoint') != ['/init'] or config.get('User', '') not in ['', '0', 'root', '0:0']
            or config.get('WorkingDir') != '/app' or env.get('NODE_ENV') != 'production'
            or env.get('PUID', '0') != '0' or env.get('PGID', '0') != '0'
            or env.get('DEVELOPMENT', 'false') != 'false'
            or any(k.startswith(('DB_MYSQL_', 'DB_POSTGRES_', 'INITIAL_ADMIN_')) for k in env)
            or env.get('DB_SQLITE_FILE', '/data/database.sqlite') != '/data/database.sqlite'):
        raise ValueError('Unreviewed image entrypoint, user, environment or database mode.')
    # Read the actual selected image, not a tag URL or an older reference copy.
    archive = run(['podman', 'run', '--rm', '--pull=never', '--network', 'none',
                   '--read-only', '--entrypoint', '/bin/tar', image,
                   '-cf', '-', *EXPECTED])
    files = {}
    with tarfile.open(fileobj=io.BytesIO(archive)) as bundle:
        for member in bundle.getmembers():
            name = '/' + member.name.lstrip('/')
            if name not in EXPECTED or not member.isfile() or member.size > 1024 * 1024:
                raise ValueError('Unreviewed source archive entry: ' + name)
            files[name] = bundle.extractfile(member).read()
    for path, expected in EXPECTED.items():
        actual = digest(files.get(path, b''))
        if actual != expected:
            raise ValueError(f'Unreviewed startup source: {path}; SHA-256 {actual}; expected {expected}. '
                             'Review this image before installation/update; no wildcard fallback.')
    source = files['/app/index.js']
    old = b'app.listen(3000, () => {'
    if source.count(old) != 1:
        raise ValueError('Reviewed listen call was not found exactly once.')
    modified = source.replace(old, b'app.listen(3000, "127.0.0.1", () => {', 1)
    if digest(modified) != PATCHED_SHA256:
        raise ValueError('Generated startup source differs from the reviewed adaptation.')
    parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    if directory.exists():
        # Never replace an adaptation a running container may be using.
        subprocess.run([sys.executable, __file__, '--check', image], check=True)
    else:
        with tempfile.TemporaryDirectory(prefix='.npm-backend-', dir=parent) as work:
            temporary = Path(work)
            generated = temporary / 'index.js'
            generated.write_bytes(modified)
            generated.chmod(0o644)
            # Use the image's own Node version; no app execution or production mounts.
            run(['podman', 'run', '--rm', '--pull=never', '--network', 'none', '--read-only',
                 '--volume', str(generated) + ':/app/index.js:ro', '--entrypoint', 'node',
                 image, '--check', '/app/index.js'])
            record = {'source': REVIEWED_SOURCE, 'image_id': image, 'source_hashes': EXPECTED,
                      'generated_sha256': PATCHED_SHA256,
                      'change': 'Only app.listen(3000) gains host 127.0.0.1; all other bytes retained.'}
            metadata = temporary / 'provenance.json'
            metadata.write_text(json.dumps(record, indent=2) + '\n')
            metadata.chmod(0o644)
            temporary.chmod(0o755)
            os.rename(temporary, directory)
    print('NPM loopback startup source prepared: ' + image)
except (OSError, ValueError, KeyError, subprocess.SubprocessError, tarfile.TarError) as exc:
    # No image environment dump, tokens, or application data in diagnostics.
    print('ERROR: NPM image compatibility: ' + str(exc), file=sys.stderr)
    raise SystemExit(1)
NPM_PREPARE_BACKEND_PY
pct push "$CT_ID" "$tmp" /usr/local/sbin/npm-prepare-backend --perms 0755
rm -f -- "$tmp"

tmp=$(mktemp)
cat > "$tmp" <<'NPM_HEALTH_CHECK_PY'
#!/usr/bin/python3
"""Read-only NPM v2.15.1 API health contract; no login or configuration writes."""
import json
import sys
import urllib.request

try:
    if len(sys.argv) != 2 or sys.argv[1] != '81':
        raise ValueError('Usage: npm-health-check 81')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open('http://127.0.0.1:' + sys.argv[1] + '/api/', timeout=4) as response:
        if response.status != 200:
            raise ValueError('API HTTP status is not 200.')
        data = json.load(response)
    if (not isinstance(data, dict) or data.get('status') != 'OK'
            or type(data.get('setup')) is not bool
            or not isinstance(data.get('version'), dict)
            or any(type(data['version'].get(k)) is not int for k in ['major', 'minor', 'revision'])):
        raise ValueError('API JSON does not match the reviewed status/setup/version contract.')
    print('NPM API OK; admin account ' + ('configured' if data['setup'] else 'awaiting setup wizard'))
except Exception as exc:
    print('ERROR: NPM API health: ' + str(exc), file=sys.stderr)
    raise SystemExit(1)
NPM_HEALTH_CHECK_PY
pct push "$CT_ID" "$tmp" /usr/local/sbin/npm-health-check --perms 0755
rm -f -- "$tmp"

tmp=$(mktemp)
cat > "$tmp" <<'NPM_STATE_CHECK_PY'
#!/usr/bin/python3
"""Read-only mount, ownership, process and SQLite validation; no repair actions."""
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys

os.environ['LC_ALL'] = 'C'
os.environ['PATH'] = '/usr/sbin:/usr/bin:/sbin:/bin'

def run(args):
    result = subprocess.run(args, check=False, capture_output=True, text=True, timeout=30)
    if result.returncode:
        # These checks have no credential arguments. Preserve stderr, never the
        # captured inspect stdout, which can contain environment secrets.
        detail = result.stderr.strip()[:2000] or '(no stderr)'
        raise RuntimeError(f'{" ".join(args)} exited {result.returncode}: {detail}')
    return result.stdout

def npm_processes():
    # Podman 5.4 supports hpid/comm. "gid" is not a supported descriptor and
    # triggers the ps fallback, which cannot interpret the hpid argument.
    # hpid refers to the Podman host (this CT), matching /proc and ss here.
    rows = run(['podman', 'top', 'npm', 'hpid', 'comm']).splitlines()
    if not rows or rows[0].split() != ['HPID', 'COMMAND']:
        raise ValueError('Unexpected podman top process-table header.')
    processes = []
    for row in rows[1:]:
        if not row.strip():
            continue
        parts = row.split(maxsplit=1)
        if len(parts) != 2 or not re.fullmatch(r'[1-9][0-9]*', parts[0]):
            raise ValueError('Malformed podman top process row.')
        pid, name = parts
        if name not in ['node', 'nginx']:
            continue
        status = dict(line.split(':', 1) for line in
                      Path('/proc', pid, 'status').read_text().splitlines() if ':' in line)
        if status.get('Name', '').strip() != name:
            raise ValueError(f'NPM process identity changed while checking PID {pid}.')
        # proc status reports real, effective, saved and filesystem IDs.
        # Check numeric effective IDs; no name-service lookup or nested UID
        # mapping assumptions about the outer Proxmox host are involved.
        for field in ['Uid', 'Gid']:
            ids = status.get(field, '').split()
            if len(ids) != 4 or any(not value.isdecimal() for value in ids) or ids[1] != '0':
                raise ValueError(f'Unexpected NPM {name} effective {field} at CT PID {pid}.')
        processes.append((pid, name))
    if not {'node', 'nginx'} <= {name for _, name in processes}:
        raise ValueError('Expected Node and nginx processes are missing.')
    return processes

try:
    image = sys.argv[1]
    if os.geteuid() != 0 or not re.fullmatch(r'sha256:[a-f0-9]{64}', image):
        raise ValueError('Root and immutable image ID required.')
    info = json.loads(run(['podman', 'inspect', 'npm']))[0]
    if ('sha256:' + info['Image'].removeprefix('sha256:') != image
            or info.get('Name', '').lstrip('/') != 'npm'
            or not info['State']['Running'] or info['HostConfig']['NetworkMode'] != 'host'):
        raise ValueError('Container identity/image/network/state mismatch.')
    env = dict(item.split('=', 1) for item in info['Config'].get('Env', []) if '=' in item)
    if (env.get('PUID', '0') != '0' or env.get('PGID', '0') != '0'
            or env.get('DB_SQLITE_FILE', '/data/database.sqlite') != '/data/database.sqlite'
            or any(k.startswith(('DB_MYSQL_', 'DB_POSTGRES_', 'INITIAL_ADMIN_')) for k in env)):
        raise ValueError('Unexpected runtime identity, credentials or database mode.')
    expected = {'/data': ('/opt/npm/data', True),
                '/etc/letsencrypt': ('/opt/npm/letsencrypt', True),
                '/app/index.js': ('/opt/npm/runtime/' + image.removeprefix('sha256:') + '/index.js', False)}
    for destination, (source, writable) in expected.items():
        matches = [m for m in info['Mounts'] if m['Destination'] == destination]
        if len(matches) != 1 or matches[0]['Type'] != 'bind' or matches[0]['Source'] != source or matches[0]['RW'] != writable:
            raise ValueError('Unexpected persistent/startup mount: ' + destination)
    run(['/usr/local/sbin/npm-prepare-backend', '--check', image])
    processes = npm_processes()
    sockets = run(['ss', '-H', '-ltnp'])
    for port, process in [(80, 'nginx'), (81, 'nginx'), (443, 'nginx'), (3000, 'node')]:
        lines = [line for line in sockets.splitlines() if line.split()[3].rsplit(':', 1)[-1] == str(port)]
        if not lines or any(not any(re.search(r'pid=' + re.escape(pid) + r'[,)]', line)
                                   for pid, name in processes if name == process) for line in lines):
            raise ValueError(f'TCP {port} owner does not map to the NPM {process} process.')
    for name in ['data', 'letsencrypt', 'data/database.sqlite', 'data/keys.json']:
        path = Path('/opt/npm') / name
        stat = path.stat()
        if stat.st_uid != 0 or stat.st_gid != 0:
            raise ValueError('Unexpected persistent owner: ' + str(path))
    # SQLite has no DB password or separate application SQL role. The app's
    # inspected UID is CT root; read-only filesystem access is the real boundary.
    with sqlite3.connect('file:/opt/npm/data/database.sqlite?mode=ro', uri=True, timeout=5) as db:
        db.execute('PRAGMA query_only=ON')
        if db.execute('PRAGMA quick_check').fetchall() != [('ok',)]:
            raise ValueError('SQLite quick_check failed.')
        names = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if not {'migrations', 'user', 'auth', 'user_permission', 'proxy_host', 'setting'} <= names:
            raise ValueError('Expected migrated SQLite tables missing.')
        if db.execute('SELECT COUNT(*) FROM migrations').fetchone()[0] < 1:
            raise ValueError('No migration records found.')
        db.execute('SELECT id FROM user WHERE is_deleted=0 LIMIT 1').fetchall()
        if not db.execute("SELECT id FROM setting WHERE id='default-site'").fetchone():
            raise ValueError('NPM setup default-site setting missing.')
    print('NPM mounts, process/socket owners, persistent ownership and read-only SQLite checks passed.')
except Exception as exc:
    print('ERROR: NPM state verification: ' + str(exc), file=sys.stderr)
    raise SystemExit(1)
NPM_STATE_CHECK_PY
pct push "$CT_ID" "$tmp" /usr/local/sbin/npm-state-check --perms 0755
rm -f -- "$tmp"

pct exec "$CT_ID" -- /usr/local/sbin/npm-prepare-backend "$APP_IMAGE_ID"

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
After=network-online.target ufw.service
Wants=network-online.target
Requires=ufw.service

[Container]
# LabTag=${APP_TAG}
# LabImage=${APP_IMAGE}
Image=${APP_IMAGE_ID}
Pull=never
ContainerName=npm
Network=host
Environment=TZ=${APP_TZ}
${DISABLE_IPV6_LINE}
Volume=${APP_DIR}/data:/data
Volume=${APP_DIR}/letsencrypt:/etc/letsencrypt
Volume=${APP_DIR}/runtime/${APP_IMAGE_ID#sha256:}/index.js:/app/index.js:ro
StopTimeout=110
LogDriver=journald

[Service]
ExecStartPre=/usr/local/sbin/npm-ufw-check
ExecStartPre=/usr/local/sbin/npm-prepare-backend --check ${APP_IMAGE_ID}
Restart=always
RestartSec=5
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
APP_IMAGE_ID=${APP_IMAGE_ID}
APP_PORT=${APP_PORT}
APP_TZ=${APP_TZ}
NPM_DISABLE_IPV6=${NPM_DISABLE_IPV6}
AUTO_UPDATE=${AUTO_UPDATE}
PODMAN_FUSE_OVERLAY=${PODMAN_FUSE_OVERLAY}
INITIAL_WAIT_SECONDS=${INITIAL_WAIT_SECONDS}
UPDATE_WAIT_SECONDS=${UPDATE_WAIT_SECONDS}
UPDATE_TIME=${UPDATE_TIME}
INSTALL_CLOUDFLARED=${INSTALL_CLOUDFLARED}
CLOUDFLARED_METRICS_PORT=${CLOUDFLARED_METRICS_PORT}
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
APP_DIR=/opt/npm
ENV_FILE=$APP_DIR/.env
UNIT_DIR=/etc/containers/systemd
MAIN_SERVICE=npm.service
LOCK=/run/lock/npm-maint.lock
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
  (( STATE[APP_PORT] >= 81 && STATE[APP_PORT] <= 65535 )) || die "Invalid APP_PORT."
  (( STATE[INITIAL_WAIT_SECONDS] >= 30 && STATE[INITIAL_WAIT_SECONDS] <= 86400 )) || die "Invalid initial wait."
  (( STATE[UPDATE_WAIT_SECONDS] >= 30 && STATE[UPDATE_WAIT_SECONDS] <= 86400 )) || die "Invalid update wait."
  [[ ${STATE[AUTO_UPDATE]} =~ ^[01]$ && ${STATE[PODMAN_FUSE_OVERLAY]} =~ ^[01]$ ]] || die "Invalid policy flag."
  [[ ${STATE[NPM_DISABLE_IPV6]:-} =~ ^[01]$ ]] || die "Invalid NPM_DISABLE_IPV6."
  (( STATE[APP_PORT] == 81 )) || die "NPM admin port is fixed at 81."
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
    APP) CONTAINER=npm; KIND=app; IMAGE_RECOVERY=0 ;;
    *) die "Unknown component: $COMPONENT" ;;
  esac
  SERVICE=$CONTAINER.service
  UNIT=$UNIT_DIR/$CONTAINER.container
}
valid_tag() {
  case $1 in
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
      -e "s|^Image=.*|Image=$id|" \
      -e "s|^Volume=/opt/npm/runtime/.*|Volume=/opt/npm/runtime/${id#sha256:}/index.js:/app/index.js:ro|" \
      -e "s|^ExecStartPre=/usr/local/sbin/npm-prepare-backend .*|ExecStartPre=/usr/local/sbin/npm-prepare-backend --check $id|" "$UNIT" > "$temp" \
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
          if /usr/local/sbin/npm-health-check "${STATE[APP_PORT]}" >/dev/null 2>&1 \
            && /usr/local/sbin/npm-listener-check "${STATE[NPM_DISABLE_IPV6]}" >/dev/null 2>&1; then
            value=1
          fi
          ;;
        postgres)
          timeout 5 podman exec "$container" pg_isready -q -h 127.0.0.1 -U postgres -d postgres && value=1
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
  if [[ $kind == app ]]; then
    /usr/local/sbin/npm-listener-check "${STATE[NPM_DISABLE_IPV6]}" || true
  fi
  return 1
}
validate_candidate() {
  local id=$1 old_user new_user
  # Only the image shell runs, without network or data mounts. The candidate
  # application never gets production data during validation.
  podman run --rm --pull=never --network none --entrypoint /bin/sh "$id" -c true
  old_user=$(podman image inspect --format '{{.Config.User}}' "$OLD_ID")
  new_user=$(podman image inspect --format '{{.Config.User}}' "$id")
  [[ $old_user == "$new_user" ]] || die "Image USER changed; review ownership before updating."
  # Extract and validate the candidate before switching control files or starting it.
  # A changed startup source requires review, never a silent wildcard fallback.
  /usr/local/sbin/npm-prepare-backend "$id"
}
pre_update_checks() {
  /usr/local/sbin/npm-state-check "$OLD_ID" || die "NPM persistent state or startup adaptation failed verification."
  /usr/local/sbin/lab-hardening-check || die "Shared hardening failed before image update."
}
post_update_checks() {
  /usr/local/sbin/npm-ufw-check || die "Expected UFW rules failed verification after update."
  /usr/local/sbin/npm-state-check "$new_id" || die "NPM persistent state or startup adaptation failed after update."
  /usr/local/sbin/lab-hardening-check || die "Shared hardening failed after image update."
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
        systemctl start "$MAIN_SERVICE" && wait_service npm app "${STATE[UPDATE_WAIT_SECONDS]}" || restored=0
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
  local requested=${2:-} actual new_id target
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

  if [[ $COMPONENT == APP ]]; then
    [[ ${OLD_TAG%%.*} == "${target%%.*}" ]] || die "Application major changes require a separate migration review."
  fi
  /usr/local/sbin/npm-ufw-check || die "Restore active UFW filtering and expected source rules before maintenance."
  actual=$(podman inspect --format '{{.Image}}' "$CONTAINER") || die "Cannot inspect running image."
  [[ $(image_id "$actual") == "$OLD_ID" ]] || die "Running/configured image mismatch; inspect the service."
  wait_service "$CONTAINER" "$KIND" 30 || die "$SERVICE is unhealthy before update."
  if [[ $COMPONENT != APP ]]; then
    wait_service npm app 30 || die "Application is unhealthy before backend update."
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
  WORK=$(mktemp -d /run/npm-update.XXXXXX)
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
      wait_service npm app "${STATE[UPDATE_WAIT_SECONDS]}" || die "Application did not recover after backend update."
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

[[ $EUID == 0 ]] || die "Run as root inside the npm CT."
for command in podman systemctl curl awk sed sort head cat stat grep mktemp cp chmod mv rm flock timeout python3 ss; do
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
  update)
    (( $# <= 2 )) || die "Usage: $0 $cmd [tag] [--yes]"
    if (( YES == 0 )); then
      exec 8</dev/tty || die "Interactive terminal or --yes is required."
    fi
    case $cmd in
      update) update_component APP "${2:-}" ;;
    esac
    ;;
  auto-update)
    (( $# == 1 )) || die "auto-update takes no tag."
    [[ ${STATE[AUTO_UPDATE]} == 1 ]] || { printf '  Auto-update is disabled.\n'; exit 0; }
    YES=1
    # This one-component loop retains the existing maintenance flow.
    # shellcheck disable=SC2043
    for component in APP; do
      update_component "$component"
    done
    ;;
  check)
    (( $# <= 2 )) && [[ ${2:-} == "" || ${2:-} == --initial ]] || die "Usage: $0 check [--initial]"
    /usr/local/sbin/npm-ufw-check
    budget=${STATE[UPDATE_WAIT_SECONDS]}
    [[ ${2:-} != --initial ]] || budget=${STATE[INITIAL_WAIT_SECONDS]}
    # This one-component loop retains the existing maintenance flow.
    # shellcheck disable=SC2043
    for component in APP; do
      select_component "$component"
      load_unit
      if [[ ${2:-} == --initial ]]; then
        [[ $(systemctl show "$SERVICE" -p NRestarts --value) == 0 ]] || die "$SERVICE restarted during initial startup."
      fi
      wait_service "$CONTAINER" "$KIND" "$budget" || die "$SERVICE failed readiness or restarted."
      actual=$(podman inspect --format '{{.Image}}' "$CONTAINER")
      [[ $(image_id "$actual") == "$OLD_ID" ]] || die "Running/configured image mismatch: $SERVICE"
    done
    /usr/local/sbin/npm-state-check "$OLD_ID"
    /usr/local/sbin/npm-health-check "${STATE[APP_PORT]}"
    /usr/local/sbin/npm-ufw-check
    printf '  JSON API, loopback backend, proxy/admin listeners, mounts, SQLite, process identities, image IDs and UFW source rules passed.\n'
    ;;
  version)
    (( $# == 1 )) || die "version takes no argument."
    # This one-component loop retains the existing maintenance flow.
    # shellcheck disable=SC2043
    for component in APP; do
      select_component "$component"; load_unit
      printf '  %s\n    tag: %s\n    configured ID: %s\n    running ID: ' "$CONTAINER" "$OLD_TAG" "$OLD_ID"
      podman inspect --format '{{.Image}}' "$CONTAINER" || true
    done
    ;;
  --help|-h|'')
    printf 'Usage: %s update [tag] [--yes] | auto-update | check [--initial] | version\n' "$0"
    printf '  Exact image IDs; one component per operation; PBS/PVE handles data recovery.\n'
    printf '  Fresh-creator helper: do not replace an older deployed helper without migrating its control files.\n'
    ;;
  *) die "Unknown command: $cmd" ;;
esac
MAINT
pct push "$CT_ID" "$tmp" /usr/local/bin/npm-maint.sh --perms 0755
rm -f -- "$tmp"

STAGE="Quadlet validation"
# ── Start via Quadlet ─────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -s -- npm <<'QUADLET_VALIDATE'
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
pct exec "$CT_ID" -- /usr/local/sbin/npm-ufw-check
# Preserve the CT even if the first persistent start fails partway through.
CLEANUP_ON_FAIL=0
STAGE="NPM startup"
# Refuse conflicts before NPM starts; no attempt to kill or move another service.
pct exec "$CT_ID" -- bash -s <<'PORT_PREFLIGHT'
set -euo pipefail
ss -H -ltn | awk '$4 ~ /:(80|81|443|3000)$/ {bad=1; print "ERROR: NPM port already in use: " $4 > "/dev/stderr"} END {exit bad}'
PORT_PREFLIGHT
pct exec "$CT_ID" -- systemctl start npm.service

# Destructive cleanup was disarmed before the first persistent service start.

STAGE="early application verification"
# ── Verification ──────────────────────────────────────────────────────────────
sleep 30
if ! pct exec "$CT_ID" -- /usr/local/bin/npm-maint.sh check --initial; then
  echo "ERROR: Initial readiness/image/firewall verification failed; CT $CT_ID is preserved." >&2
  false
fi
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
for _ in $(seq 1 60); do
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
for _ in $(seq 1 90); do
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
  echo "  Preserve this CT for read-only diagnosis; use a corrected creator with a new CT ID and hostname." >&2
  false
fi

STAGE="optional cloudflared"
# ── Cloudflare Tunnel (optional) ──────────────────────────────────────────────
if [[ "$INSTALL_CLOUDFLARED" -eq 1 && -n "$TUNNEL_TOKEN" ]]; then
  echo "  Installing Cloudflare Tunnel ..."

  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
    apt-get install -y curl gnupg ca-certificates

    install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg \
      -o /usr/share/keyrings/cloudflare-public-v2.gpg

    echo "deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main" \
      > /etc/apt/sources.list.d/cloudflared.list

    apt-get update -qq
    apt-get install -y cloudflared
    cloudflared --version
  '

  # Check supported flags on the installed artifact before handling credentials.
  pct exec "$CT_ID" -- bash -s -- "$CLOUDFLARED_METRICS_PORT" <<'CLOUDFLARED_UNIT'
set -euo pipefail
help=$(cloudflared tunnel run --help)
grep -q -- '--token-file' <<< "$help"
help=$(cloudflared tunnel --help)
grep -q -- '--protocol' <<< "$help"
grep -q -- '--metrics' <<< "$help"
ss -H -ltn | awk -v port="$1" '$4 ~ (":" port "$") {bad=1} END {exit bad}'
install -d -m 0700 /etc/cloudflared
cat > /etc/systemd/system/cloudflared.service <<EOF2
[Unit]
Description=Cloudflare published-application tunnel for NPM
After=network-online.target ufw.service
Wants=network-online.target
Requires=ufw.service
[Service]
Type=notify
ExecStartPre=/usr/local/sbin/npm-ufw-check
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel --protocol http2 --metrics 127.0.0.1:$1 run --token-file /etc/cloudflared/token
Restart=on-failure
RestartSec=5
TimeoutStartSec=180
TimeoutStopSec=90
[Install]
WantedBy=multi-user.target
EOF2
chmod 0644 /etc/systemd/system/cloudflared.service
CLOUDFLARED_UNIT
  # Root-only token file; the value is not in host or guest process argv/unit text.
  printf '%s\n' "$TUNNEL_TOKEN" | pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    umask 077
    cat > /etc/cloudflared/token
    chmod 0600 /etc/cloudflared/token
  '
  unset TUNNEL_TOKEN
  pct exec "$CT_ID" -- bash -s -- "$CLOUDFLARED_METRICS_PORT" "$INITIAL_WAIT_SECONDS" <<'CLOUDFLARED_START'
set -euo pipefail
systemctl daemon-reload
systemctl enable --now cloudflared.service
start=$SECONDS
ready=0
while (( SECONDS - start < $2 )); do
  if systemctl is-active --quiet cloudflared.service \
      && curl --noproxy '*' -fsS --max-time 3 -o /dev/null "http://127.0.0.1:$1/ready"; then
    ready=1
    break
  fi
  sleep 2
done
[[ $ready == 1 ]] || { echo 'ERROR: cloudflared did not connect; inspect journalctl -u cloudflared. CT preserved.' >&2; false; }
echo '  cloudflared connected: HTTP/2 transport, loopback metrics, root-only token file.'
CLOUDFLARED_START

  pct set "$CT_ID" --tags "${TAGS};cloudflared"
fi

# ── Auto-update timer (policy-driven) ─────────────────────────────────────────
pct exec "$CT_ID" -- bash -s -- "$UPDATE_TIME" <<'TIMER_INSTALL'
set -euo pipefail
cat > /etc/systemd/system/npm-update.service <<EOF2
[Unit]
Description=npm image maintenance
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/npm-maint.sh auto-update
TimeoutStartSec=infinity
TimeoutStopSec=180
EOF2
cat > /etc/systemd/system/npm-update.timer <<EOF2
[Unit]
Description=npm daily image maintenance
[Timer]
OnCalendar=*-*-* $1:00
Persistent=true
[Install]
WantedBy=timers.target
EOF2
systemctl daemon-reload
TIMER_INSTALL
if [[ $AUTO_UPDATE == 1 ]]; then
  pct exec "$CT_ID" -- systemctl enable --now npm-update.timer
else
  pct exec "$CT_ID" -- systemctl disable --now npm-update.timer
fi

# ── Extra packages ────────────────────────────────────────────────────────────
if [[ "${#EXTRA_PACKAGES[@]}" -gt 0 ]]; then
  pct exec "$CT_ID" -- bash -lc "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
    apt-get install -y ${EXTRA_PACKAGES[*]}
  "
fi

STAGE="package cleanup and MOTD"
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
  : > /etc/motd
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
printf '  Maintain:  /usr/local/bin/npm-maint.sh [check|update|auto-update|version]\\n'
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
  pct exec "$CT_ID" -- bash -lc 'set -euo pipefail; cat > /etc/update-motd.d/35-cloudflared; chmod +x /etc/update-motd.d/35-cloudflared' <<'MOTD'
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

# ── Shared hardening integration boundary ─────────────────────────────────────
STAGE="hardening prerequisites and firewall checkpoint"
CLEANUP_ON_FAIL=0
# Already verified Proxmox-only above; keep the standalone guest SSH guard intact.
unset SSH_CONNECTION
pct exec "$CT_ID" -- /usr/local/sbin/npm-ufw-check
pct exec "$CT_ID" -- bash -s <<'UFW_BEFORE_HARDENING'
set -euo pipefail
sha256sum /etc/ufw/{before,after,user}.rules /etc/ufw/{before6,after6,user6}.rules > /opt/npm/ufw-before-hardening.sha256
iptables -w 5 -S > /opt/npm/ufw-before-hardening.iptables
ip6tables -w 5 -S > /opt/npm/ufw-before-hardening.ip6tables
UFW_BEFORE_HARDENING
# Record exact arguments as JSON, including custom/empty lists; never source it.
pct exec "$CT_ID" -- python3 - \
  "$HARDENING_PROFILE" "$HARDENING_RP_FILTER" "$HARDENING_KEEP_SSH" \
  "$HARDENING_REMOVE_POSTFIX" "$HARDENING_JOURNAL_DAYS" "$HARDENING_JOURNAL_MAX_MB" \
  "$HARDENING_JOURNAL_RUNTIME_MB" "$HARDENING_UPDATE_MAX_AGE_HOURS" \
  "$HARDENING_TCP_PORTS" "$HARDENING_UDP_PORTS" <<'NPM_HARDENING_SETTINGS'
import json, pathlib, sys
keys = ['PROFILE', 'RP_FILTER', 'KEEP_SSH', 'REMOVE_POSTFIX', 'JOURNAL_DAYS',
        'JOURNAL_MAX_MB', 'JOURNAL_RUNTIME_MB', 'UPDATE_MAX_AGE_HOURS', 'TCP_PORTS', 'UDP_PORTS']
target = pathlib.Path('/opt/npm/hardening-settings.json')
target.write_text(json.dumps(dict(zip(('HARDENING_' + k for k in keys), sys.argv[1:])), indent=2) + '\n')
target.chmod(0o600)
NPM_HARDENING_SETTINGS
STAGE="shared hardening v1.1.2"
# BEGIN SHARED STANDALONE HARDENING — identical to the standalone v1.1.2 deliverable
#!/usr/bin/env bash
# ── Shared Debian 13 LXC hardening block ───────────────────────────────────────
# Version: 1.1.2 (2026-09-13; Postfix shutdown/runtime verification; retains IPv6 fix)
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
#   /usr/local/sbin/lab-{apt-wait-online,hardening-check,postfix-check}
#   /etc/update-motd.d/25-lab-hardening
#   /etc/default/ufw (IPT_SYSCTL only); SSH service/socket masks (when SSH removed)
#   /etc/systemd/system/postfix*.{service,socket,path} masks (when Postfix removed)
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
for command in ufw iptables ip6tables ip ss sysctl python3 systemctl apt-get flock timeout; do
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

# ── Postfix inventory and runtime verification (read-only) ────────────────────
cat > "$stage/usr/local/sbin/lab-postfix-check" <<'POSTFIX_CHECK_HELPER'
#!/usr/bin/python3
"""Read-only Postfix inventory and removal checks for the native Debian service."""
import os
from pathlib import Path
import re
import subprocess
import sys

os.environ['LC_ALL'] = 'C'
os.environ['PATH'] = '/usr/sbin:/usr/bin:/sbin:/bin'
STANDARD_UNITS = {
    'postfix.service', 'postfix@.service',
    'postfix.socket', 'postfix@.socket',
    'postfix-resolvconf.service', 'postfix-resolvconf.path',
}
INSTANCE = re.compile(r'postfix@[^/\s]+\.(?:service|socket)')
TEMPLATES = {'postfix@.service', 'postfix@.socket'}
# Debian's packaged daemon names are only an ambiguity guard when procfs denies
# executable inspection, never sufficient identity for stopping/killing a PID.
DAEMON_NAMES = {'master', 'anvil', 'bounce', 'cleanup', 'discard', 'dnsblog', 'error',
                'flush', 'fsstone', 'lmtp', 'local', 'nqmgr', 'oqmgr', 'pickup', 'pipe',
                'postlogd', 'postscreen', 'proxymap', 'qmgr', 'qmqpd', 'scache', 'showq',
                'smtp', 'smtpd', 'spawn', 'tlsmgr', 'tlsproxy', 'trivial-rewrite',
                'verify', 'virtual', 'postfix', 'postmulti', 'postdrop', 'postqueue'}

def is_postfix_unit(name):
    return name in STANDARD_UNITS or INSTANCE.fullmatch(name) is not None

def command(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError(f'{" ".join(args)} exited {result.returncode}: '
                           + (result.stderr.strip()[:1500] or '(no stderr)'))
    return result.stdout

try:
    if os.geteuid() != 0:
        raise ValueError('Root is required to inspect process ownership.')
    if len(sys.argv) != 2 or sys.argv[1] not in {
            '--units', '--stop-units', '--check-stopped', '--check-removed'}:
        raise ValueError('Use --units, --stop-units, --check-stopped or --check-removed.')
    mode = sys.argv[1]
    runtime = {}
    # Include not-found/masked units that systemd still has in memory. Never
    # equate LoadState=not-found or package absence with a stopped service.
    output = command(['systemctl', 'list-units', '--all', '--plain', '--full',
                      '--no-legend', '--no-pager', 'postfix*'])
    for line in output.splitlines():
        fields = line.split()
        if not fields:
            continue
        if len(fields) < 4:
            raise ValueError('Malformed systemd unit inventory.')
        unit, load, active, sub = fields[:4]
        if is_postfix_unit(unit):
            runtime[unit] = (load, active, sub)
    units = set(STANDARD_UNITS) | runtime.keys()
    if mode in {'--units', '--check-removed'}:
        output = command(['systemctl', 'list-unit-files', '--full', '--no-legend',
                          '--no-pager', 'postfix*'])
        for line in output.splitlines():
            fields = line.split()
            if fields and is_postfix_unit(fields[0]):
                units.add(fields[0])
    if mode == '--units':
        print('\n'.join(sorted(units)))
        raise SystemExit(0)
    if mode == '--stop-units':
        # Only instantiated runtime units need stopping. Templates cannot run;
        # absent/inactive units would make systemctl stop fail needlessly.
        pending = [unit for unit, (_, active, _) in runtime.items()
                   if unit not in TEMPLATES and active != 'inactive']
        print('\n'.join(sorted(pending, key=lambda u: (u.endswith('.service'), u))))
        raise SystemExit(0)

    errors = []
    for unit, (load, active, sub) in sorted(runtime.items()):
        if active != 'inactive':
            errors.append(f'{unit}: LoadState={load}, ActiveState={active}, SubState={sub}')
    # Executable paths catch detached daemons and deleted executables. Cgroup
    # membership catches remaining workers even if the unit file has vanished.
    # Do not match a bare process name such as "master" and never signal a PID.
    for process in Path('/proc').iterdir():
        if not process.name.isdecimal():
            continue
        try:
            groups = process.joinpath('cgroup').read_text()
            try:
                executable = os.readlink(process / 'exe').removesuffix(' (deleted)')
            except FileNotFoundError:
                executable = ''  # exited process, kernel thread or zombie
            except PermissionError:
                executable = ''
                # LXC root need not have ptrace access to every unrelated
                # process. Keep cgroup detection and fail on ambiguous daemon
                # names instead of requiring extra CT capabilities.
                name = process.joinpath('comm').read_text().strip()
                if name in DAEMON_NAMES:
                    errors.append(f'Cannot exclude a Postfix process: PID={process.name}, '
                                  f'comm={name}; executable inspection denied')
            group_owned = any(is_postfix_unit(component)
                              for line in groups.splitlines()
                              for component in line.split(':', 2)[-1].split('/'))
            exe_owned = (executable.startswith(('/usr/lib/postfix/', '/usr/libexec/postfix/'))
                         or executable in {'/usr/sbin/postfix', '/usr/sbin/postmulti',
                                           '/usr/sbin/postdrop', '/usr/sbin/postqueue'})
            if group_owned or exe_owned:
                errors.append(f'Postfix process remains: PID={process.name}, '
                              f'executable={executable or "unavailable"}')
        except FileNotFoundError:
            continue  # process exited during the read-only scan
        except OSError as exc:
            errors.append(f'Cannot inspect PID {process.name}: {exc.strerror}')
    if mode == '--check-removed':
        package = subprocess.run(['dpkg-query', '-W', '-f=${db:Status-Status}', 'postfix'],
                                 capture_output=True, text=True, timeout=30)
        absent = (package.returncode == 0 and package.stdout.strip() == 'not-installed')
        absent = absent or (package.returncode == 1 and not package.stdout.strip()
                            and package.stderr.strip() == 'dpkg-query: no packages found matching postfix')
        if not absent:
            errors.append('Postfix package is not confirmed purged: '
                          + (package.stdout.strip() or package.stderr.strip()[:500] or 'unknown status'))
        for unit in sorted(units):
            # is-enabled returns nonzero for masked units; validate its text
            # and reject runtime-only masks, which would disappear at boot.
            result = subprocess.run(['systemctl', 'is-enabled', unit],
                                    capture_output=True, text=True, timeout=30)
            if result.returncode not in (0, 1) or result.stdout.strip() != 'masked':
                errors.append(f'Persistent Postfix mask missing: {unit}')
    if errors:
        for error in errors:
            print('ERROR: ' + error, file=sys.stderr)
        raise SystemExit(1)
    print('Postfix units and processes stopped.' if mode == '--check-stopped' else
          'Postfix package purged; units masked; no remaining Postfix processes.')
except Exception as exc:
    print('ERROR: Postfix verification: ' + str(exc), file=sys.stderr)
    raise SystemExit(1)
POSTFIX_CHECK_HELPER

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

    if policy['remove_postfix']:
        # Keep the detailed diagnostic in the hardening report. This helper is
        # read-only and checks runtime units/processes even after package purge.
        postfix = subprocess.run(['/usr/local/sbin/lab-postfix-check', '--check-removed'],
                                 capture_output=True, text=True, timeout=90)
        require(postfix.returncode == 0,
                'Postfix removal incomplete: ' + (postfix.stderr.strip()[:4000] or 'verification failed'))

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
if [[ $REMOVE_POSTFIX == 1 ]]; then
  # Scope operations to known Debian Postfix units and actual instances only.
  # Read inventory before masking/purging; a not-found unit can still be active.
  postfix_unit_text=$(/usr/local/sbin/lab-postfix-check --units)
  mapfile -t postfix_units <<< "$postfix_unit_text"
  postfix_stop_text=$(/usr/local/sbin/lab-postfix-check --stop-units)
  if [[ -n $postfix_stop_text ]]; then
    mapfile -t postfix_stop_units <<< "$postfix_stop_text"
    echo 'Stopping Postfix units before package removal...'
    timeout 60 systemctl stop "${postfix_stop_units[@]}"
  fi
  # Mask without --force: never overwrite a local custom unit. No blanket
  # process-name kills. If stopping or masking fails, preserve the CT and fail.
  systemctl mask "${postfix_units[@]}"
  /usr/local/sbin/lab-postfix-check --check-stopped
fi
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
  package_status=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)
  if [[ $package_status == installed ]] ||
     [[ $package == postfix && -n $package_status && $package_status != not-installed ]]; then
    # Include Postfix config-files/partial states, not just fully installed.
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
if [[ $REMOVE_POSTFIX == 1 ]]; then
  # Package maintainer scripts can remove a mask; restore our explicit policy.
  systemctl mask "${postfix_units[@]}"
  /usr/local/sbin/lab-postfix-check --check-removed
fi
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
# END SHARED STANDALONE HARDENING

# ── Final application and firewall verification ───────────────────────────────
STAGE="final verification"
pct exec "$CT_ID" -- bash -s -- "$INSTALL_CLOUDFLARED" "$CLOUDFLARED_METRICS_PORT" <<'FINAL_VERIFY'
set -euo pipefail
export LC_ALL=C
sha256sum --check /opt/npm/ufw-before-hardening.sha256
current=$(mktemp)
trap 'rm -f -- "$current"' EXIT
iptables -w 5 -S > "$current"
cmp /opt/npm/ufw-before-hardening.iptables "$current"
ip6tables -w 5 -S > "$current"
cmp /opt/npm/ufw-before-hardening.ip6tables "$current"
/usr/local/sbin/npm-ufw-check
/usr/local/bin/npm-maint.sh check --initial
# WARN is a successful, report-only result; FAIL prevents success reporting.
/usr/local/sbin/lab-hardening-check
test -x /etc/update-motd.d/25-lab-hardening
test -L /run/systemd/generator/multi-user.target.wants/npm.service
if [[ $1 == 1 ]]; then
  systemctl is-active --quiet cloudflared.service
  curl --noproxy '*' -fsS --max-time 5 -o /dev/null "http://127.0.0.1:$2/ready"
fi
echo '  Final application health, boot dependency, hardening, persistent and effective UFW preservation passed.'
FINAL_VERIFY
STAGE="success reporting"

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


cat <<OPERATIONS

  NPM — OPERATIONS

  CONTAINER     $HN | CT $CT_ID | $CT_IP
  ADMIN         http://$CT_IP:$APP_PORT/
  ADMIN SOURCES $FIREWALL_ACCESS_LABEL
  FIREWALL      UFW inside the CT, IPv4 and IPv6; no PVE firewall dependency
  PROXY SOURCES TCP 80/443: $NPM_PUBLIC_ACCESS_LABEL
  SOURCE POLICY /etc/ufw/npm-expected-sources.conf
  AUTO-UPDATE   $AUTO_UPDATE | daily $UPDATE_TIME ($APP_TZ)
  IMAGES        exact local IDs, Pull=never; old images retained for review

  RUN ON THE PROXMOX HOST
    pct enter $CT_ID
    pct exec $CT_ID -- /usr/local/bin/npm-maint.sh version
    pct exec $CT_ID -- /usr/local/sbin/lab-hardening-check

  RUN INSIDE THE CT
    /usr/local/bin/npm-maint.sh check
    /usr/local/bin/npm-maint.sh update $APP_TAG
    ufw status verbose
    journalctl -u npm.service --no-pager -n 80

  HARDENING     v1.1.2; non-routing LXC; TCP [$HARDENING_TCP_PORTS], UDP [$HARDENING_UDP_PORTS]
                /usr/local/sbin/lab-hardening-check (WARN may mean reviewed restarts)
  STREAMS       Additional TCP/UDP streams need explicit listener policy AND
                separate source-specific UFW rules; NPM UI changes neither policy.
                Internal Node API 127.0.0.1:3000 must remain private.
  CERTIFICATES  Direct HTTP-01 needs public validation access on port 80.
                For private-only services, use DNS-01 with scoped DNS credentials.
  NETWORK       Reserve the CT DHCP address; allow its IP at backend UFW rules.
                Backend hostnames must resolve from this CT. No IP forwarding needed.

  ACCESS CHECK
    Test proxy ports 80/443 from your intended LAN/VPN client or tunnel connector.
    Test admin TCP $APP_PORT from your administrator device.
    If you restricted sources, also test each port group from outside its list.
    These checks do not audit all additional rules or prove the full network path.
    Add/delete UFW rules directly; do not restart ufw.service while apps run.
    When changing these source choices, update /etc/ufw/npm-expected-sources.conf
    to match (one TCP port and source per line), then run:
      /usr/local/bin/npm-maint.sh check
    Editing that policy file alone does not change UFW access.

  RECOVERY
    Verify a matching PBS/PVE checkpoint before updates; --yes only skips prompts.
    If FUSE is enabled, use stop-mode PBS. Back up external bind mounts separately.
    For persistent components, failed updates retain the target after it may start.
    The helper changes one component at a time; earlier successes remain applied.
    Creators build new CTs. Existing CTs require a reviewed control-file migration.

OPERATIONS

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "    CT: $CT_ID | IP: ${CT_IP} | Admin: http://${CT_IP}:${APP_PORT}/"
echo "    Image:   ${APP_IMAGE}"
echo "    ID:      ${APP_IMAGE_ID}"
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
echo "    Complete setup promptly from an allowed administrator device."
echo "    Proxy hosts (from another CT): http | <ct-ip>:<port> | enable Websockets Support where needed"
echo "    Ports 80, 443 and ${APP_PORT} use Network=host; admin and proxy sources are controlled separately by UFW."
echo "    2.15.x note: Debian Trixie base + new Certbot — verify DNS-challenge cert renewals after upgrading from 2.14."
if [[ "$PODMAN_FUSE_OVERLAY" -eq 1 ]]; then
  echo "    Backups: fuse=1 + fuse-overlayfs can deadlock under snapshot-mode vzdump/PBS (freezer)."
  echo "             Use stop-mode backups for this CT, or test PODMAN_FUSE_OVERLAY=0 (on a less critical CT first)."
fi
echo ""
