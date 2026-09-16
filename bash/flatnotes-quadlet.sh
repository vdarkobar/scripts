#!/usr/bin/env bash
set -Eeo pipefail
umask 022
export LC_ALL=C
# Baseline revision: 2026-09-16; contract 1.0.0 / hardening 1.2.0. Fresh Proxmox CT creator; maintenance runs inside the CT.

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID=""                             # empty = auto-assign via pvesh; set e.g. CT_ID=120 to pin
HN="flatnotes"
CPU=2
RAM=1024
DISK=8
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Flatnotes / Podman + Quadlet
APP_PORT=8080
APP_FQDN=""                          # e.g. notes.example.com ; blank = local IP mode
FLATNOTES_AUTH_TYPE="password"       # password | none | read_only | totp
FLATNOTES_SESSION_EXPIRY_DAYS=1      # days before login token expires (upstream default 30)
FLATNOTES_PATH_PREFIX=""             # sub-path e.g. /flatnotes ; blank = root
TAGS="flatnotes;podman;quadlet;lxc"

# Images / versions
APP_IMAGE_REPO="docker.io/dullage/flatnotes"
APP_TAG="v5.5.5"                     # pinned default; do not default to :latest
DEBIAN_VERSION=13

# COMMON TIMEZONE INPUTS
SERVER_TIMEZONE="${SERVER_TIMEZONE-Europe/Berlin}"
PRESERVE_EXISTING_TIMEZONE="${PRESERVE_EXISTING_TIMEZONE-0}"
APP_TZ=""
# END COMMON TIMEZONE INPUTS

# Auto-update policy
# AUTO_UPDATE=0 (default): timer installed but disabled; manual updates via
#   flatnotes-maint.sh update <tag>
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
PODMAN_FUSE_OVERLAY=1

# Extra packages to install (space-separated or array)
EXTRA_PACKAGES=(
)

# Behavior
CLEANUP_ON_FAIL="${CLEANUP_ON_FAIL-0}"


# Service verification and in-CT firewall
INITIAL_WAIT_SECONDS=180
UPDATE_WAIT_SECONDS=1800             # permit migrations; a timeout does not stop the app
# Bare IPs (192.168.1.20) or network CIDRs (192.168.1.0/24).
# Empty array prompts before CT creation; pressing Enter allows any source
# on APP_PORT (IPv4/IPv6). UFW stays enabled. Set client/NPM sources to restrict.
UFW_ALLOWED_SOURCES=()
UPDATE_TIME="03:00"                  # daily at CT local time
SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/flatnotes-quadlet.sh"
SCRIPT_LOCAL="/root/flatnotes-quadlet.sh"

# Shared Debian 13 LXC hardening (v1.2.0)
HARDENING_PROFILE="${HARDENING_PROFILE-lxc}"              # Debian 13 service LXC; no routing/forwarding
HARDENING_RP_FILTER="${HARDENING_RP_FILTER-1}"                # strict; 2=loose for reviewed asymmetric paths
HARDENING_KEEP_SSH="${HARDENING_KEEP_SSH-0}"                 # 0=remove SSH; 1=preserve, without adding UFW access
HARDENING_REMOVE_POSTFIX="${HARDENING_REMOVE_POSTFIX-1}"           # 1=remove Postfix; 0=preserve intentional mail service
HARDENING_JOURNAL_DAYS="${HARDENING_JOURNAL_DAYS-14}"
HARDENING_JOURNAL_MAX_MB="${HARDENING_JOURNAL_MAX_MB-256}"
HARDENING_JOURNAL_RUNTIME_MB="${HARDENING_JOURNAL_RUNTIME_MB-64}"
HARDENING_UPDATE_MAX_AGE_HOURS="${HARDENING_UPDATE_MAX_AGE_HOURS-72}"
# External listener checks only: these do not add UFW rules or prove app health.
# TCP auto resolves to the finalized APP_PORT. Explicit lists are complete;
# empty is inventory-only. These settings never grant firewall access.
HARDENING_TCP_PORTS="${HARDENING_TCP_PORTS-auto}"
HARDENING_UDP_PORTS="${HARDENING_UDP_PORTS-68 546}"  # DHCP clients; inventory only
# The template DHCP client may bind UDP 546 even with Proxmox ip6=manual.
# Preserving SSH/Postfix does not install them or grant firewall access.

# Derived
APP_DIR="/opt/flatnotes"
APP_IMAGE="${APP_IMAGE_REPO}:${APP_TAG}"
APP_ENV_FILE="${APP_DIR}/flatnotes.env"
APP_WEB_PATH="${FLATNOTES_PATH_PREFIX}/"
QUADLET_FILE="/etc/containers/systemd/flatnotes.container"
QUADLET_SERVICE="flatnotes.service"

# ── Custom configs created by this script ─────────────────────────────────────
#   /usr/local/sbin/flatnotes-ufw-check                  (service-start firewall guard)
#   /etc/default/ufw, /etc/ufw/ufw.conf               (in-CT IPv4/IPv6 policy)
#   /etc/ufw/user.rules, /etc/ufw/user6.rules         (configured source allows)
#   /etc/containers/systemd/flatnotes.container  (Quadlet unit — source of truth)
#   /opt/flatnotes/flatnotes.env                 (container credentials — read by Quadlet, 0600)
#   /opt/flatnotes/.env                          (runtime state — read by maint script)
#   /opt/flatnotes/data/                         (notes, attachments, .flatnotes search index)
#   /usr/local/bin/flatnotes-maint.sh            (maintenance helper)
#   /etc/systemd/system/flatnotes-update.service
#   /etc/systemd/system/flatnotes-update.timer
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/sysctl.d/99-hardening.conf
#   /etc/apt/apt.conf.d/99-lab-hardening
#   /etc/needrestart/conf.d/99-lab-hardening.conf
#   /etc/systemd/journald.conf.d/99-lab-hardening.conf
#   /etc/systemd/system/apt-daily{,-upgrade}.service.d/90-lab-readiness.conf
#   /etc/systemd/system/lab-hardening-check.{service,timer}
#   /usr/local/sbin/lab-{apt-wait-online,hardening-check}
#   /etc/update-motd.d/25-lab-hardening
#   /etc/systemd/system/ssh.{service,socket}      (masks when SSH is removed)
#   /var/lib/lab-hardening/{policy.json,status.json,last-index-refresh,check.lock}
#   /var/backups/lab-hardening/<run>/            (configuration backups and dry-run log)

#   /usr/local/sbin/flatnotes-check                 (complete observational app verifier)
#   /opt/flatnotes/access.json                      (source policy and six UFW file hashes)
#   /opt/flatnotes/timezone-plan.json                (retained non-secret initial plan)
#   /usr/local/sbin/lab-timezone, /usr/local/sbin/lab-postfix-check
#   /etc/localtime, existing /etc/timezone           (canonical timezone policy only)
#   /etc/containers/{storage,containers}.conf
#   /etc/locale.gen, /etc/default/locale, /root/.bashrc, /etc/motd
#   /run/lock/flatnotes-{creator,maint}.lock          (host / guest respectively)
#   /run/flatnotes-update.*/                        (temporary/retained control copies)
#   /etc/systemd/system/postfix*                    (scoped masks from common block)

# COMMON CREATOR TRAPS
INSTALL_STAGE="configuration"
CREATED=0
trap 'rc=$? err_line=$LINENO;
  trap - ERR INT TERM HUP
  if (( BASH_SUBSHELL > 0 )); then exit "$rc"; fi
  printf "  ERROR: stage=%s rc=%s line=%s\n" "$INSTALL_STAGE" "$rc" "$err_line" >&2
  printf "  Command text and arguments are omitted. External data is never removed by cleanup.\n" >&2
  if [[ $rc != 129 && $rc != 130 && $rc != 143 && ${CLEANUP_ON_FAIL:-0} == 1 && ${CREATED:-0} == 1 ]]; then
    if pct stop "$CT_ID" >/dev/null 2>&1; then
      pct destroy "$CT_ID" >/dev/null 2>&1 || printf "  CT cleanup failed; inspect the preserved state.\n" >&2
    else
      printf "  CT stop failed; no destruction attempted.\n" >&2
    fi
  else
    printf "  CT state is preserved for inspection.\n" >&2
  fi
  exit "$rc"
' ERR
trap 'rc=130; err_line=$LINENO;
  trap - ERR INT TERM HUP
  if (( BASH_SUBSHELL > 0 )); then exit "$rc"; fi
  printf "  Interrupted: stage=%s rc=%s line=%s\n" "$INSTALL_STAGE" "$rc" "$err_line" >&2
  printf "  CT and external data are preserved for inspection.\n" >&2
  exit "$rc"
' INT
trap 'rc=143; err_line=$LINENO;
  trap - ERR INT TERM HUP
  if (( BASH_SUBSHELL > 0 )); then exit "$rc"; fi
  printf "  Interrupted: stage=%s rc=%s line=%s\n" "$INSTALL_STAGE" "$rc" "$err_line" >&2
  printf "  CT and external data are preserved for inspection.\n" >&2
  exit "$rc"
' TERM
trap 'rc=129; err_line=$LINENO;
  trap - ERR INT TERM HUP
  if (( BASH_SUBSHELL > 0 )); then exit "$rc"; fi
  printf "  Interrupted: stage=%s rc=%s line=%s\n" "$INSTALL_STAGE" "$rc" "$err_line" >&2
  printf "  CT and external data are preserved for inspection.\n" >&2
  exit "$rc"
' HUP
# END COMMON CREATOR TRAPS

# ── Config validation ─────────────────────────────────────────────────────────
[[ "$HN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || { echo "  ERROR: HN is not a valid hostname: $HN" >&2; exit 1; }
[[ "$CPU" =~ ^(0|[1-9][0-9]*)$ ]] && (( CPU >= 1 )) || { echo "  ERROR: CPU must be a positive integer." >&2; exit 1; }
[[ "$RAM" =~ ^(0|[1-9][0-9]*)$ ]] && (( RAM >= 256 )) || { echo "  ERROR: RAM must be >= 256 MB." >&2; exit 1; }
[[ "$DISK" =~ ^(0|[1-9][0-9]*)$ ]] && (( DISK >= 1 )) || { echo "  ERROR: DISK must be >= 1 GB." >&2; exit 1; }
[[ "$DEBIAN_VERSION" == 13 ]] || { echo "  ERROR: This creator requires Debian 13." >&2; exit 1; }
[[ "$APP_PORT" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "  ERROR: APP_PORT must be numeric." >&2; exit 1; }
(( APP_PORT >= 1024 && APP_PORT <= 65535 )) || { echo "  ERROR: APP_PORT must be between 1024 and 65535." >&2; exit 1; }
[[ "$AUTO_UPDATE" =~ ^[01]$ ]] || { echo "  ERROR: AUTO_UPDATE must be 0 or 1." >&2; exit 1; }
[[ "$PODMAN_FUSE_OVERLAY" =~ ^[01]$ ]] || { echo "  ERROR: PODMAN_FUSE_OVERLAY must be 0 or 1." >&2; exit 1; }
[[ "$CLEANUP_ON_FAIL" =~ ^[01]$ ]] || { echo "  ERROR: CLEANUP_ON_FAIL must be 0 or 1." >&2; exit 1; }
# APP_IMAGE_REPO is interpolated into podman, sed, the Quadlet unit and .env.
[[ "$APP_IMAGE_REPO" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*[A-Za-z0-9]$ ]] || {
  echo "  ERROR: APP_IMAGE_REPO must look like registry/namespace/name (no tag, no spaces)." >&2
  exit 1
}
# Flatnotes publishes v-prefixed semver tags (v5.5.4). Floating tags like v5 or
# v5.5 are mutable and are rejected for the same reason :latest is.
[[ "$APP_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: APP_TAG must be a pinned version like v5.5.4 — ':latest' and floating tags are not permitted." >&2
  exit 1
}
# COMMON TIMEZONE VALIDATION
[[ $PRESERVE_EXISTING_TIMEZONE =~ ^[01]$ ]] || {
  echo 'ERROR: PRESERVE_EXISTING_TIMEZONE must be exactly 0 or 1.' >&2
  exit 1
}
TIMEZONE_ACTION=preserved
TIMEZONE_LABEL='preserve existing guest timezone'
if [[ $PRESERVE_EXISTING_TIMEZONE == 0 ]]; then
  [[ $SERVER_TIMEZONE =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || {
    echo 'ERROR: SERVER_TIMEZONE must be a nonempty IANA timezone name.' >&2
    exit 1
  }
  TIMEZONE_ACTION=set
  TIMEZONE_LABEL=$SERVER_TIMEZONE
fi
# END COMMON TIMEZONE VALIDATION

if [[ -n "$APP_FQDN" ]]; then
  [[ "$APP_FQDN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]] \
    || { echo "  ERROR: APP_FQDN is not a valid hostname: $APP_FQDN" >&2; exit 1; }
fi
[[ "$FLATNOTES_AUTH_TYPE" =~ ^(password|none|read_only|totp)$ ]] || {
  echo "  ERROR: FLATNOTES_AUTH_TYPE must be password, none, read_only, or totp." >&2; exit 1;
}
[[ "$FLATNOTES_SESSION_EXPIRY_DAYS" =~ ^(0|[1-9][0-9]*)$ ]] && (( FLATNOTES_SESSION_EXPIRY_DAYS >= 1 && FLATNOTES_SESSION_EXPIRY_DAYS <= 999999 )) \
  || { echo "  ERROR: FLATNOTES_SESSION_EXPIRY_DAYS must be an integer >= 1 (0 would expire tokens immediately)." >&2; exit 1; }
[[ -z "$FLATNOTES_PATH_PREFIX" || "$FLATNOTES_PATH_PREFIX" =~ ^(/[A-Za-z0-9._~-]+)+$ ]] || {
  echo "  ERROR: FLATNOTES_PATH_PREFIX must be empty or start with / and have no trailing slash (e.g. /flatnotes)." >&2; exit 1;
}
[[ "$TAGS" =~ ^[A-Za-z0-9._-]+(;[A-Za-z0-9._-]+)*$ ]] || { echo "  ERROR: TAGS must be a semicolon-separated list without spaces." >&2; exit 1; }
for pkg in "${EXTRA_PACKAGES[@]}"; do
  [[ "$pkg" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || { echo "  ERROR: Invalid package name in EXTRA_PACKAGES: $pkg" >&2; exit 1; }
done


for wait_var in INITIAL_WAIT_SECONDS UPDATE_WAIT_SECONDS; do
  [[ ${!wait_var} =~ ^[1-9][0-9]{1,4}$ ]] && (( ${!wait_var} >= 30 && ${!wait_var} <= 86400 )) \
    || { echo "ERROR: $wait_var must be 30..86400 seconds." >&2; exit 1; }
done
[[ $UPDATE_TIME =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "ERROR: Invalid UPDATE_TIME." >&2; exit 1; }

# Validate common policy before CT creation; preserve explicitly empty inventories.
[[ $HARDENING_PROFILE == lxc && $HARDENING_RP_FILTER =~ ^[12]$ &&
   $HARDENING_KEEP_SSH =~ ^[01]$ && $HARDENING_REMOVE_POSTFIX =~ ^[01]$ ]] || {
  echo 'ERROR: Invalid service-LXC hardening policy.' >&2; exit 1;
}
for key in HARDENING_JOURNAL_DAYS HARDENING_JOURNAL_MAX_MB HARDENING_JOURNAL_RUNTIME_MB HARDENING_UPDATE_MAX_AGE_HOURS; do
  [[ ${!key} =~ ^[1-9][0-9]{0,3}$ ]] || { echo 'ERROR: Hardening numeric policy must be 1..9999.' >&2; exit 1; }
done
for key in HARDENING_TCP_PORTS HARDENING_UDP_PORTS; do
  value=${!key}
  [[ $key != HARDENING_TCP_PORTS || $value != auto ]] || continue
  [[ $value =~ ^[0-9\ ]*$ ]] || { echo 'ERROR: Listener inventories require one line of decimal ports.' >&2; exit 1; }
  for port in $value; do
    [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )) || {
      echo 'ERROR: Listener ports must be 1..65535, without leading zeroes.' >&2; exit 1;
    }
  done
done
if [[ $HARDENING_KEEP_SSH == 1 || $HARDENING_REMOVE_POSTFIX == 0 ]]; then
  [[ $HARDENING_TCP_PORTS != auto ]] || {
    echo 'ERROR: Preserved SSH/mail needs an explicit complete TCP inventory or explicit empty inventory-only mode.' >&2
    exit 1
  }
fi

# ── Preflight — root & commands ───────────────────────────────────────────────
INSTALL_STAGE="preflight"
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pveversion sha256sum cut date env pvesh pveam pct pvesm qm curl python3 ip awk grep sed sort paste seq readlink cp chmod dpkg head tr flock mktemp mv rm tail bash stat timeout; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

[[ -d /etc/pve ]] || { echo 'ERROR: This creator requires the Proxmox host.' >&2; exit 1; }
pveversion >/dev/null

# pveam lists templates for more than one CPU architecture. Selecting only by
# Debian version can pick an ARM64 rootfs on an AMD64 host (or vice versa),
# which creates successfully but fails when LXC executes /sbin/init.
# Serialize this creator before assigning an ID or checking its hostname.
exec 7>/run/lock/flatnotes-creator.lock
flock -n 7 || { echo "ERROR: Another flatnotes creator is running." >&2; exit 1; }

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

[[ $CT_ID =~ ^[1-9][0-9]{2,8}$ ]] && (( CT_ID >= 100 && CT_ID <= 999999999 )) || {
  echo 'ERROR: Invalid selected CT_ID.' >&2; exit 1;
}

# Creator scripts are not idempotent: a re-run would create a second CT with the
# same hostname. Refuse if one already exists on this node (e.g. a preserved
# failed install). Preserve it and refuse reuse.
EXISTING_CT="$(pct list 2>/dev/null | awk -v h="$HN" 'NR>1 && $NF==h {print $1}' | head -n1)"
if [[ -n "$EXISTING_CT" ]]; then
  echo "  ERROR: A CT with hostname '${HN}' already exists on this node (CT ${EXISTING_CT})." >&2
  echo "  Fresh creator: use the existing CT maintenance helper, or inspect the retained CT; it will not be reused." >&2
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

  Flatnotes Quadlet LXC Creator — Configuration
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
  Auth type:         $FLATNOTES_AUTH_TYPE
  Session expiry:    ${FLATNOTES_SESSION_EXPIRY_DAYS} days
  Path prefix:       ${FLATNOTES_PATH_PREFIX:-(none)}
  Timezone plan:     $TIMEZONE_LABEL
  FQDN:              $([ -n "$APP_FQDN" ] && echo "$APP_FQDN" || echo "(no public FQDN)")
  Listens on:        0.0.0.0:${APP_PORT} inside the CT (Network=host) — access follows the UFW source choice below
  Podman storage:    $([ "$PODMAN_FUSE_OVERLAY" -eq 1 ] && echo "fuse-overlayfs (fuse=1)" || echo "native overlay (no FUSE)")
  Tags:              $TAGS
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled (re-pull pinned $APP_TAG)" || echo "disabled (pinned $APP_TAG, manual)")
  Cleanup on fail:   $CLEANUP_ON_FAIL (ordinary early failures only; disarmed before first persistent start)
  Interruptions:     CT and external data are always preserved
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

if [[ "$FLATNOTES_AUTH_TYPE" == "none" || "$FLATNOTES_AUTH_TYPE" == "read_only" ]]; then
  echo "  WARNING: FLATNOTES_AUTH_TYPE=${FLATNOTES_AUTH_TYPE} — no login required. Port ${APP_PORT} is open to"
  echo "  the sources selected below. Restrict UFW_ALLOWED_SOURCES to intended clients or NPM IPs."
  echo ""
fi

SCRIPT_SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

response=""
read -r -p "  Continue with these settings? [y/N]: " response <&8 || { echo "ERROR: Confirmation interrupted." >&2; exit 1; }
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
      [[ ! -e $SCRIPT_LOCAL ]] || SCRIPT_LOCAL="/root/flatnotes-quadlet-downloaded.$$.sh"
      DOWNLOAD_TEMP=$(mktemp /root/flatnotes-download.XXXXXX)
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
  if [[ "$PW1" =~ [[:space:][:cntrl:]] ]]; then echo "  Password cannot contain whitespace/control characters."; continue; fi
  if [[ ${#PW1} -lt 8 ]]; then echo "  Password must be at least 8 characters."; continue; fi
  read -r -s -p "  Verify root password: " PW2 <&8; echo
  if [[ "$PW1" == "$PW2" ]]; then PASSWORD="$PW1"; break; fi
  echo "  Passwords do not match. Try again."
done

echo ""

# ── Flatnotes credentials ─────────────────────────────────────────────────────
# Values are written UNQUOTED to flatnotes.env (podman --env-file keeps quotes
# literally, unlike compose). Reject shell/systemd-sensitive characters so the
# value on disk is exactly what the app receives; verification round-trips the
# values through the running container to prove it.
FLATNOTES_USERNAME=""
FLATNOTES_PASSWORD=""
FLATNOTES_TOTP_KEY=""
FLATNOTES_TOTP_MANUAL_KEY=""
SECRET_KEY=""

if [[ "$FLATNOTES_AUTH_TYPE" == "password" || "$FLATNOTES_AUTH_TYPE" == "totp" ]]; then
  while true; do
    read -r -p "  Flatnotes username: " FLATNOTES_USERNAME <&8
    [[ -z "$FLATNOTES_USERNAME" ]] && { echo "  Username cannot be empty."; continue; }
    [[ "$FLATNOTES_USERNAME" =~ [[:space:][:cntrl:]] ]] && { echo "  Username cannot contain spaces."; continue; }
    [[ "$FLATNOTES_USERNAME" =~ [\"\'$\`\\#] ]] && { echo '  Username cannot contain quotes, $, backtick, backslash or #'; continue; }
    break
  done
  echo ""
  while true; do
    read -r -s -p "  Flatnotes password: " FN_PW1 <&8; echo
    if [[ -z "$FN_PW1" ]]; then echo "  Password cannot be blank."; continue; fi
    if [[ ${#FN_PW1} -lt 8 ]]; then echo "  Password must be at least 8 characters."; continue; fi
    if [[ "$FN_PW1" =~ [[:cntrl:]] ]]; then echo "  Password cannot contain control characters."; continue; fi
    if [[ "$FN_PW1" =~ ^[[:space:]]|[[:space:]]$ ]]; then echo "  Password cannot start or end with whitespace."; continue; fi
    if [[ "$FN_PW1" =~ [\"\'$\`\\#] ]]; then echo '  Password cannot contain quotes, $, backtick, backslash or #'; continue; fi
    read -r -s -p "  Verify Flatnotes password: " FN_PW2 <&8; echo
    if [[ "$FN_PW1" == "$FN_PW2" ]]; then FLATNOTES_PASSWORD="$FN_PW1"; break; fi
    echo "  Passwords do not match. Try again."
  done
  echo ""

  # FLATNOTES_SECRET_KEY signs session tokens — required for password and totp.
  set +o pipefail
  SECRET_KEY="$(head -c 4096 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 48)"
  set -o pipefail
  [[ ${#SECRET_KEY} -eq 48 ]] || { echo "  ERROR: Failed to generate secret key." >&2; exit 1; }
fi

if [[ "$FLATNOTES_AUTH_TYPE" == "totp" ]]; then
  set +o pipefail
  FLATNOTES_TOTP_KEY="$(head -c 4096 /dev/urandom | tr -dc 'A-Z2-7' | head -c 32)"
  set -o pipefail
  [[ ${#FLATNOTES_TOTP_KEY} -eq 32 ]] || { echo "  ERROR: Failed to generate TOTP key." >&2; exit 1; }
  # Flatnotes base32-encodes FLATNOTES_TOTP_KEY before handing it to pyotp;
  # the encoded form is what an authenticator app expects as the manual entry.
  FLATNOTES_TOTP_MANUAL_KEY="$(printf '%s' "$FLATNOTES_TOTP_KEY" \
    | python3 -c 'import base64,sys; sys.stdout.write(base64.b32encode(sys.stdin.buffer.read()).decode("ascii").rstrip("="))')"
  [[ -n "$FLATNOTES_TOTP_MANUAL_KEY" ]] || { echo "  ERROR: Failed to derive the TOTP authenticator key." >&2; exit 1; }
  echo "  Generated TOTP seed; the authenticator key will be shown in the summary."
  echo ""
fi

# Finalized application listener inventory; firewall source policy is independent.
FINALIZED_APP_TCP_PORTS=$APP_PORT
# COMMON TCP RESOLUTION
[[ $HARDENING_TCP_PORTS != auto ]] || HARDENING_TCP_PORTS=$FINALIZED_APP_TCP_PORTS
# END COMMON TCP RESOLUTION

for key in HARDENING_TCP_PORTS HARDENING_UDP_PORTS; do
  [[ ${!key} =~ ^[0-9\ ]*$ ]] || { echo 'ERROR: Invalid finalized listener inventory.' >&2; exit 1; }
  for port in ${!key}; do
    [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )) || {
      echo 'ERROR: Invalid finalized listener port.' >&2; exit 1;
    }
  done
done

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
INSTALL_STAGE="create LXC"
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

# ── OS update ─────────────────────────────────────────────────────────────────
INSTALL_STAGE="OS bootstrap"
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
  apt-get install -y locales tzdata curl ca-certificates iproute2 python3 ufw iptables util-linux podman tar gzip ${PODMAN_FUSE_PKG}
  sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
"

# ── Guest timezone planning (read-only until the late common block) ────────────
INSTALL_STAGE="guest timezone validation"
pct exec "$CT_ID" -- bash -s <<'EARLY_TIMEZONE_BOOTSTRAP'
set -euo pipefail
target=/usr/local/sbin/lab-timezone
[[ ! -L $target && ( ! -e $target || -f $target ) ]] || {
  echo 'ERROR: Unsafe timezone helper destination.' >&2; exit 1;
}
install -d -m 0755 /usr/local/sbin
tmp=$(mktemp /usr/local/sbin/.lab-timezone.XXXXXX)
trap 'rm -f -- "$tmp"' EXIT
cat > "$tmp" <<'EARLY_TIMEZONE_HELPER'
#!/usr/bin/python3
"""LXC timezone policy, adapted from debian-hardening.sh v1.0.3.

Only apply writes timezone files; plan/check are read-only. No timedated,
clock, RTC, NTP, SSH, or access-recovery operations are performed.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from zoneinfo import ZoneInfo

ZONES = Path('/usr/share/zoneinfo')
LOCALTIME = Path('/etc/localtime')
TIMEZONE = Path('/etc/timezone')


def guest_guard():
    if os.geteuid() != 0 or shutil.which('pveversion') or Path('/etc/pve').exists():
        raise ValueError('Timezone operations require root inside the selected Debian 13 LXC.')
    release = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines()
                   if '=' in line and not line.startswith('#'))
    if release.get('ID', '').strip('"') != 'debian' or release.get('VERSION_ID', '').strip('"') != '13':
        raise ValueError('Timezone policy requires Debian 13.')
    result = subprocess.run(['systemd-detect-virt', '--container'], text=True,
                            capture_output=True, timeout=10)
    if result.returncode or result.stdout.strip() != 'lxc':
        raise ValueError('Timezone policy refuses environments other than LXC.')


def zone_path(name):
    # Same name grammar as the native source; validate against guest tzdata.
    if not re.fullmatch(r'[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+)*', name):
        raise ValueError('Invalid SERVER_TIMEZONE; use an installed IANA timezone name.')
    if name.split('/')[0] in ('posix', 'right', 'localtime', 'posixrules'):
        raise ValueError('SERVER_TIMEZONE must identify an IANA zone, not a special tzdata tree.')
    path = ZONES / name
    try:
        path.resolve(strict=True).relative_to(ZONES.resolve(strict=True))
        with path.open('rb') as stream:
            ZoneInfo.from_file(stream, key=name)
    except (OSError, ValueError) as exc:
        raise ValueError('Timezone is unavailable or invalid in this guest: ' + name) from exc
    return path


def effective_timezone():
    if not LOCALTIME.exists() and not LOCALTIME.is_symlink():
        zone_path('UTC')
        return 'UTC'  # localtime(5): absent /etc/localtime means UTC.
    if LOCALTIME.is_symlink():
        # Keep the selected alias, rather than resolving US/Eastern to another name.
        link = Path(os.path.normpath(LOCALTIME.parent / os.readlink(LOCALTIME)))
        try:
            name = str(link.relative_to(ZONES))
        except ValueError as exc:
            raise ValueError('/etc/localtime does not link into the guest zoneinfo tree.') from exc
        zone_path(name)
        return name
    if LOCALTIME.is_file() and TIMEZONE.is_file() and not TIMEZONE.is_symlink():
        name = TIMEZONE.read_text().strip()
        if LOCALTIME.read_bytes() == zone_path(name).read_bytes():
            return name
    raise ValueError('Cannot identify the guest timezone from /etc/localtime and /etc/timezone.')


def fingerprint(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return {'kind': 'absent'}
    if stat.S_ISLNK(info.st_mode):
        return {'kind': 'symlink', 'target': os.readlink(path)}
    if stat.S_ISREG(info.st_mode):
        return {'kind': 'file', 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    raise ValueError('Unsupported timezone file type: ' + str(path))


def fingerprints():
    return {str(path): fingerprint(path) for path in (LOCALTIME, TIMEZONE)}


def plan(preserve, requested):
    if preserve not in ('0', '1'):
        raise ValueError('PRESERVE_EXISTING_TIMEZONE must be exactly 0 or 1.')
    if preserve == '0':
        zone_path(requested)
        if TIMEZONE.is_symlink() or (TIMEZONE.exists() and not TIMEZONE.is_file()):
            raise ValueError('Refusing to replace a non-regular /etc/timezone.')
    before = effective_timezone()
    return {'preserve': preserve == '1', 'requested': None if preserve == '1' else requested,
            'before': before, 'effective': before if preserve == '1' else requested,
            'files_before': fingerprints()}


def verify(setting):
    actual = effective_timezone()
    if actual != setting['effective']:
        raise ValueError('Guest timezone drift: expected ' + setting['effective'] + ', found ' + actual)
    expected_files = setting.get('files', setting['files_before'])
    if fingerprints() != expected_files:
        raise ValueError('Guest timezone files changed; review /etc/localtime and /etc/timezone.')
    return actual


def apply(setting, backup):
    if fingerprints() != setting['files_before'] or effective_timezone() != setting['before']:
        raise ValueError('Guest timezone changed after validation; refusing to overwrite it.')
    if not setting['preserve']:
        target = zone_path(setting['requested'])
        saved = Path(backup) / 'timezone'
        saved.mkdir(mode=0o700, parents=True, exist_ok=False)
        (saved / 'before.json').write_text(json.dumps(setting, indent=2) + '\n')
        for path in (LOCALTIME, TIMEZONE):
            if path.exists() or path.is_symlink():
                shutil.copy2(path, saved / path.name, follow_symlinks=False)
        # Atomic per-file replacement; no automatic undo of a later failure.
        if setting['before'] != setting['requested']:
            with tempfile.TemporaryDirectory(prefix='.lab-timezone-', dir=LOCALTIME.parent) as tmp:
                replacement = Path(tmp) / 'localtime'
                replacement.symlink_to(target)
                os.replace(replacement, LOCALTIME)
        # Debian uses /etc/localtime. Keep an existing legacy file consistent;
        # do not introduce /etc/timezone when the template does not maintain it.
        desired = setting['requested'] + '\n'
        if TIMEZONE.exists() and TIMEZONE.read_text() != desired:
            with tempfile.TemporaryDirectory(prefix='.lab-timezone-', dir=TIMEZONE.parent) as tmp:
                replacement = Path(tmp) / 'timezone'
                replacement.write_text(desired)
                replacement.chmod(0o644)
                os.replace(replacement, TIMEZONE)
    final = {**setting, 'files': fingerprints()}
    if setting['preserve'] and final['files'] != setting['files_before']:
        raise ValueError('Preserve mode detected a timezone-file change.')
    verify(final)
    return final


def main():
    guest_guard()
    if len(sys.argv) == 4 and sys.argv[1] == 'plan':
        print(json.dumps(plan(sys.argv[2], sys.argv[3])))
    elif len(sys.argv) == 4 and sys.argv[1] == 'apply':
        setting = json.loads(Path(sys.argv[2]).read_text())
        print(json.dumps(apply(setting, sys.argv[3])))
    elif len(sys.argv) == 3 and sys.argv[1] == 'check':
        policy = json.loads(Path(sys.argv[2]).read_text())
        print(verify(policy['timezone']))
    else:
        raise ValueError('Invalid timezone helper arguments.')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print('ERROR: LXC timezone: ' + str(exc), file=sys.stderr)
        raise SystemExit(1)
EARLY_TIMEZONE_HELPER
chown root:root "$tmp"
chmod 0755 "$tmp"
mv -fT "$tmp" "$target"
EARLY_TIMEZONE_BOOTSTRAP
# COMMON EARLY TIMEZONE PLAN
INSTALL_STAGE="guest timezone validation"
TIMEZONE_PLAN=$(pct exec "$CT_ID" -- /usr/local/sbin/lab-timezone plan "$PRESERVE_EXISTING_TIMEZONE" "$SERVER_TIMEZONE")
APP_TZ=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["effective"])' "$TIMEZONE_PLAN")
printf '  Guest timezone plan: %s (%s during shared hardening).\n' "$APP_TZ" "$TIMEZONE_ACTION"
# END COMMON EARLY TIMEZONE PLAN

printf '%s\n' "$TIMEZONE_PLAN" | pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  install -d -m 0755 /opt/flatnotes
  umask 077
  cat > /opt/flatnotes/timezone-plan.json
  chmod 0600 /opt/flatnotes/timezone-plan.json
'

# ── UFW inside the CT ─────────────────────────────────────────────────────────
INSTALL_STAGE="UFW setup"
# Fresh CT only. Network=host uses this CT's INPUT chain.
pct exec "$CT_ID" -- bash -s -- "$APP_PORT" "${UFW_ALLOWED_SOURCES[@]}" <<'UFWSETUP'
set -euo pipefail
export LC_ALL=C
port=$1; shift
(( $# > 0 )) || { echo "ERROR: No allowed source addresses."; false; }
iptables -w 5 -S INPUT >/dev/null
ip6tables -w 5 -S INPUT >/dev/null
# Preserve existing UFW rules; add only the selected Flatnotes source allows.
sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
grep -qx 'IPV6=yes' /etc/default/ufw
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
python3 - "$port" "$@" <<'ACCESS_POLICY'
import hashlib, ipaddress, json, pathlib, sys
policy = {'port': int(sys.argv[1]), 'sources': sorted(set(str(ipaddress.ip_network(s, strict=True)) for s in sys.argv[2:])),
          'rules_sha256': {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                           for base in ('before', 'after', 'user') for suffix in ('', '6')
                           for p in [pathlib.Path('/etc/ufw') / (base + suffix + '.rules')]}}
p = pathlib.Path('/opt/flatnotes/access.json')
p.write_text(json.dumps(policy, indent=2) + '\n')
p.chmod(0o644)
ACCESS_POLICY
UFWSETUP

tmp=$(mktemp)
cat > "$tmp" <<'UFWCHECK'
#!/usr/bin/python3
"""Read-only Flatnotes access guard. Never changes a firewall rule."""
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

def require(ok, message):
    if not ok:
        raise ValueError(message)

def run(args):
    p = subprocess.run(args, capture_output=True, text=True, timeout=30)
    require(p.returncode == 0, 'firewall command failed; inspect UFW state')
    return p.stdout

def value(tokens, flag, default=None):
    return tokens[tokens.index(flag) + 1] if flag in tokens else default

def port_matches(spec, port):
    for item in spec.split(','):
        bounds = item.split(':')
        require(len(bounds) <= 2 and all(not x or x.isdecimal() for x in bounds),
                'unsupported TCP port expression')
        low = int(bounds[0] or 0)
        high = int(bounds[-1] or 65535)
        if low <= port <= high:
            return True
    return False

def inspect_input(text, version, port, sources):
    """Conservative graph walk for NEW external TCP to this port.

    Prove no potentially reachable ACCEPT exceeds the chosen sources. Drops
    are not used to excuse a later broad ACCEPT. Unknown relevant matches or
    targets fail closed; protocol/port/state exclusions are evaluated first.
    This is a scoped policy check, not a general netfilter interpreter.
    """
    chains = {}
    policies = {}
    for line in text.splitlines():
        t = shlex.split(line)
        require(len(t) >= 2 and t[0] in ('-P', '-N', '-A'), 'unrecognized filter table')
        chains.setdefault(t[1], [])
        if t[0] == '-P':
            policies[t[1]] = t[2]
        elif t[0] == '-A':
            chains[t[1]].append(t[2:])
    require(policies.get('INPUT') == policies.get('FORWARD') == 'DROP',
            'effective INPUT/FORWARD policy must be DROP')
    require(policies.get('OUTPUT') == 'ACCEPT', 'effective OUTPUT policy must be ACCEPT')
    allowed = list(ipaddress.collapse_addresses(n for n in sources if n.version == version))
    universe = ipaddress.ip_network('0.0.0.0/0' if version == 4 else '::/0')
    prefix = 'ufw' if version == 4 else 'ufw6'
    for hook in ('before', 'after', 'reject', 'track'):
        require(['-j', prefix + '-' + hook + '-input'] in chains['INPUT'],
                'required UFW INPUT hook missing')
    require(prefix + '-user-input' in chains, 'UFW user input chain missing')

    def walk(chain, inherited, parents):
        require(chain not in parents and len(parents) < 32, 'cyclic/overdeep input chain')
        require(chain in chains, 'unknown reachable TCP input target; review custom filtering')
        for t in chains[chain]:
            # Skip only proven irrelevant rules, before inspecting their targets.
            # This preserves UFW DHCP, ICMPv6 and protocol-41 handling.
            proto = value(t, '-p', 'all')
            if '-p' in t and (t.index('-p') == 0 or t[t.index('-p') - 1] != '!'):
                if proto not in ('all', '0', 'tcp', '6'):
                    continue
            if value(t, '-i') == 'lo' and '!' not in t:
                continue
            states = value(t, '--ctstate', value(t, '--state'))
            if states and '!' not in t and 'NEW' not in states.split(','):
                continue
            dport = value(t, '--dport', value(t, '--dports'))
            if dport and '!' not in t and not port_matches(dport, port):
                continue
            require('!' not in t and '-g' not in t, 'unsupported relevant negation/goto')
            dst_type = value(t, '--dst-type')
            if dst_type and dst_type in ('BROADCAST', 'MULTICAST'):
                continue
            source = ipaddress.ip_network(value(t, '-s', str(universe)), strict=False)
            require(source.version == version, 'source address family mismatch')
            if not source.overlaps(inherited):
                continue
            effective = source if source.subnet_of(inherited) else inherited
            target = value(t, '-j')
            if target in ('LOG', 'NFLOG'):
                continue  # non-terminating observation only
            if target in ('DROP', 'REJECT'):
                continue  # never relied on to authorize a broad later rule
            # Known match forms; unfamiliar potentially relevant filtering fails.
            arity = {'-s': 1, '-d': 1, '-p': 1, '-i': 1, '-j': 1, '-m': 1,
                     '--dport': 1, '--dports': 1, '--sport': 1, '--sports': 1,
                     '--ctstate': 1, '--state': 1, '--dst-type': 1, '--comment': 1,
                     '--tcp-flags': 2, '--syn': 0}
            i = 0
            while i < len(t):
                token = t[i]
                require(token in arity and i + arity[token] < len(t),
                        'unsupported relevant input match')
                if token == '-m':
                    require(t[i + 1] in ('tcp', 'multiport', 'conntrack', 'state', 'addrtype', 'comment'),
                            'unsupported relevant input match module')
                if token == '--dst-type':
                    require(t[i + 1] == 'LOCAL', 'unsupported relevant destination type')
                i += arity[token] + 1
            if target == 'ACCEPT':
                require(any(effective.subnet_of(n) for n in allowed),
                        'broader TCP access than the selected source policy')
            elif target == 'RETURN':
                if t == ['-j', 'RETURN'] or t == ['-m', 'addrtype', '--dst-type', 'LOCAL', '-j', 'RETURN']:
                    break
            elif target is not None:
                walk(target, effective, parents + [chain])
            else:
                require(False, 'missing reachable input target')
    walk('INPUT', universe, [])

def main():
    require(os.geteuid() == 0 and len(sys.argv) == 1, 'run as root without arguments')
    os.environ['LC_ALL'] = 'C'
    os.environ['PATH'] = '/usr/sbin:/usr/bin:/sbin:/bin'
    path = Path('/opt/flatnotes/access.json')
    require(not path.is_symlink() and path.is_file(), 'missing regular access policy')
    st = path.stat()
    require(st.st_uid == 0 and not st.st_mode & 0o022, 'unsafe access policy ownership/mode')
    policy = json.loads(path.read_text())
    port = policy['port']
    require(type(port) is int and 1024 <= port <= 65535, 'invalid access port')
    sources = [ipaddress.ip_network(s, strict=True) for s in policy['sources']]
    require(bool(sources), 'empty access policy')
    expected_files = {f'/etc/ufw/{base}{suffix}.rules'
                      for base in ('before', 'after', 'user') for suffix in ('', '6')}
    require(set(policy['rules_sha256']) == expected_files, 'incomplete persistent UFW baseline')
    for filename, digest in policy['rules_sha256'].items():
        require(hashlib.sha256(Path(filename).read_bytes()).hexdigest() == digest,
                'persistent UFW file changed; review the selected access policy')
    require('ENABLED=yes' in Path('/etc/ufw/ufw.conf').read_text().splitlines(), 'UFW is not persistent')
    defaults = Path('/etc/default/ufw').read_text().splitlines()
    for setting in ('IPV6=yes', 'DEFAULT_INPUT_POLICY="DROP"',
                    'DEFAULT_OUTPUT_POLICY="ACCEPT"', 'DEFAULT_FORWARD_POLICY="DROP"'):
        require(setting in defaults, 'UFW defaults differ from the service policy')
    require('Status: active' in run(['ufw', 'status']).splitlines(), 'UFW is inactive')
    for action in ('is-enabled', 'is-active'):
        run(['systemctl', action, '--quiet', 'ufw.service'])
    for version, tool, prefix in ((4, 'iptables', 'ufw'), (6, 'ip6tables', 'ufw6')):
        table = run([tool, '-w', '5', '-S'])
        inspect_input(table, version, port, sources)
        for source in sources:
            if source.version == version:
                run([tool, '-w', '5', '-C', prefix + '-user-input', '-s', str(source),
                     '-p', 'tcp', '-m', 'tcp', '--dport', str(port), '-j', 'ACCEPT'])

if __name__ == '__main__':
    try:
        main()
    except ValueError as exc:
        print('ERROR: Flatnotes UFW: ' + str(exc), file=sys.stderr)
        raise SystemExit(1)
    except Exception:
        # Do not expose subprocess arguments or policy/configuration contents.
        print('ERROR: Flatnotes UFW verification failed; inspect source policy, rules and service state.', file=sys.stderr)
        raise SystemExit(1)
UFWCHECK
pct push "$CT_ID" "$tmp" /usr/local/sbin/flatnotes-ufw-check --perms 0755
rm -f -- "$tmp"

pct exec "$CT_ID" -- /usr/local/sbin/flatnotes-ufw-check

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

# ── Pull image ────────────────────────────────────────────────────────────────
INSTALL_STAGE="image compatibility"
echo "  Pulling Flatnotes image: ${APP_IMAGE} ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman pull '${APP_IMAGE}'
"


# ── Resolve immutable runtime images ──────────────────────────────────────────
for component in APP; do
  reference_var=${component}_IMAGE
  resolved=$(pct exec "$CT_ID" -- podman image inspect --format '{{.Id}}' "${!reference_var}")
  resolved=${resolved#sha256:}
  [[ $resolved =~ ^[a-f0-9]{64}$ ]] || { echo "ERROR: Invalid image ID for $component." >&2; false; }
  printf -v "${component}_IMAGE_ID" 'sha256:%s' "$resolved"
done

# Disposable compatibility probe: default entrypoint is preserved for production.
pct exec "$CT_ID" -- timeout 60 podman run --rm --pull=never --network none --read-only \
  --user 1000:1000 --entrypoint /bin/sh "$APP_IMAGE_ID" -ec \
  'test "$(id -u):$(id -g)" = 1000:1000; python3 -c "import os,time,json"'

INSTALL_STAGE="application configuration"
# ── Prepare persistent paths ──────────────────────────────────────────────────
# Flatnotes persistent state (all of it):
#   /opt/flatnotes/data/            notes (*.md), attachments, .flatnotes/ search index
# The image entrypoint drops to PUID/PGID (1000:1000) before starting the app,
# so data/ must be owned by 1000:1000 as seen from inside the LXC. The app
# creates .flatnotes/ itself on first start — do not pre-create it.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  install -d -m 0755 '${APP_DIR}'
  install -d -m 0755 -o 1000 -g 1000 '${APP_DIR}/data'
"

# ── Quadlet unit file ─────────────────────────────────────────────────────────
# Rootful Quadlet: /etc/containers/systemd/ — no linger, no --user flags needed.
# systemd daemon-reload triggers the Quadlet generator; flatnotes.service is
# created as a transient unit and WantedBy=multi-user.target handles boot start.
# Network=host bypasses Netavark NAT issues on Debian LXC; FLATNOTES_PORT tells
# the app which port to bind on the CT interface instead of PublishPort=.
# Credentials live in flatnotes.env (0600) via EnvironmentFile=, so this unit
# file contains no secrets and can stay 0644.
PREFIX_LINE=""
[[ -n "$FLATNOTES_PATH_PREFIX" ]] && PREFIX_LINE="Environment=FLATNOTES_PATH_PREFIX=${FLATNOTES_PATH_PREFIX}"

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  mkdir -p /etc/containers/systemd

  cat > '${QUADLET_FILE}' <<EOF2
[Unit]
Description=Flatnotes
After=network-online.target ufw.service
Wants=network-online.target
Requires=ufw.service

[Container]
# LabTag=${APP_TAG}
# LabImage=${APP_IMAGE}
Image=${APP_IMAGE_ID}
Pull=never
ContainerName=flatnotes
Network=host
Environment=TZ=${APP_TZ}
Environment=PUID=1000
Environment=PGID=1000
Environment=FLATNOTES_PORT=${APP_PORT}
Environment=FLATNOTES_AUTH_TYPE=${FLATNOTES_AUTH_TYPE}
Environment=FLATNOTES_SESSION_EXPIRY_DAYS=${FLATNOTES_SESSION_EXPIRY_DAYS}
${PREFIX_LINE}
EnvironmentFile=${APP_ENV_FILE}
Volume=${APP_DIR}/data:/data
StopTimeout=50
LogDriver=journald

[Service]
ExecStartPre=/usr/local/sbin/flatnotes-ufw-check
Restart=always
RestartSec=5
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF2

  chmod 0644 '${QUADLET_FILE}'
"

# ── Container credentials file ────────────────────────────────────────────────
# Read by Quadlet via EnvironmentFile= (podman --env-file). Written UNQUOTED —
# podman keeps quotes as part of the value. Streamed over stdin so credentials
# never appear in host or CT argv, and no temp file is created.
{
  printf '# Flatnotes container credentials — managed by flatnotes-quadlet.sh\n'
  if [[ "$FLATNOTES_AUTH_TYPE" == "password" || "$FLATNOTES_AUTH_TYPE" == "totp" ]]; then
    printf 'FLATNOTES_USERNAME=%s\n' "$FLATNOTES_USERNAME"
    printf 'FLATNOTES_PASSWORD=%s\n' "$FLATNOTES_PASSWORD"
    printf 'FLATNOTES_SECRET_KEY=%s\n' "$SECRET_KEY"
  fi
  if [[ "$FLATNOTES_AUTH_TYPE" == "totp" ]]; then
    printf 'FLATNOTES_TOTP_KEY=%s\n' "$FLATNOTES_TOTP_KEY"
  fi
} | pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  umask 077
  cat > '${APP_ENV_FILE}'
  chmod 0600 '${APP_ENV_FILE}'
"
unset SECRET_KEY FLATNOTES_TOTP_KEY FN_PW1 FN_PW2 FLATNOTES_PASSWORD

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
APP_FQDN=${APP_FQDN}
FLATNOTES_AUTH_TYPE=${FLATNOTES_AUTH_TYPE}
FLATNOTES_SESSION_EXPIRY_DAYS=${FLATNOTES_SESSION_EXPIRY_DAYS}
FLATNOTES_PATH_PREFIX=${FLATNOTES_PATH_PREFIX}
AUTO_UPDATE=${AUTO_UPDATE}
PODMAN_FUSE_OVERLAY=${PODMAN_FUSE_OVERLAY}
INITIAL_WAIT_SECONDS=${INITIAL_WAIT_SECONDS}
UPDATE_WAIT_SECONDS=${UPDATE_WAIT_SECONDS}
UPDATE_TIME=${UPDATE_TIME}
EOF2
  chmod 0600 '${APP_DIR}/.env'
"

# ── Reusable application verification and maintenance ───────────────────────
tmp=$(mktemp)
cat > "$tmp" <<'APP_CHECK'
#!/usr/bin/python3
"""Complete observational Flatnotes verifier; maintenance owns the shared lock."""
import datetime
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
from zoneinfo import ZoneInfo

def require(ok, message):
    if not ok:
        raise ValueError(message)

def run(args, timeout=30):
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    require(p.returncode == 0, 'required runtime command failed (arguments omitted)')
    return p.stdout.strip()

def regular(path, mode=None):
    p = Path(path)
    info = p.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_gid == 0,
            'control file must be a regular root-owned file')
    require(not info.st_mode & 0o022, 'control file is writable by another account')
    if mode is not None:
        require(stat.S_IMODE(info.st_mode) == mode, 'control file permissions differ')
    return p

def data_file(path):
    values = {}
    for line in regular(path, 0o600).read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        key, sep, value = line.partition('=')
        require(sep and re.fullmatch(r'[A-Z][A-Z0-9_]*', key) and key not in values,
                'malformed or duplicate state/configuration key')
        values[key] = value
    return values

def one(lines, prefix):
    values = [line[len(prefix):] for line in lines if line.startswith(prefix)]
    require(len(values) == 1, 'missing or duplicate Quadlet setting')
    return values[0]

def service_value(name):
    return run(['systemctl', 'show', 'flatnotes.service', '-p', name, '--value'])

def main():
    require(os.geteuid() == 0, 'run as root in the Flatnotes CT')
    require(sys.argv[1:] in ([], ['--initial']), 'usage: flatnotes-check [--initial]')
    initial = sys.argv[1:] == ['--initial']
    bootstrap = os.environ.get('FLATNOTES_INSTALL_BOOTSTRAP', '')
    require(bootstrap in ('', '1') and (not bootstrap or initial), 'invalid bootstrap context')
    os.environ['LC_ALL'] = 'C'
    os.environ['PATH'] = '/usr/sbin:/usr/bin:/sbin:/bin'
    state = data_file('/opt/flatnotes/.env')
    for key, low, high in (('APP_PORT', 1024, 65535), ('INITIAL_WAIT_SECONDS', 30, 86400),
                           ('UPDATE_WAIT_SECONDS', 30, 86400), ('FLATNOTES_SESSION_EXPIRY_DAYS', 1, 999999)):
        require(re.fullmatch(r'[1-9][0-9]{0,5}', state.get(key, '')) and
                low <= int(state[key]) <= high, 'invalid numeric application policy')
    require(state.get('AUTO_UPDATE') in ('0', '1') and state.get('PODMAN_FUSE_OVERLAY') in ('0', '1'),
            'invalid update/storage policy')
    require(re.fullmatch(r'([01][0-9]|2[0-3]):[0-5][0-9]', state.get('UPDATE_TIME', '')), 'invalid update time')
    require(re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?', state.get('APP_TAG', '')),
            'invalid pinned image tag')
    require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._/-]*[A-Za-z0-9]', state.get('APP_IMAGE_REPO', '')),
            'invalid image repository')
    require(state.get('APP_IMAGE') == state['APP_IMAGE_REPO'] + ':' + state['APP_TAG'] and
            re.fullmatch(r'sha256:[a-f0-9]{64}', state.get('APP_IMAGE_ID', '')), 'inconsistent image state')
    prefix = state.get('FLATNOTES_PATH_PREFIX', '')
    require(not prefix or re.fullmatch(r'(/[A-Za-z0-9._~-]+)+', prefix), 'invalid path prefix')
    require(state.get('FLATNOTES_AUTH_TYPE') in ('password', 'none', 'read_only', 'totp'), 'invalid auth policy')
    zone = state.get('APP_TZ', '')
    require(re.fullmatch(r'[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*', zone), 'invalid application timezone')
    ZoneInfo(zone)
    access = json.loads(regular('/opt/flatnotes/access.json').read_text())
    require(access['port'] == int(state['APP_PORT']), 'access/application port mismatch')
    run(['/usr/local/sbin/flatnotes-ufw-check'])

    policy_path = Path('/var/lib/lab-hardening/policy.json')
    if bootstrap:
        require(not policy_path.exists(), 'bootstrap exception is only for the first installation check')
        plan = json.loads(regular('/opt/flatnotes/timezone-plan.json', 0o600).read_text())
        require(plan['effective'] == zone, 'planned application timezone mismatch')
        current = json.loads(run(['/usr/local/sbin/lab-timezone', 'plan',
                                  '1' if plan['preserve'] else '0', plan['requested'] or '']))
        require(current == plan, 'guest timezone plan changed before startup verification')
    else:
        policy = json.loads(regular(policy_path).read_text())
        require(policy.get('version') == '1.2.0' and policy.get('profile') == 'lxc',
                'missing or mismatched final hardening policy')
        require(policy['timezone']['effective'] == zone, 'application/hardening timezone mismatch')
        require(run(['/usr/local/sbin/lab-timezone', 'check', str(policy_path)]) == zone,
                'final guest timezone differs from application')
        for path, expected in policy['files'].items():
            require(hashlib.sha256(Path(path).read_bytes()).hexdigest() == expected,
                    'managed hardening file changed')

    lines = regular('/etc/containers/systemd/flatnotes.container', 0o644).read_text().splitlines()
    for key, expected in {'Image=': state['APP_IMAGE_ID'], 'Pull=': 'never', 'Network=': 'host',
                          'ContainerName=': 'flatnotes', '# LabTag=': state['APP_TAG'],
                          '# LabImage=': state['APP_IMAGE'],
                          'EnvironmentFile=': '/opt/flatnotes/flatnotes.env',
                          'Volume=': '/opt/flatnotes/data:/data', 'StopTimeout=': '50',
                          'TimeoutStopSec=': '60',
                          'ExecStartPre=': '/usr/local/sbin/flatnotes-ufw-check'}.items():
        require(one(lines, key) == expected, 'Quadlet runtime contract differs')
    require(not any(line.startswith(('Exec=', 'Entrypoint=', 'User=', 'PublishPort=')) for line in lines),
            'unexpected Flatnotes entrypoint/user/network override')
    require(service_value('LoadState') == 'loaded', 'Flatnotes service is not loaded')
    generated = run(['systemctl', 'cat', 'flatnotes.service'])
    require('/usr/local/sbin/flatnotes-ufw-check' in generated and state['APP_IMAGE_ID'] in generated,
            'loaded unit does not reflect the configured image/firewall guard')

    budget = int(state['INITIAL_WAIT_SECONDS' if initial else 'UPDATE_WAIT_SECONDS'])
    started = time.monotonic()
    stable_since = None
    restarts = service_value('NRestarts')
    require(restarts.isdecimal() and (not initial or restarts == '0'), 'unexpected initial restart count')
    while time.monotonic() - started < budget:
        active = service_value('ActiveState')
        require(active not in ('failed', 'inactive') and service_value('NRestarts') == restarts,
                'Flatnotes failed, stopped or restarted during observation')
        p = subprocess.run(['curl', '--silent', '--output', '/dev/null', '--write-out', '%{http_code}',
                            '--connect-timeout', '2', '--max-time', '3',
                            'http://127.0.0.1:' + state['APP_PORT'] + prefix + '/health'],
                           capture_output=True, text=True, timeout=5)
        if active == 'active' and p.returncode == 0 and p.stdout == '200':
            stable_since = stable_since or time.monotonic()
            if time.monotonic() - stable_since >= 6:
                break
        else:
            stable_since = None
        time.sleep(2)
    else:
        raise ValueError('Flatnotes /health did not become stably ready within the selected budget')

    container = json.loads(run(['podman', 'inspect', 'flatnotes']))[0]
    require(container['State']['Running'] and container['Name'].lstrip('/') == 'flatnotes', 'container is not running')
    require('sha256:' + container['Image'].removeprefix('sha256:') == state['APP_IMAGE_ID'], 'running image differs')
    image = json.loads(run(['podman', 'image', 'inspect', state['APP_IMAGE_ID']]))[0]
    require('sha256:' + image['Id'].removeprefix('sha256:') == state['APP_IMAGE_ID'], 'local image identity differs')
    require(container['HostConfig']['NetworkMode'] == 'host', 'container is not using host networking')
    require((container['Config'].get('Entrypoint') or []) == (image['Config'].get('Entrypoint') or []) and
            (container['Config'].get('Cmd') or []) == (image['Config'].get('Cmd') or []), 'image entrypoint/command was overridden')
    mounts = [m for m in container['Mounts'] if m['Destination'] == '/data']
    require(len(mounts) == 1 and mounts[0]['Type'] == 'bind' and
            mounts[0]['Source'] == '/opt/flatnotes/data' and mounts[0]['RW'], 'persistent mount differs')
    root = Path('/opt/flatnotes/data')
    require(root.is_dir() and not root.is_symlink() and root.stat().st_uid == root.stat().st_gid == 1000,
            'Flatnotes data ownership/path differs')
    run(['podman', 'exec', '--user', '1000:1000', 'flatnotes', 'python3', '-c',
         'import os; from pathlib import Path; p=Path("/data"); '
         'assert os.getuid()==os.getgid()==1000 and os.access(p,os.R_OK|os.W_OK|os.X_OK); '
         'q=p/".flatnotes"; assert not q.exists() or (q.is_dir() and '
         'q.stat().st_uid==q.stat().st_gid==1000 and os.access(q,os.R_OK|os.W_OK|os.X_OK))'])
    env = {}
    for item in container['Config']['Env']:
        key, _, val = item.partition('=')
        require(key not in env, 'duplicate runtime environment key')
        env[key] = val
    wanted = {'TZ': zone, 'PUID': '1000', 'PGID': '1000', 'FLATNOTES_PORT': state['APP_PORT'],
              'FLATNOTES_AUTH_TYPE': state['FLATNOTES_AUTH_TYPE'],
              'FLATNOTES_SESSION_EXPIRY_DAYS': state['FLATNOTES_SESSION_EXPIRY_DAYS']}
    if prefix:
        wanted['FLATNOTES_PATH_PREFIX'] = prefix
    else:
        require(env.get('FLATNOTES_PATH_PREFIX', '') == '', 'unexpected runtime path prefix')
    secrets = data_file('/opt/flatnotes/flatnotes.env')
    expected_secret_keys = set()
    if state['FLATNOTES_AUTH_TYPE'] in ('password', 'totp'):
        expected_secret_keys = {'FLATNOTES_USERNAME', 'FLATNOTES_PASSWORD', 'FLATNOTES_SECRET_KEY'}
    if state['FLATNOTES_AUTH_TYPE'] == 'totp':
        expected_secret_keys.add('FLATNOTES_TOTP_KEY')
    require(set(secrets) == expected_secret_keys and all(secrets.values()), 'credential file keys differ')
    wanted.update(secrets)
    # Captured privately; neither inspect output nor environment values are printed.
    runtime_env = json.loads(run(['podman', 'exec', 'flatnotes', 'python3', '-c',
                                 'import json,os; print(json.dumps(dict(os.environ)))']))
    for key, expected in wanted.items():
        require(env.get(key) == runtime_env.get(key) == expected, 'runtime configuration/secret delivery mismatch')
        if key not in secrets:
            require(one(lines, 'Environment=' + key + '=') == expected, 'Quadlet environment differs')
    clock = json.loads(run(['podman', 'exec', '--user', '1000:1000', 'flatnotes', 'python3', '-c',
                            'import json,time; t=time.time(); v=time.localtime(t); '
                            'print(json.dumps([t,v.tm_gmtoff,v.tm_zone]))']))
    expected_clock = datetime.datetime.fromtimestamp(clock[0], ZoneInfo(zone))
    require(clock[1] == int(expected_clock.utcoffset().total_seconds()) and clock[2] == expected_clock.tzname(),
            'application timezone use differs from the planned zone')

    # ss supplies only socket-owner PIDs; no process command lines are printed.
    pid = int(container['State']['Pid'])
    group = Path(f'/proc/{pid}/cgroup').read_text()
    require(group.strip(), 'container cgroup identity unavailable')
    found = False
    for line in run(['ss', '-H', '-ltnp']).splitlines():
        fields = line.split()
        require(len(fields) >= 4, 'unrecognized TCP socket inventory')
        address, port = fields[3].rsplit(':', 1)
        if port != state['APP_PORT']:
            continue
        address = address.split('%', 1)[0].strip('[]')
        require(address in ('0.0.0.0', '*', '::'), 'application socket is not wildcard-bound')
        owners = re.findall(r'pid=(\d+)', line)
        require(bool(owners), 'application listener ownership unavailable')
        for owner in owners:
            process = Path('/proc') / owner
            require(process.joinpath('cgroup').read_text() == group, 'listener belongs to another container/service')
            status = process.joinpath('status').read_text()
            for field in ('Uid', 'Gid'):
                ids = re.search(r'^' + field + r':\s+([0-9\s]+)$', status, re.M)
                require(ids and all(int(x) == 1000 for x in ids.group(1).split()), 'listener UID/GID differs from 1000:1000')
        if address in ('0.0.0.0', '*'):
            found = True
    require(found, 'expected external IPv4 Flatnotes listener is missing')
    require(service_value('NRestarts') == restarts and service_value('ActiveState') == 'active',
            'service changed during final runtime inspection')
    print('  Flatnotes: readiness, stable restarts, image, mount, UID/GID, secrets, listener, UFW and timezone verified.')

if __name__ == '__main__':
    try:
        main()
    except ValueError as exc:
        print('ERROR: Flatnotes verification: ' + str(exc), file=sys.stderr)
        raise SystemExit(1)
    except Exception:
        print('ERROR: Flatnotes verification could not complete; command arguments and configuration are omitted.', file=sys.stderr)
        raise SystemExit(1)
APP_CHECK
pct push "$CT_ID" "$tmp" /usr/local/sbin/flatnotes-check --perms 0755
rm -f -- "$tmp"

tmp=$(mktemp)
cat > "$tmp" <<'MAINT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C

# Generated with this application's creator; no shared runtime library.
APP_DIR=/opt/flatnotes
ENV_FILE=$APP_DIR/.env
UNIT_DIR=/etc/containers/systemd
MAIN_SERVICE=flatnotes.service
LOCK=/run/lock/flatnotes-maint.lock
GENERATOR=/usr/lib/systemd/system-generators/podman-system-generator
# Only temporary control-file copies are made. PBS/PVE owns data recovery.
# Atomic rename protects each file; this is not a multi-file disk transaction.
# The Quadlet and validated state must agree. No automatic state reconciliation.
# After the candidate starts, preserve it on failure; data may have changed.
WORK=""
SWITCHED=0
START_ATTEMPTED=0
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
    [[ ! ${STATE[$key]+yes} ]] || die "Duplicate state key."
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
  [[ ${STATE[FLATNOTES_PATH_PREFIX]:-} == "" || ${STATE[FLATNOTES_PATH_PREFIX]} =~ ^(/[A-Za-z0-9._~-]+)+$ ]] || die "Invalid path prefix."
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
    APP) CONTAINER=flatnotes ;;
    *) die "Unknown component." ;;
  esac
  SERVICE=$CONTAINER.service
  UNIT=$UNIT_DIR/$CONTAINER.container
}
valid_tag() {
  case $1 in
    APP) [[ $2 =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] ;;
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
verify_application() {
  /usr/local/sbin/flatnotes-check "$@"
}
validate_candidate() {
  local candidate=$1 old_contract new_contract
  # No production data, network or normal entrypoint during this compatibility probe.
  timeout 60 podman run --rm --pull=never --network none --read-only --user 1000:1000 \
    --entrypoint /bin/sh "$candidate" -ec 'test "$(id -u):$(id -g)" = 1000:1000; python3 -c "import os,time,json"'
  old_contract=$(podman image inspect --format '{{json .Config.User}} {{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$OLD_ID")
  new_contract=$(podman image inspect --format '{{json .Config.User}} {{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$candidate")
  [[ $old_contract == "$new_contract" ]] || die "Candidate USER/entrypoint/command changed; review compatibility."
}
finish() {
  local rc=$? restored=1
  trap - EXIT ERR INT TERM HUP
  set +e
  if (( rc != 0 && SWITCHED )); then
    if (( START_ATTEMPTED == 0 )); then
      copy_control_file "$WORK/old.container" "$UNIT" || restored=0
      copy_control_file "$WORK/old.env" "$ENV_FILE" || restored=0
      systemctl daemon-reload || restored=0
      (( restored )) && printf '  Previous control files restored before candidate startup.\n' >&2
    else
      restored=0
      printf '  Candidate image and data retained for inspection; no automatic downgrade.\n' >&2
      printf '  An image rollback cannot undo persistent data/index changes.\n' >&2
    fi
  fi
  if [[ -n $WORK ]]; then
    if (( restored )); then
      rm -rf -- "$WORK"
    else
      printf '  Prior control files retained at %s (not a data backup).\n' "$WORK" >&2
    fi
  fi
  exit "$rc"
}
trap finish EXIT
trap 'rc=$?; printf "  Maintenance failed: rc=%s line=%s; command arguments omitted.\n" "$rc" "$LINENO" >&2' ERR
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

update_application() {
  local target=${1:-} new_id answer
  select_component APP
  load_unit
  target=${target:-$OLD_TAG}
  valid_tag APP "$target" || die "Invalid target tag."
  [[ $(printf '%s\n%s\n' "$OLD_TAG" "$target" | sort -V | head -n 1) == "$OLD_TAG" ]] \
    || die "Downgrade requires a separate compatibility/data review."
  verify_application
  if (( YES == 0 )); then
    exec 8</dev/tty || die "Interactive terminal or --yes is required."
    [[ -t 8 ]] || die "Interactive terminal or --yes is required."
    printf '  Verify a matching PBS/PVE recovery checkpoint covering /opt/flatnotes first.\n'
    (( STATE[PODMAN_FUSE_OVERLAY] == 0 )) || printf '  FUSE is enabled: use reviewed stop-mode backups.\n'
    printf '  No automatic image downgrade after candidate startup.\n'
    read -r -p "  Update Flatnotes $OLD_TAG -> $target? [y/N]: " answer <&8 || die "Update prompt interrupted."
    [[ $answer =~ ^([Yy]|[Yy][Ee][Ss])$ ]] || return 0
  else
    printf '  --yes skips confirmation; no backup is created or verified.\n'
  fi
  podman pull "$REPO:$target"
  new_id=$(image_id "$REPO:$target") || die "Cannot resolve candidate image."
  if [[ $new_id == "$OLD_ID" && $target == "$OLD_TAG" ]]; then
    printf '  Pinned image unchanged; no restart.\n'
    return 0
  fi
  validate_candidate "$new_id"
  WORK=$(mktemp -d /run/flatnotes-update.XXXXXX)
  cp --preserve=mode,ownership "$UNIT" "$WORK/old.container"
  cp --preserve=mode,ownership "$ENV_FILE" "$WORK/old.env"
  SWITCHED=1
  write_unit "$target" "$REPO:$target" "$new_id"
  write_env "$target" "$REPO:$target" "$new_id"
  "$GENERATOR" --dryrun > "$WORK/generator.txt" 2> "$WORK/generator-errors.txt"
  grep -Fq 'flatnotes.service' "$WORK/generator.txt" || die "Generator omitted Flatnotes."
  systemctl daemon-reload
  [[ $(systemctl show "$SERVICE" -p LoadState --value) == loaded ]] || die "Unit did not load."
  if [[ $new_id != "$OLD_ID" ]]; then
    START_ATTEMPTED=1
    systemctl restart "$SERVICE"
  fi
  read_state
  verify_application
  SWITCHED=0; START_ATTEMPTED=0
  rm -rf -- "$WORK"; WORK=""
  printf '  Updated Flatnotes: %s (%s); complete application verification passed.\n' "$target" "$new_id"
  # Retain prior images. No pruning, data archives or application data restoration.
}

[[ $EUID == 0 ]] || die "Run as root inside the Flatnotes CT."
for command in podman systemctl awk sed sort head cat stat grep mktemp cp chmod mv rm flock timeout; do
  command -v "$command" >/dev/null || die "Missing required maintenance command."
done
[[ -f $ENV_FILE && ! -L $ENV_FILE && $(stat -c '%u:%g:%a' "$ENV_FILE") == 0:0:600 ]] \
  || die "Missing or unsafe application state file."
exec 9>"$LOCK"
flock -n 9 || die "Another maintenance operation is running."
cmd=${1:---help}
YES=0
case $cmd in
  check)
    { (( $# == 1 )) || { (( $# == 2 )) && [[ $2 == --initial ]]; }; } \
      || die "Usage: flatnotes-maint.sh check [--initial]"
    if [[ ${2:-} == --initial ]]; then verify_application --initial; else verify_application; fi
    ;;
  update)
    shift
    target=''
    for arg in "$@"; do
      case $arg in
        --yes|-y) (( YES == 0 )) || die "Duplicate confirmation flag."; YES=1 ;;
        *) [[ -z $target ]] && valid_tag APP "$arg" || die "Invalid update arguments."; target=$arg ;;
      esac
    done
    read_state
    update_application "$target"
    ;;
  auto-update)
    (( $# == 1 )) || die "auto-update takes no arguments."
    read_state
    [[ ${STATE[AUTO_UPDATE]} == 1 ]] || { printf '  Auto-update is disabled.\n'; exit 0; }
    YES=1
    update_application
    ;;
  version)
    (( $# == 1 )) || die "version takes no arguments."
    read_state; select_component APP; load_unit
    actual=$(podman inspect --format '{{.Image}}' flatnotes)
    actual=$(image_id "$actual") || die "Cannot resolve running image."
    printf '  Flatnotes\n    image: %s\n    configured ID: %s\n    running ID: %s\n' "$OLD_IMAGE" "$OLD_ID" "$actual"
    ;;
  --help|-h)
    (( $# <= 1 )) || die "Unexpected help arguments."
    printf 'Usage: %s update [tag] [--yes] | auto-update | check [--initial] | version\n' "$0"
    printf '  PBS/PVE owns data recovery; --yes does not create or verify a backup.\n'
    ;;
  *) die "Unknown maintenance command." ;;
esac
MAINT
pct push "$CT_ID" "$tmp" /usr/local/bin/flatnotes-maint.sh --perms 0755
rm -f -- "$tmp"

# ── Start via Quadlet ─────────────────────────────────────────────────────────
INSTALL_STAGE="Quadlet compatibility"
pct exec "$CT_ID" -- bash -s -- flatnotes <<'QUADLET_VALIDATE'
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
pct exec "$CT_ID" -- /usr/local/sbin/flatnotes-ufw-check
# Preserve the CT even if the first persistent start fails partway through.
INSTALL_STAGE="application startup"
CLEANUP_ON_FAIL=0
pct exec "$CT_ID" -- systemctl start flatnotes.service

# Destructive cleanup was disarmed before the first persistent service start.

# ── Initial application verification ─────────────────────────────────────────
INSTALL_STAGE="early application verification"
sleep 30
# Explicit, first-install-only exception; final and ordinary checks require policy.json.
pct exec "$CT_ID" -- env FLATNOTES_INSTALL_BOOTSTRAP=1 /usr/local/bin/flatnotes-maint.sh check --initial

# ── Auto-update timer (policy-driven) ─────────────────────────────────────────
pct exec "$CT_ID" -- bash -s -- "$UPDATE_TIME" <<'TIMER_INSTALL'
set -euo pipefail
cat > /etc/systemd/system/flatnotes-update.service <<EOF2
[Unit]
Description=flatnotes image maintenance
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/flatnotes-maint.sh auto-update
TimeoutStartSec=infinity
TimeoutStopSec=180
EOF2
cat > /etc/systemd/system/flatnotes-update.timer <<EOF2
[Unit]
Description=flatnotes daily image maintenance
[Timer]
OnCalendar=*-*-* $1:00
Persistent=true
[Install]
WantedBy=timers.target
EOF2
systemctl daemon-reload
TIMER_INSTALL
# Keep image updates disabled through all remaining installation checks.
pct exec "$CT_ID" -- systemctl disable --now flatnotes-update.timer

INSTALL_STAGE="package cleanup and MOTD"
# ── Extra packages ────────────────────────────────────────────────────────────
if [[ "${#EXTRA_PACKAGES[@]}" -gt 0 ]]; then
  pct exec "$CT_ID" -- bash -lc "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
    apt-get install -y ${EXTRA_PACKAGES[*]}
  "
fi

# ── Cleanup package cache ────────────────────────────────────────────────────
pct exec "$CT_ID" -- apt-get clean

# ── MOTD (dynamic drop-ins) ───────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -s <<'MOTD_INSTALL'
set -euo pipefail
mkdir -p /etc/update-motd.d
> /etc/motd
rm -f /etc/update-motd.d/*
cat > /etc/update-motd.d/00-header <<'MOTD_HEADER'
#!/bin/sh
printf '\n  Flatnotes (Podman/Quadlet)\n'
printf '  ────────────────────────────────────\n'
MOTD_HEADER
cat > /etc/update-motd.d/10-sysinfo <<'MOTD_SYSINFO'
#!/bin/sh
ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
printf '  Hostname:  %s\n' "$(hostname)"
printf '  IP:        %s\n' "${ip:-n/a}"
printf '  Uptime:    %s\n' "$(uptime -p 2>/dev/null || uptime)"
printf '  Disk:      %s\n' "$(df -h / | awk 'NR==2{printf "%s/%s (%s used)", $3, $2, $5}')"
MOTD_SYSINFO
cat > /etc/update-motd.d/30-app <<'MOTD_APP'
#!/bin/sh
svc=$(systemctl is-active flatnotes.service 2>/dev/null); svc=${svc:-unknown}
ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
port=$(sed -n 's/^APP_PORT=//p' /opt/flatnotes/.env)
prefix=$(sed -n 's/^FLATNOTES_PATH_PREFIX=//p' /opt/flatnotes/.env)
zone=$(sed -n 's/^APP_TZ=//p' /opt/flatnotes/.env)
auto=$(sed -n 's/^AUTO_UPDATE=//p' /opt/flatnotes/.env)
when=$(sed -n 's/^UPDATE_TIME=//p' /opt/flatnotes/.env)
printf '  Service:   flatnotes.service (%s)\n' "$svc"
printf '  Web UI:    http://%s:%s%s/\n' "${ip:-n/a}" "$port" "$prefix"
printf '  Timezone:  %s\n' "$zone"
printf '  Updates:   AUTO_UPDATE=%s | daily %s (%s)\n' "$auto" "$when" "$zone"
printf '  Data:      /opt/flatnotes/data (notes, attachments, search index)\n'
printf '  Secrets:   /opt/flatnotes/flatnotes.env (0600)\n'
printf '  State:     /opt/flatnotes/.env; source policy: /opt/flatnotes/access.json\n'
printf '  Quadlet:   /etc/containers/systemd/flatnotes.container\n'
printf '  Check:     /usr/local/bin/flatnotes-maint.sh check\n'
printf '  Version:   /usr/local/bin/flatnotes-maint.sh version\n'
printf '  Update:    /usr/local/bin/flatnotes-maint.sh update <tag>\n'
MOTD_APP
cat > /etc/update-motd.d/99-footer <<'MOTD_FOOTER'
#!/bin/sh
printf '  ────────────────────────────────────\n\n'
MOTD_FOOTER
chmod 0755 /etc/update-motd.d/{00-header,10-sysinfo,30-app,99-footer}
MOTD_INSTALL

# COMMON TERMINAL WRAPPER
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'
# END COMMON TERMINAL WRAPPER

# COMMON TIMEZONE PLAN RECHECK
TIMEZONE_PLAN_LATE=$(pct exec "$CT_ID" -- /usr/local/sbin/lab-timezone plan "$PRESERVE_EXISTING_TIMEZONE" "$SERVER_TIMEZONE")
[[ $TIMEZONE_PLAN == "$TIMEZONE_PLAN_LATE" ]] || {
  echo 'ERROR: Guest timezone changed since early planning; CT preserved.' >&2
  false
}
unset TIMEZONE_PLAN_LATE
# END COMMON TIMEZONE PLAN RECHECK

# COMMON HARDENING CALLER
INSTALL_STAGE="shared hardening"
CLEANUP_ON_FAIL=0
[[ $EUID == 0 && -d /etc/pve ]] || {
  echo 'ERROR: Shared hardening caller must be the verified Proxmox host.' >&2
  false
}
command -v pveversion >/dev/null
command -v pct >/dev/null
pveversion >/dev/null
[[ $CT_ID =~ ^[1-9][0-9]+$ ]] || {
  echo 'ERROR: Invalid selected CT_ID.' >&2
  false
}
pct status "$CT_ID" | grep -qx 'status: running'
pct config "$CT_ID" | grep -qx 'unprivileged: 1'
# A verified host login marker is not a guest SSH session.
unset SSH_CONNECTION
UFW_RULES_BEFORE=$(pct exec "$CT_ID" -- bash -s <<'UFW_SNAPSHOT_BEFORE'
set -euo pipefail
sha256sum /etc/ufw/{before,after,user}{,6}.rules
iptables -w 5 -S
ip6tables -w 5 -S
UFW_SNAPSHOT_BEFORE
)
# END COMMON HARDENING CALLER

# BEGIN CANONICAL HARDENING v1.2.0
#!/usr/bin/env bash
# ── Shared Debian 13 LXC hardening block ───────────────────────────────────────
# Version: 1.2.0 (2026-09-15; user-authorized LXC timezone adaptation)
# Base v1.1.2 SHA-256: ae2fa917d7dfe007c5f3700ea9d8c6686867a892d4323af2eb78c847092c3774
# Timezone policy source: debian-hardening.sh v1.0.3; native access code excluded.
# Guest-only /etc/localtime handling replaces the native timedated dependency.
# Timezone backups are observational; later failures have no automatic undo.
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
#   /etc/localtime; existing /etc/timezone (set mode only)
#   /usr/local/sbin/lab-timezone (plan/check read-only; apply internal)
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
SERVER_TIMEZONE="${SERVER_TIMEZONE-Europe/Berlin}"
PRESERVE_EXISTING_TIMEZONE="${PRESERVE_EXISTING_TIMEZONE-0}" # 0=set; 1=keep guest zone
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
  "$HARDENING_UDP_PORTS" "$PRESERVE_EXISTING_TIMEZONE" "$SERVER_TIMEZONE" <<'LAB_HARDENING_GUEST'
set -Eeuo pipefail
umask 022
export LC_ALL=C DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
PROFILE=$1 RP_FILTER=$2 KEEP_SSH=$3 REMOVE_POSTFIX=$4
JOURNAL_DAYS=$5 JOURNAL_MAX_MB=$6 JOURNAL_RUNTIME_MB=$7 UPDATE_MAX_AGE=$8
TCP_PORTS=$9 UDP_PORTS=${10}
PRESERVE_TIMEZONE=${11} REQUESTED_TIMEZONE=${12}
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
# Timezone policy is owned here, inside the verified LXC dispatch boundary.
# Validate and apply before package operations; preserve mode makes no timezone writes.
cat > "$stage/timezone.py" <<'TIMEZONE_HELPER'
#!/usr/bin/python3
"""LXC timezone policy, adapted from debian-hardening.sh v1.0.3.

Only apply writes timezone files; plan/check are read-only. No timedated,
clock, RTC, NTP, SSH, or access-recovery operations are performed.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from zoneinfo import ZoneInfo

ZONES = Path('/usr/share/zoneinfo')
LOCALTIME = Path('/etc/localtime')
TIMEZONE = Path('/etc/timezone')


def guest_guard():
    if os.geteuid() != 0 or shutil.which('pveversion') or Path('/etc/pve').exists():
        raise ValueError('Timezone operations require root inside the selected Debian 13 LXC.')
    release = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines()
                   if '=' in line and not line.startswith('#'))
    if release.get('ID', '').strip('"') != 'debian' or release.get('VERSION_ID', '').strip('"') != '13':
        raise ValueError('Timezone policy requires Debian 13.')
    result = subprocess.run(['systemd-detect-virt', '--container'], text=True,
                            capture_output=True, timeout=10)
    if result.returncode or result.stdout.strip() != 'lxc':
        raise ValueError('Timezone policy refuses environments other than LXC.')


def zone_path(name):
    # Same name grammar as the native source; validate against guest tzdata.
    if not re.fullmatch(r'[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+)*', name):
        raise ValueError('Invalid SERVER_TIMEZONE; use an installed IANA timezone name.')
    if name.split('/')[0] in ('posix', 'right', 'localtime', 'posixrules'):
        raise ValueError('SERVER_TIMEZONE must identify an IANA zone, not a special tzdata tree.')
    path = ZONES / name
    try:
        path.resolve(strict=True).relative_to(ZONES.resolve(strict=True))
        with path.open('rb') as stream:
            ZoneInfo.from_file(stream, key=name)
    except (OSError, ValueError) as exc:
        raise ValueError('Timezone is unavailable or invalid in this guest: ' + name) from exc
    return path


def effective_timezone():
    if not LOCALTIME.exists() and not LOCALTIME.is_symlink():
        zone_path('UTC')
        return 'UTC'  # localtime(5): absent /etc/localtime means UTC.
    if LOCALTIME.is_symlink():
        # Keep the selected alias, rather than resolving US/Eastern to another name.
        link = Path(os.path.normpath(LOCALTIME.parent / os.readlink(LOCALTIME)))
        try:
            name = str(link.relative_to(ZONES))
        except ValueError as exc:
            raise ValueError('/etc/localtime does not link into the guest zoneinfo tree.') from exc
        zone_path(name)
        return name
    if LOCALTIME.is_file() and TIMEZONE.is_file() and not TIMEZONE.is_symlink():
        name = TIMEZONE.read_text().strip()
        if LOCALTIME.read_bytes() == zone_path(name).read_bytes():
            return name
    raise ValueError('Cannot identify the guest timezone from /etc/localtime and /etc/timezone.')


def fingerprint(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return {'kind': 'absent'}
    if stat.S_ISLNK(info.st_mode):
        return {'kind': 'symlink', 'target': os.readlink(path)}
    if stat.S_ISREG(info.st_mode):
        return {'kind': 'file', 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    raise ValueError('Unsupported timezone file type: ' + str(path))


def fingerprints():
    return {str(path): fingerprint(path) for path in (LOCALTIME, TIMEZONE)}


def plan(preserve, requested):
    if preserve not in ('0', '1'):
        raise ValueError('PRESERVE_EXISTING_TIMEZONE must be exactly 0 or 1.')
    if preserve == '0':
        zone_path(requested)
        if TIMEZONE.is_symlink() or (TIMEZONE.exists() and not TIMEZONE.is_file()):
            raise ValueError('Refusing to replace a non-regular /etc/timezone.')
    before = effective_timezone()
    return {'preserve': preserve == '1', 'requested': None if preserve == '1' else requested,
            'before': before, 'effective': before if preserve == '1' else requested,
            'files_before': fingerprints()}


def verify(setting):
    actual = effective_timezone()
    if actual != setting['effective']:
        raise ValueError('Guest timezone drift: expected ' + setting['effective'] + ', found ' + actual)
    expected_files = setting.get('files', setting['files_before'])
    if fingerprints() != expected_files:
        raise ValueError('Guest timezone files changed; review /etc/localtime and /etc/timezone.')
    return actual


def apply(setting, backup):
    if fingerprints() != setting['files_before'] or effective_timezone() != setting['before']:
        raise ValueError('Guest timezone changed after validation; refusing to overwrite it.')
    if not setting['preserve']:
        target = zone_path(setting['requested'])
        saved = Path(backup) / 'timezone'
        saved.mkdir(mode=0o700, parents=True, exist_ok=False)
        (saved / 'before.json').write_text(json.dumps(setting, indent=2) + '\n')
        for path in (LOCALTIME, TIMEZONE):
            if path.exists() or path.is_symlink():
                shutil.copy2(path, saved / path.name, follow_symlinks=False)
        # Atomic per-file replacement; no automatic undo of a later failure.
        if setting['before'] != setting['requested']:
            with tempfile.TemporaryDirectory(prefix='.lab-timezone-', dir=LOCALTIME.parent) as tmp:
                replacement = Path(tmp) / 'localtime'
                replacement.symlink_to(target)
                os.replace(replacement, LOCALTIME)
        # Debian uses /etc/localtime. Keep an existing legacy file consistent;
        # do not introduce /etc/timezone when the template does not maintain it.
        desired = setting['requested'] + '\n'
        if TIMEZONE.exists() and TIMEZONE.read_text() != desired:
            with tempfile.TemporaryDirectory(prefix='.lab-timezone-', dir=TIMEZONE.parent) as tmp:
                replacement = Path(tmp) / 'timezone'
                replacement.write_text(desired)
                replacement.chmod(0o644)
                os.replace(replacement, TIMEZONE)
    final = {**setting, 'files': fingerprints()}
    if setting['preserve'] and final['files'] != setting['files_before']:
        raise ValueError('Preserve mode detected a timezone-file change.')
    verify(final)
    return final


def main():
    guest_guard()
    if len(sys.argv) == 4 and sys.argv[1] == 'plan':
        print(json.dumps(plan(sys.argv[2], sys.argv[3])))
    elif len(sys.argv) == 4 and sys.argv[1] == 'apply':
        setting = json.loads(Path(sys.argv[2]).read_text())
        print(json.dumps(apply(setting, sys.argv[3])))
    elif len(sys.argv) == 3 and sys.argv[1] == 'check':
        policy = json.loads(Path(sys.argv[2]).read_text())
        print(verify(policy['timezone']))
    else:
        raise ValueError('Invalid timezone helper arguments.')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print('ERROR: LXC timezone: ' + str(exc), file=sys.stderr)
        raise SystemExit(1)
TIMEZONE_HELPER
python3 "$stage/timezone.py" plan "$PRESERVE_TIMEZONE" "$REQUESTED_TIMEZONE" > "$stage/timezone-plan.json"
python3 "$stage/timezone.py" apply "$stage/timezone-plan.json" "$backup" > "$stage/timezone-policy.json"
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
install -m 0755 "$stage/timezone.py" "$stage/usr/local/sbin/lab-timezone"
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
timezone = None

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

    # Check selected zone and file identity without freezing tzdata database bytes.
    tz_result = subprocess.run(['/usr/local/sbin/lab-timezone', 'check', str(STATE / 'policy.json')],
                               text=True, capture_output=True, timeout=30)
    timezone = tz_result.stdout.strip() if tz_result.returncode == 0 else None
    require(tz_result.returncode == 0, 'Timezone policy verification failed: '
            + (tz_result.stderr.strip()[:1000] or 'see guest timezone files'))

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
          'warnings': warnings, 'external_listeners': listeners, 'timezone': timezone}
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
          'version': '1.2.0',
          'timezone': json.loads((stage / 'timezone-policy.json').read_text()),
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
effective_timezone=$(/usr/local/sbin/lab-timezone check /var/lib/lab-hardening/policy.json)
timezone_action=set; [[ $PRESERVE_TIMEZONE != 1 ]] || timezone_action=preserved
printf "Timezone: %s (%s; guest files verified).\n" "$effective_timezone" "$timezone_action"
printf '\nShared hardening applied (%s). Backups: %s\n' "$PROFILE" "$backup"
echo 'Manual check: /usr/local/sbin/lab-hardening-check'
echo 'Local reports: /var/lib/lab-hardening/status.json and journalctl -u lab-hardening-check'
echo 'Application image updates, source-specific UFW rules and app health remain with the creator.'
LAB_HARDENING_GUEST
)
# ── End shared hardening block ────────────────────────────────────────────────
# END CANONICAL HARDENING v1.2.0

# COMMON UFW PRESERVATION CHECK
INSTALL_STAGE="final verification"
UFW_RULES_AFTER=$(pct exec "$CT_ID" -- bash -s <<'UFW_SNAPSHOT_AFTER'
set -euo pipefail
sha256sum /etc/ufw/{before,after,user}{,6}.rules
iptables -w 5 -S
ip6tables -w 5 -S
UFW_SNAPSHOT_AFTER
)
[[ $UFW_RULES_BEFORE == "$UFW_RULES_AFTER" ]] || {
  echo 'ERROR: Persistent/effective UFW rules changed during hardening; CT preserved.' >&2
  false
}
unset UFW_RULES_BEFORE UFW_RULES_AFTER
# END COMMON UFW PRESERVATION CHECK

pct exec "$CT_ID" -- /usr/local/bin/flatnotes-maint.sh check --initial
pct exec "$CT_ID" -- /usr/local/sbin/lab-hardening-check
# COMMON FINAL TIMEZONE CHECK
EFFECTIVE_GUEST_TIMEZONE=$(pct exec "$CT_ID" -- /usr/local/sbin/lab-timezone check /var/lib/lab-hardening/policy.json)
[[ $EFFECTIVE_GUEST_TIMEZONE == "$APP_TZ" ]] || {
  echo 'ERROR: Planned application timezone differs from the final guest timezone; CT preserved.' >&2
  false
}
unset TIMEZONE_PLAN
# END COMMON FINAL TIMEZONE CHECK

HARDENING_STATUS=$(pct exec "$CT_ID" -- python3 -c 'import json; print(json.load(open("/var/lib/lab-hardening/status.json"))["status"])')
case $HARDENING_STATUS in
  OK|WARN) ;;
  *) echo 'ERROR: Final common hardening report failed; CT preserved.' >&2; false ;;
esac

INSTALL_STAGE="timer and protection"
pct exec "$CT_ID" -- bash -s -- "$AUTO_UPDATE" "$UPDATE_TIME" <<'TIMER_FINAL'
set -euo pipefail
systemctl daemon-reload
grep -qx "OnCalendar=\*-\*-\* $2:00" /etc/systemd/system/flatnotes-update.timer
grep -qx 'Persistent=true' /etc/systemd/system/flatnotes-update.timer
systemd-analyze calendar "*-*-* $2:00" >/dev/null
if [[ $1 == 1 ]]; then
  systemctl enable --now flatnotes-update.timer
  systemctl is-enabled --quiet flatnotes-update.timer
  systemctl is-active --quiet flatnotes-update.timer
  next=$(systemctl show flatnotes-update.timer -p NextElapseUSecRealtime --value)
  [[ -n $next && $next != 0 && $next != n/a ]]
else
  systemctl disable --now flatnotes-update.timer
  enabled=$(systemctl is-enabled flatnotes-update.timer) || [[ $? == 1 ]]
  active=$(systemctl is-active flatnotes-update.timer) || [[ $? == 3 ]]
  [[ $enabled == disabled && $active == inactive ]]
fi
calendar=$(systemctl show flatnotes-update.timer -p TimersCalendar --value)
[[ $calendar == *"OnCalendar=*-*-* $2:00"* ]]
systemctl show flatnotes-update.timer -p UnitFileState -p ActiveState -p TimersCalendar -p NextElapseUSecRealtime
TIMER_FINAL

# ── Proxmox UI description ────────────────────────────────────────────────────
FN_DESC_LINK="http://${CT_IP}:${APP_PORT}${APP_WEB_PATH}"
if [[ -n "$APP_FQDN" ]]; then
  FN_DESC_LINK="https://${APP_FQDN}${APP_WEB_PATH}"
fi
FN_DESC="<a href='${FN_DESC_LINK}' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Flatnotes</a>
<details><summary>Details</summary>Flatnotes (Podman/Quadlet) on Debian ${DEBIAN_VERSION} LXC
Auth: ${FLATNOTES_AUTH_TYPE} | Tag: ${APP_TAG}
Created by flatnotes-quadlet.sh</details>"
pct set "$CT_ID" --description "$FN_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1


# ── Summary ───────────────────────────────────────────────────────────────────
INSTALL_STAGE="summary"
CT_IPS=$(pct exec "$CT_ID" -- ip -o address show scope global | awk '{print $4}' | paste -sd ' ')
cat <<SUMMARY

  FLATNOTES

  Container:  $HN | CT $CT_ID | $CT_IPS
              Debian 13, unprivileged, protection enabled; root password set
              Console: pct enter $CT_ID | SSH preserved: $HARDENING_KEEP_SSH (no added SSH access)

  Access:     http://${CT_IP}:${APP_PORT}${APP_WEB_PATH}
              TCP $APP_PORT allowed from: $FIREWALL_ACCESS_LABEL
              Auth: $FLATNOTES_AUTH_TYPE | NPM upstream: http://${CT_IP}:${APP_PORT}
  Firewall:   UFW inside CT, IPv4/IPv6; no Proxmox firewall dependency
  Inventory:  TCP=${HARDENING_TCP_PORTS:-inventory-only}; UDP=${HARDENING_UDP_PORTS:-inventory-only}
              Inventory does not grant access. No backend listener is required.

  Timezone:   $EFFECTIVE_GUEST_TIMEZONE ($TIMEZONE_ACTION); guest and Flatnotes TZ/use verified
  Image:      $APP_IMAGE
              $APP_IMAGE_ID | Pull=never; default image entrypoint retained
  Files:      $QUADLET_FILE
              /opt/flatnotes/.env; /opt/flatnotes/access.json; /opt/flatnotes/timezone-plan.json
              /opt/flatnotes/flatnotes.env (credentials, 0600)
              /opt/flatnotes/data (notes, attachments and .flatnotes search index)

  Updates:    AUTO_UPDATE=$AUTO_UPDATE | daily $UPDATE_TIME in $EFFECTIVE_GUEST_TIMEZONE
              Debian unattended updates; no automatic reboot; needrestart report only
              Common verification after boot and hourly; final hardening: $HARDENING_STATUS (v1.2.0)
  Recovery:   Verify PBS/PVE coverage of the CT and all /opt/flatnotes state before updating.
              No external bind mount is created. Any later external mount needs its own backup.
              --yes creates/verifies no backup. No automatic image downgrade after candidate start.
              Image rollback cannot undo persistent data or search-index changes.

  Run on Proxmox:
    pct exec $CT_ID -- /usr/local/bin/flatnotes-maint.sh check
    pct exec $CT_ID -- /usr/local/bin/flatnotes-maint.sh version
    pct exec $CT_ID -- /usr/local/sbin/lab-hardening-check
  Run inside CT:
    /usr/local/bin/flatnotes-maint.sh check
    /usr/local/bin/flatnotes-maint.sh version
    /usr/local/bin/flatnotes-maint.sh update $APP_TAG
    /usr/local/sbin/lab-hardening-check
    journalctl -u flatnotes.service --no-pager -n 80

  Verification: application checks passed; six UFW files and both filter tables preserved.
                Common result: $HARDENING_STATUS. Review WARN entries in /var/lib/lab-hardening/status.json.
                Still required: client/proxy access, denied-source tests, DHCP renewal,
                reviewed reboot persistence and backup/restore acceptance.
SUMMARY
if [[ -n $APP_FQDN ]]; then
  printf '  Public URL (operator-configured proxy/DNS): https://%s%s\n' "$APP_FQDN" "$APP_WEB_PATH"
fi
if [[ $FLATNOTES_AUTH_TYPE == totp ]]; then
  # Explicit one-time enrollment output, never part of generic diagnostics or MOTD.
  printf '\n  TOTP enrollment key (store privately): %s\n' "$FLATNOTES_TOTP_MANUAL_KEY"
fi
unset FLATNOTES_TOTP_MANUAL_KEY FLATNOTES_USERNAME
if [[ $PODMAN_FUSE_OVERLAY == 1 ]]; then
  printf '  FUSE storage: use reviewed stop-mode backups; snapshot freezing can deadlock.\n'
fi
