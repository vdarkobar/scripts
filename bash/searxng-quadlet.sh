#!/usr/bin/env bash
set -Eeo pipefail
umask 022
export LC_ALL=C
# Safety revision: 2026-09-11. Fresh Proxmox CT creator; maintenance runs inside the CT.

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID=""                             # empty = auto-assign via pvesh; set e.g. CT_ID=120 to pin
HN="searxng"
CPU=2
RAM=3072
DISK=16
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# SearXNG / Podman + Quadlet
APP_PORT=8080                        # SearXNG binds this port on the CT interface (Network=host)
APP_TZ="Europe/Berlin"
APP_FQDN=""                          # e.g. search.example.com ; blank = local IP mode
                                     # set → base_url=https://FQDN/ and public_instance: true (link_token bot detection)
INSTANCE_NAME="SearXNG"              # shown in the web UI title and results page
TRUSTED_PROXIES=""                   # comma-separated CIDRs whose X-Forwarded-For is believed, e.g. "192.168.1.20/32"
                                     # blank = none (correct for direct LAN access). Required when APP_FQDN is set:
                                     # list ONLY the reverse proxy (NPM CT) — any host in a trusted range can
                                     # spoof X-Forwarded-For and pick its own rate-limit identity.
TAGS="searxng;podman;quadlet;lxc"

# Images / versions
# SearXNG: "latest" (default) follows upstream; to pin, use a date+commit tag
# from https://hub.docker.com/r/searxng/searxng/tags, e.g. 2026.4.13-ee66b070a.
APP_IMAGE_REPO="docker.io/searxng/searxng"
APP_TAG="latest"                     # "latest" or a pinned tag like 2026.4.13-ee66b070a
# Valkey is always deployed — the limiter requires it in both local and public mode.
VALKEY_IMAGE_REPO="docker.io/valkey/valkey"
VALKEY_TAG="9.0.5"                   # pinned cache sidecar per lab convention
DEBIAN_VERSION=13

# SearXNG settings.yml overrides
# Full reference: https://docs.searxng.org/admin/settings/settings.html
SEARCH_SAFE_SEARCH=0                 # 0 = off, 1 = moderate, 2 = strict
SEARCH_DEFAULT_LANG="auto"           # auto = detect from browser; or e.g. "en", "de", "all"
SEARCH_AUTOCOMPLETE=""               # blank = off; options: google, duckduckgo, brave, ...
ENABLE_IMAGE_PROXY=1                 # 1 = proxy images through SearXNG (uses memory)
OUTGOING_TIMEOUT=4.0                 # seconds before giving up on an upstream search engine
OUTGOING_MAX_TIMEOUT=10.0            # hard ceiling for upstream request timeouts

# Auto-update policy
# AUTO_UPDATE=1 (opt-in): searxng-update.timer re-pulls the CURRENT tags
#   (latest or pinned) daily at UPDATE_TIME and restarts only the services
#   whose image ID changed; recovery depends on persistent-state compatibility.
# AUTO_UPDATE=0 (default): timer installed but disabled; manual updates via
#   searxng-maint.sh update <tag> / update-valkey <tag> / auto-update
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
SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/searxng-quadlet.sh"
SCRIPT_LOCAL="/root/searxng-quadlet.sh"

# Derived
APP_DIR="/opt/searxng"
APP_IMAGE="${APP_IMAGE_REPO}:${APP_TAG}"
VALKEY_IMAGE="${VALKEY_IMAGE_REPO}:${VALKEY_TAG}"
QUADLET_FILE="/etc/containers/systemd/searxng.container"
QUADLET_SERVICE="searxng.service"
VALKEY_QUADLET_FILE="/etc/containers/systemd/searxng-valkey.container"
VALKEY_QUADLET_SERVICE="searxng-valkey.service"
# PUBLIC_INSTANCE controls only public_instance: in settings.yml (link_token bot
# detection for internet-facing instances). Valkey + limiter are always deployed.
PUBLIC_INSTANCE=0
[[ -n "$APP_FQDN" ]] && PUBLIC_INSTANCE=1

# ── Custom configs created by this script ─────────────────────────────────────
#   /usr/local/sbin/searxng-ufw-check                  (service-start firewall guard)
#   /etc/default/ufw, /etc/ufw/ufw.conf               (in-CT IPv4/IPv6 policy)
#   /etc/ufw/user.rules, /etc/ufw/user6.rules         (configured source allows)
#   /etc/containers/systemd/searxng.container         (Quadlet unit — source of truth)
#   /etc/containers/systemd/searxng-valkey.container  (Quadlet unit — limiter backend)
#   /opt/searxng/.env                                 (runtime state — read by maint script)
#   /opt/searxng/config/settings.yml                  (SearXNG configuration, contains secret_key)
#   /opt/searxng/config/limiter.toml                  (bot detection / trusted proxies)
#   /opt/searxng/cache/                               (favicon DB and SearXNG persistent cache)
#   /opt/searxng/valkey.conf                          (Valkey config — no persistence, loopback only)
#   /usr/local/bin/searxng-maint.sh                   (maintenance helper)
#   /etc/systemd/system/searxng-update.service
#   /etc/systemd/system/searxng-update.timer
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/sysctl.d/99-hardening.conf

# ── Config validation ─────────────────────────────────────────────────────────
[[ "$HN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || { echo "  ERROR: HN is not a valid hostname: $HN" >&2; exit 1; }
[[ "$CPU" =~ ^(0|[1-9][0-9]*)$ ]] && (( CPU >= 1 )) || { echo "  ERROR: CPU must be a positive integer." >&2; exit 1; }
[[ "$RAM" =~ ^(0|[1-9][0-9]*)$ ]] && (( RAM >= 256 )) || { echo "  ERROR: RAM must be >= 256 MB." >&2; exit 1; }
[[ "$DISK" =~ ^(0|[1-9][0-9]*)$ ]] && (( DISK >= 1 )) || { echo "  ERROR: DISK must be >= 1 GB." >&2; exit 1; }
[[ "$DEBIAN_VERSION" == 13 ]] || { echo "  ERROR: This creator requires Debian 13." >&2; exit 1; }
[[ "$APP_PORT" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "  ERROR: APP_PORT must be numeric." >&2; exit 1; }
(( APP_PORT >= 1024 && APP_PORT <= 65535 )) || { echo "  ERROR: APP_PORT must be between 1024 and 65535." >&2; exit 1; }
(( APP_PORT != 6379 )) || { echo "  ERROR: APP_PORT 6379 collides with Valkey on the shared host network." >&2; exit 1; }
[[ "$AUTO_UPDATE" =~ ^[01]$ ]] || { echo "  ERROR: AUTO_UPDATE must be 0 or 1." >&2; exit 1; }
[[ "$ENABLE_IMAGE_PROXY" =~ ^[01]$ ]] || { echo "  ERROR: ENABLE_IMAGE_PROXY must be 0 or 1." >&2; exit 1; }
[[ "$SEARCH_SAFE_SEARCH" =~ ^[012]$ ]] || { echo "  ERROR: SEARCH_SAFE_SEARCH must be 0, 1, or 2." >&2; exit 1; }
[[ "$PODMAN_FUSE_OVERLAY" =~ ^[01]$ ]] || { echo "  ERROR: PODMAN_FUSE_OVERLAY must be 0 or 1." >&2; exit 1; }
[[ "$CLEANUP_ON_FAIL" =~ ^[01]$ ]] || { echo "  ERROR: CLEANUP_ON_FAIL must be 0 or 1." >&2; exit 1; }
# Image repos are interpolated into podman, sed, the Quadlet units and .env.
[[ "$APP_IMAGE_REPO" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*[A-Za-z0-9]$ ]] || {
  echo "  ERROR: APP_IMAGE_REPO must look like registry/namespace/name (no tag, no spaces)." >&2
  exit 1
}
[[ "$VALKEY_IMAGE_REPO" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*[A-Za-z0-9]$ ]] || {
  echo "  ERROR: VALKEY_IMAGE_REPO must look like registry/namespace/name (no tag, no spaces)." >&2
  exit 1
}
# SearXNG: "latest" or a date+commit tag (2026.4.13-ee66b070a); a date tag
# without the commit suffix does not exist upstream.
[[ "$APP_TAG" == "latest" || "$APP_TAG" =~ ^[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}-[0-9a-f]{7,12}$ ]] || {
  echo "  ERROR: APP_TAG must be 'latest' or a SearXNG tag like 2026.4.13-ee66b070a." >&2
  exit 1
}
# Valkey: pinned full semver (9.0.5). Floating majors (9, 9.0) are rejected —
# they hide which line is running without the simplicity of "latest".
[[ "$VALKEY_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: VALKEY_TAG must be a pinned full version like 9.0.5 (floating tags like 9 are not accepted)." >&2
  exit 1
}
[[ "$UPDATE_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "  ERROR: UPDATE_TIME must be HH:MM (24h), e.g. 03:00." >&2; exit 1; }
[[ -e "/usr/share/zoneinfo/${APP_TZ}" ]] || { echo "  ERROR: APP_TZ not found in /usr/share/zoneinfo: $APP_TZ" >&2; exit 1; }
[[ "$APP_TZ" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)+$ ]] || { echo "  ERROR: APP_TZ contains invalid characters." >&2; exit 1; }
if [[ -n "$APP_FQDN" ]]; then
  [[ "$APP_FQDN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]] \
    || { echo "  ERROR: APP_FQDN is not a valid hostname: $APP_FQDN" >&2; exit 1; }
fi
# The following values land inside double-quoted YAML scalars in settings.yml.
[[ "$INSTANCE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]{0,63}$ ]] || {
  echo "  ERROR: INSTANCE_NAME must be 1-64 chars of letters, digits, spaces, dot, underscore or dash." >&2; exit 1;
}
[[ "$SEARCH_DEFAULT_LANG" =~ ^(auto|all|[a-z]{2,3}(-[A-Za-z0-9]{2,4})?)$ ]] || {
  echo "  ERROR: SEARCH_DEFAULT_LANG must be auto, all, or a language code like en / de / en-US." >&2; exit 1;
}
[[ -z "$SEARCH_AUTOCOMPLETE" || "$SEARCH_AUTOCOMPLETE" =~ ^[a-z0-9_]+$ ]] || {
  echo "  ERROR: SEARCH_AUTOCOMPLETE must be empty or a lowercase engine name (e.g. duckduckgo)." >&2; exit 1;
}
# TRUSTED_PROXIES is interpolated into limiter.toml as a TOML string array.
TRUSTED_PROXIES_TOML=""
if [[ -n "$TRUSTED_PROXIES" ]]; then
  IFS=',' read -r -a _tp_list <<< "$TRUSTED_PROXIES"
  for _tp in "${_tp_list[@]}"; do
    _tp="${_tp// /}"
    [[ -n "$_tp" ]] || continue
    [[ "$_tp" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ || "$_tp" =~ ^[0-9A-Fa-f:]+/[0-9]{1,3}$ ]] \
      || { echo "  ERROR: TRUSTED_PROXIES entry is not a CIDR (e.g. 192.168.1.20/32): $_tp" >&2; exit 1; }
    TRUSTED_PROXIES_TOML+="  \"${_tp}\","$'\n'
  done
  unset _tp _tp_list
fi
if [[ -n "$APP_FQDN" && -z "$TRUSTED_PROXIES_TOML" ]]; then
  echo "  ERROR: APP_FQDN is set (reverse-proxied) but TRUSTED_PROXIES is empty — set it to the proxy's CIDR," >&2
  echo "         otherwise every user is rate-limited as the proxy's IP." >&2
  exit 1
fi
[[ "$OUTGOING_TIMEOUT" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "  ERROR: OUTGOING_TIMEOUT must be a number (e.g. 4.0)." >&2; exit 1; }
[[ "$OUTGOING_MAX_TIMEOUT" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "  ERROR: OUTGOING_MAX_TIMEOUT must be a number (e.g. 10.0)." >&2; exit 1; }
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
exec 7>/run/lock/searxng-creator.lock
flock -n 7 || { echo "ERROR: Another searxng creator is running." >&2; exit 1; }

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

  SearXNG Quadlet LXC Creator — Configuration
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
  Valkey image:      $VALKEY_IMAGE (limiter backend, always deployed)
  App port:          $APP_PORT
  Instance name:     $INSTANCE_NAME
  Timezone:          $APP_TZ
  FQDN:              $([ -n "$APP_FQDN" ] && echo "$APP_FQDN" || echo "(no public FQDN — local IP mode)")
  public_instance:   $([ "$PUBLIC_INSTANCE" -eq 1 ] && echo "true (link_token bot detection)" || echo "false (local/private)")
  Trusted proxies:   ${TRUSTED_PROXIES:-(none — clients identified by connecting IP)}
  Safe search:       ${SEARCH_SAFE_SEARCH} (0=off, 1=moderate, 2=strict)
  Default language:  ${SEARCH_DEFAULT_LANG}
  Autocomplete:      ${SEARCH_AUTOCOMPLETE:-(disabled)}
  Image proxy:       $([ "$ENABLE_IMAGE_PROXY" -eq 1 ] && echo "enabled" || echo "disabled")
  Outgoing timeout:  ${OUTGOING_TIMEOUT}s / max ${OUTGOING_MAX_TIMEOUT}s
  Listens on:        0.0.0.0:${APP_PORT} inside the CT (Network=host) — access follows the UFW source choice below
                     Valkey on 127.0.0.1:6379 only (not reachable from the LAN)
  Podman storage:    $([ "$PODMAN_FUSE_OVERLAY" -eq 1 ] && echo "fuse-overlayfs (fuse=1)" || echo "native overlay (no FUSE)")
  Tags:              $TAGS
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled — daily at ${UPDATE_TIME} (re-pull $APP_TAG / $VALKEY_TAG)" || echo "disabled ($APP_TAG / $VALKEY_TAG, manual)")
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
      [[ ! -e $SCRIPT_LOCAL ]] || SCRIPT_LOCAL="/root/searxng-quadlet-downloaded.$$.sh"
      DOWNLOAD_TEMP=$(mktemp /root/searxng-download.XXXXXX)
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

# ── Generate secret key ───────────────────────────────────────────────────────
# server.secret_key signs SearXNG session/preference cookies. Written only to
# settings.yml (streamed over stdin, never in argv or .env).
set +o pipefail
SEARXNG_SECRET="$(head -c 4096 /dev/urandom | tr -dc 'a-f0-9' | head -c 64)"
set -o pipefail
[[ ${#SEARXNG_SECRET} -eq 64 ]] || { echo "  ERROR: Failed to generate SEARXNG_SECRET." >&2; exit 1; }

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
  apt-get install -y locales curl ca-certificates iproute2 python3 python3-yaml ufw iptables util-linux podman tar gzip ${PODMAN_FUSE_PKG}
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
pct push "$CT_ID" "$tmp" /usr/local/sbin/searxng-ufw-check --perms 0755
rm -f -- "$tmp"
pct exec "$CT_ID" -- /usr/local/sbin/searxng-ufw-check

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
echo "  Pulling SearXNG image: ${APP_IMAGE} ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman pull '${APP_IMAGE}'
"

echo "  Pulling Valkey image: ${VALKEY_IMAGE} ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman pull '${VALKEY_IMAGE}'
"


# ── Resolve immutable runtime images ──────────────────────────────────────────
for component in VALKEY APP; do
  reference_var=${component}_IMAGE
  resolved=$(pct exec "$CT_ID" -- podman image inspect --format '{{.Id}}' "${!reference_var}")
  resolved=${resolved#sha256:}
  [[ $resolved =~ ^[a-f0-9]{64}$ ]] || { echo "ERROR: Invalid image ID for $component." >&2; false; }
  printf -v "${component}_IMAGE_ID" 'sha256:%s' "$resolved"
done

# ── Prepare persistent paths ──────────────────────────────────────────────────
# SearXNG persistent state (all of it):
#   /opt/searxng/config/   settings.yml, limiter.toml  (→ /etc/searxng)
#   /opt/searxng/cache/    faviconcache.db, other persistent cache (→ /var/cache/searxng)
# The image entrypoint starts as root and, with FORCE_OWNERSHIP=true (image
# default), chowns both mounts to searxng:searxng before dropping privileges —
# no UID detection needed. Valkey has no persistent state here: it only holds
# rate-limit counters, RDB/AOF are disabled in valkey.conf, so no volume is mounted.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  install -d -m 0755 '${APP_DIR}'
  install -d -m 0755 '${APP_DIR}/config' '${APP_DIR}/cache'
"

# ── SearXNG settings.yml ──────────────────────────────────────────────────────
# use_default_settings: true — only the listed keys override upstream defaults.
# Streamed over stdin so secret_key never appears in host or CT argv.
# base_url: required when behind a reverse proxy (public FQDN); in local IP
# mode it stays false so SearXNG derives links from the request itself.
IMAGE_PROXY_YML=$([[ "$ENABLE_IMAGE_PROXY" -eq 1 ]] && echo "true" || echo "false")
PUBLIC_INSTANCE_YML=$([[ "$PUBLIC_INSTANCE" -eq 1 ]] && echo "true" || echo "false")
BASE_URL_YML="false"
[[ -n "$APP_FQDN" ]] && BASE_URL_YML="\"https://${APP_FQDN}/\""

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  umask 027
  cat > '${APP_DIR}/config/settings.yml'
  chmod 0640 '${APP_DIR}/config/settings.yml'
" <<SETTINGS
use_default_settings: true

general:
  instance_name: "${INSTANCE_NAME}"
  debug: false
  donation_url: false
  contact_url: false
  enable_metrics: true

search:
  safe_search: ${SEARCH_SAFE_SEARCH}
  autocomplete: "${SEARCH_AUTOCOMPLETE}"
  default_lang: "${SEARCH_DEFAULT_LANG}"
  formats:
    - html
    - json

server:
  secret_key: "${SEARXNG_SECRET}"
  bind_address: "0.0.0.0"
  port: ${APP_PORT}
  base_url: ${BASE_URL_YML}
  image_proxy: ${IMAGE_PROXY_YML}
  limiter: true
  public_instance: ${PUBLIC_INSTANCE_YML}
  method: "GET"
  default_http_headers:
    X-Content-Type-Options: nosniff
    X-Robots-Tag: "noindex, nofollow"
    Referrer-Policy: no-referrer

ui:
  query_in_title: false

outgoing:
  request_timeout: ${OUTGOING_TIMEOUT}
  max_request_timeout: ${OUTGOING_MAX_TIMEOUT}
  enable_http2: true
  useragent_suffix: ""

# Valkey runs on the shared host network stack (Network=host), loopback only.
valkey:
  url: valkey://127.0.0.1:6379/0

# Engines that require Tor log an ERROR on every startup of a non-Tor instance.
engines:
  - name: ahmia
    disabled: true
  - name: torch
    disabled: true
SETTINGS
unset SEARXNG_SECRET

# ── limiter.toml ──────────────────────────────────────────────────────────────
# Read by the limiter whenever it is enabled (always, here). Only overrides are
# listed; everything else inherits upstream defaults. trusted_proxies tells the
# botdetection to take the real client IP from X-Forwarded-For / X-Real-IP when
# the request comes from one of these ranges; headers from any other address
# are discarded. Trust only the reverse proxy, never whole LAN ranges (a
# trusted host can spoof the header). Empty for direct access.
# Note: SearXNG logs "X-Forwarded-For nor X-Real-IP header is set!" once per
# worker for the first header-less request (e.g. the /healthz probe) no matter
# what is configured here — it is informational, the connecting IP is used.
# Full reference: https://docs.searxng.org/admin/searx.limiter.html
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  umask 027
  cat > '${APP_DIR}/config/limiter.toml'
  chmod 0640 '${APP_DIR}/config/limiter.toml'
" <<LIMITER
[botdetection]
# Reverse proxies whose X-Forwarded-For / X-Real-IP headers are trusted.
# Empty = none: every client is identified by its own connecting address.
trusted_proxies = [
${TRUSTED_PROXIES_TOML}]
LIMITER

# ── Valkey config ─────────────────────────────────────────────────────────────
# Network=host means Valkey would otherwise listen on every CT interface; bind
# it to loopback. Persistence stays off: the limiter counters reset harmlessly
# on restart and nothing else lives in this DB.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > '${APP_DIR}/valkey.conf' <<EOF2
bind 127.0.0.1
port 6379
protected-mode yes
save \"\"
appendonly no
loglevel warning
maxmemory 128mb
maxmemory-policy allkeys-lru
EOF2
  chmod 0644 '${APP_DIR}/valkey.conf'
"

# ── Quadlet unit files ────────────────────────────────────────────────────────
# Rootful Quadlet: /etc/containers/systemd/ — no linger, no --user flags needed.
# systemd daemon-reload triggers the Quadlet generator; searxng.service and
# searxng-valkey.service are created as transient units and
# WantedBy=multi-user.target handles boot start.
# Network=host bypasses Netavark NAT issues on Debian LXC; SEARXNG_PORT tells
# the app which port to bind on the CT interface instead of PublishPort=.
# Both containers share the CT network stack, so SearXNG reaches Valkey on
# 127.0.0.1:6379. Requires=/After= order Valkey before SearXNG.
# No secrets in either unit file — secret_key lives in settings.yml (0640).
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  mkdir -p /etc/containers/systemd

  cat > '${VALKEY_QUADLET_FILE}' <<EOF2
[Unit]
Description=Valkey for SearXNG (limiter backend)
After=network-online.target
Wants=network-online.target

[Container]
# LabTag=${VALKEY_TAG}
# LabImage=${VALKEY_IMAGE}
Image=${VALKEY_IMAGE_ID}
Pull=never
ContainerName=searxng-valkey
Network=host
Exec=valkey-server /etc/valkey/valkey.conf
Volume=${APP_DIR}/valkey.conf:/etc/valkey/valkey.conf:ro
StopTimeout=20
HealthCmd=valkey-cli -h 127.0.0.1 ping
HealthInterval=10s
HealthTimeout=5s
HealthRetries=3
HealthStartPeriod=10s
Notify=healthy
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
Description=SearXNG
After=network-online.target ufw.service ${VALKEY_QUADLET_SERVICE}
Wants=network-online.target
Requires=ufw.service
Requires=${VALKEY_QUADLET_SERVICE}

[Container]
# LabTag=${APP_TAG}
# LabImage=${APP_IMAGE}
Image=${APP_IMAGE_ID}
Pull=never
ContainerName=searxng
Network=host
Environment=TZ=${APP_TZ}
Environment=SEARXNG_BIND_ADDRESS=0.0.0.0
Environment=SEARXNG_PORT=${APP_PORT}
Environment=FORCE_OWNERSHIP=true
Volume=${APP_DIR}/config:/etc/searxng
Volume=${APP_DIR}/cache:/var/cache/searxng
StopTimeout=50
LogDriver=journald

[Service]
ExecStartPre=/usr/local/sbin/searxng-ufw-check
Restart=always
RestartSec=5
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF2

  chmod 0644 '${VALKEY_QUADLET_FILE}' '${QUADLET_FILE}'
"

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
VALKEY_IMAGE_REPO=${VALKEY_IMAGE_REPO}
VALKEY_TAG=${VALKEY_TAG}
VALKEY_IMAGE=${VALKEY_IMAGE}
VALKEY_IMAGE_ID=${VALKEY_IMAGE_ID}
APP_PORT=${APP_PORT}
APP_TZ=${APP_TZ}
APP_FQDN=${APP_FQDN}
PUBLIC_INSTANCE=${PUBLIC_INSTANCE}
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
APP_DIR=/opt/searxng
ENV_FILE=$APP_DIR/.env
UNIT_DIR=/etc/containers/systemd
MAIN_SERVICE=searxng.service
LOCK=/run/lock/searxng-maint.lock
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
    VALKEY) CONTAINER=searxng-valkey; KIND=valkey; IMAGE_RECOVERY=1 ;;
    APP) CONTAINER=searxng; KIND=app; IMAGE_RECOVERY=0 ;;
    *) die "Unknown component: $COMPONENT" ;;
  esac
  SERVICE=$CONTAINER.service
  UNIT=$UNIT_DIR/$CONTAINER.container
}
valid_tag() {
  case $1 in
    VALKEY) [[ $2 =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] ;;
    APP) [[ $2 == latest || $2 =~ ^[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}-[0-9a-f]{7,12}$ ]] ;;
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
            "http://127.0.0.1:${STATE[APP_PORT]}/healthz") || code=000
          [[ $code =~ ^200$ ]] && value=1
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

}
pre_update_checks() {
python3 - "$APP_DIR/config/settings.yml" "$APP_DIR/config/limiter.toml" <<'CONFIG_CHECK'
import sys, yaml, tomllib
with open(sys.argv[1]) as f:
    config = yaml.safe_load(f)
if not isinstance(config, dict) or not isinstance(config.get("server"), dict):
    raise SystemExit("Invalid SearXNG settings mapping")
with open(sys.argv[2], "rb") as f:
    tomllib.load(f)
CONFIG_CHECK
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
        systemctl start "$MAIN_SERVICE" && wait_service searxng app "${STATE[UPDATE_WAIT_SECONDS]}" || restored=0
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
  /usr/local/sbin/searxng-ufw-check || die "Restore active UFW filtering before maintenance."
  actual=$(podman inspect --format '{{.Image}}' "$CONTAINER") || die "Cannot inspect running image."
  [[ $(image_id "$actual") == "$OLD_ID" ]] || die "Running/configured image mismatch; inspect the service."
  wait_service "$CONTAINER" "$KIND" 30 || die "$SERVICE is unhealthy before update."
  if [[ $COMPONENT != APP ]]; then
    wait_service searxng app 30 || die "Application is unhealthy before backend update."
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
  WORK=$(mktemp -d /run/searxng-update.XXXXXX)
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
      wait_service searxng app "${STATE[UPDATE_WAIT_SECONDS]}" || die "Application did not recover after backend update."
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

[[ $EUID == 0 ]] || die "Run as root inside the searxng CT."
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
  update|update-valkey)
    (( $# <= 2 )) || die "Usage: $0 $cmd [tag] [--yes]"
    if (( YES == 0 )); then
      exec 8</dev/tty || die "Interactive terminal or --yes is required."
    fi
    case $cmd in
      update-valkey) update_component VALKEY "${2:-}" ;;
      update) update_component APP "${2:-}" ;;
    esac
    ;;
  auto-update)
    (( $# == 1 )) || die "auto-update takes no tag."
    [[ ${STATE[AUTO_UPDATE]} == 1 ]] || { printf '  Auto-update is disabled.\n'; exit 0; }
    YES=1
    for component in VALKEY APP; do
      update_component "$component"
    done
    ;;
  check)
    (( $# <= 2 )) && [[ ${2:-} == "" || ${2:-} == --initial ]] || die "Usage: $0 check [--initial]"
    /usr/local/sbin/searxng-ufw-check
    budget=${STATE[UPDATE_WAIT_SECONDS]}
    [[ ${2:-} != --initial ]] || budget=${STATE[INITIAL_WAIT_SECONDS]}
    for component in VALKEY APP; do
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
    for component in VALKEY APP; do
      select_component "$component"; load_unit
      printf '  %s\n    tag: %s\n    configured ID: %s\n    running ID: ' "$CONTAINER" "$OLD_TAG" "$OLD_ID"
      podman inspect --format '{{.Image}}' "$CONTAINER" || true
    done
    ;;
  --help|-h|'')
    printf 'Usage: %s update [tag] [--yes] | update-valkey [tag] [--yes] | auto-update | check [--initial] | version\n' "$0"
    printf '  Exact image IDs; one component per operation; PBS/PVE handles data recovery.\n'
    printf '  Fresh-creator helper: do not replace an older deployed helper without migrating its control files.\n'
    ;;
  *) die "Unknown command: $cmd" ;;
esac
MAINT
pct push "$CT_ID" "$tmp" /usr/local/bin/searxng-maint.sh --perms 0755
rm -f -- "$tmp"

# ── Start via Quadlet ─────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -s -- searxng-valkey searxng <<'QUADLET_VALIDATE'
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
pct exec "$CT_ID" -- /usr/local/sbin/searxng-ufw-check
# Preserve the CT even if the first persistent start fails partway through.
CLEANUP_ON_FAIL=0
pct exec "$CT_ID" -- systemctl start searxng.service

# Destructive cleanup was disarmed before the first persistent service start.

# ── Verification ──────────────────────────────────────────────────────────────
sleep 30
if ! pct exec "$CT_ID" -- /usr/local/bin/searxng-maint.sh check --initial; then
  echo "ERROR: Initial readiness/image/firewall verification failed; CT $CT_ID is preserved." >&2
  exit 1
fi
VERIFY_FAIL=0

for svc in "$VALKEY_QUADLET_SERVICE" "$QUADLET_SERVICE"; do
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
    'podman ps --filter name=^searxng$ --filter name=^searxng-valkey$ --format "{{.Names}}" 2>/dev/null | wc -l' \
    2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge 2 ]] && break
  sleep 2
done
pct exec "$CT_ID" -- bash -lc 'podman ps' || true

if [[ "$RUNNING" -lt 2 ]]; then
  echo "  ERROR: Expected 2 containers running (searxng, searxng-valkey), found $RUNNING" >&2
  VERIFY_FAIL=1
else
  echo "  Container count OK ($RUNNING running)"
fi

VK_PONG="$(pct exec "$CT_ID" -- sh -lc 'podman exec searxng-valkey valkey-cli -h 127.0.0.1 ping 2>/dev/null' 2>/dev/null || true)"
if [[ "$VK_PONG" == "PONG" ]]; then
  echo "  Valkey responds on 127.0.0.1:6379 (PONG)"
else
  echo "  ERROR: Valkey did not answer PING on 127.0.0.1:6379" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u searxng-valkey.service --no-pager -n 50" >&2
  VERIFY_FAIL=1
fi

# /healthz is exempt from the limiter, so this probe is valid from inside the CT.
SX_HEALTHY=0
for i in $(seq 1 90); do
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc "curl -s -o /dev/null -w '%{http_code}' --max-time 3 'http://127.0.0.1:${APP_PORT}/healthz' 2>/dev/null" 2>/dev/null || echo 000)"
  case "$HTTP_CODE" in
    200)
      SX_HEALTHY=1
      break
      ;;
  esac
  sleep 2
done

if [[ "$SX_HEALTHY" -eq 1 ]]; then
  echo "  SearXNG health check passed (HTTP $HTTP_CODE)"
else
  echo "  ERROR: SearXNG /healthz did not return 200 on port ${APP_PORT}" >&2
  echo "  Check: pct exec $CT_ID -- systemctl status searxng.service" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u searxng.service --no-pager -n 80" >&2
  VERIFY_FAIL=1
fi

# In local mode SearXNG silently disables the limiter if Valkey is unreachable
# (only public_instance makes it fatal). Valkey is deployed on purpose, so a
# limiter/Valkey error in the startup log is a real failure here.
if pct exec "$CT_ID" -- sh -lc 'journalctl -u searxng.service --no-pager -o cat 2>/dev/null | grep -qiE "limiter requires (a )?valkey|searx\.valkeydb.*(error|refused)"' 2>/dev/null; then
  echo "  ERROR: SearXNG logged a limiter/Valkey connection error — rate limiting is not active" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u searxng.service --no-pager -n 80" >&2
  VERIFY_FAIL=1
else
  echo "  Limiter connected to Valkey (no connection errors in startup log)"
fi


if (( VERIFY_FAIL == 1 )); then
  echo "" >&2
  echo "  FATAL: Core verification failed — CT $CT_ID is preserved but the install is incomplete." >&2
  echo "  Inspect the container and fix manually, or destroy and re-run." >&2
  exit 1
fi

# ── Auto-update timer (policy-driven) ─────────────────────────────────────────
pct exec "$CT_ID" -- bash -s -- "$UPDATE_TIME" <<'TIMER_INSTALL'
set -euo pipefail
cat > /etc/systemd/system/searxng-update.service <<EOF2
[Unit]
Description=searxng image maintenance
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/searxng-maint.sh auto-update
TimeoutStartSec=infinity
TimeoutStopSec=180
EOF2
cat > /etc/systemd/system/searxng-update.timer <<EOF2
[Unit]
Description=searxng daily image maintenance
[Timer]
OnCalendar=*-*-* $1:00
Persistent=true
[Install]
WantedBy=timers.target
EOF2
systemctl daemon-reload
TIMER_INSTALL
if [[ $AUTO_UPDATE == 1 ]]; then
  pct exec "$CT_ID" -- systemctl enable --now searxng-update.timer
else
  pct exec "$CT_ID" -- systemctl disable --now searxng-update.timer
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
printf '\\n  SearXNG (Podman/Quadlet)\\n'
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
running=\$(podman ps --filter name=^searxng$ --filter name=^searxng-valkey$ --format '{{.Names}}' 2>/dev/null | wc -l)
svc_status=\$(systemctl is-active searxng.service 2>/dev/null); svc_status=\${svc_status:-unknown}
vk_status=\$(systemctl is-active searxng-valkey.service 2>/dev/null); vk_status=\${vk_status:-unknown}
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
image=\$(awk -F= '/^APP_IMAGE=/{print \$2}' /opt/searxng/.env 2>/dev/null | tail -n1)
vk_image=\$(awk -F= '/^VALKEY_IMAGE=/{print \$2}' /opt/searxng/.env 2>/dev/null | tail -n1)
auto=\$(awk -F= '/^AUTO_UPDATE=/{print \$2}' /opt/searxng/.env 2>/dev/null | tail -n1)
public=\$(awk -F= '/^PUBLIC_INSTANCE=/{print \$2}' /opt/searxng/.env 2>/dev/null | tail -n1)
fqdn=\$(awk -F= '/^APP_FQDN=/{print \$2}' /opt/searxng/.env 2>/dev/null | tail -n1)
port=\$(awk -F= '/^APP_PORT=/{print \$2}' /opt/searxng/.env 2>/dev/null | tail -n1)
port=\${port:-8080}
printf '  Containers: searxng + searxng-valkey (%s running)\\n' \"\$running\"
printf '  Services:   searxng.service (%s) | searxng-valkey.service (%s)\\n' \"\$svc_status\" \"\$vk_status\"
printf '  Image:      %s\\n' \"\${image:-n/a}\"
printf '  Valkey:     %s (127.0.0.1:6379, no persistence)\\n' \"\${vk_image:-n/a}\"
printf '  Mode:       %s\\n' \"\$([ \"\$public\" = '1' ] && echo 'public (limiter + link_token)' || echo 'local (limiter)')\"
printf '  Policy:     %s\\n' \"\$([ \"\$auto\" = '1' ] && echo 'auto-update daily (re-pull current tags)' || echo 'manual updates only')\"
printf '  Config:     /opt/searxng/config/settings.yml  limiter.toml\\n'
printf '  Cache:      /opt/searxng/cache\\n'
printf '  Logs:       journalctl -u searxng.service -f\\n'
printf '  Maintain:   /usr/local/bin/searxng-maint.sh [update|update-valkey|auto-update|version]\\n'
printf '  Updates:    systemctl status searxng-update.timer\\n'
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
SX_DESC_LINK="http://${CT_IP}:${APP_PORT}/"
SX_DESC_LABEL="SearXNG (local)"
if [[ -n "$APP_FQDN" ]]; then
  SX_DESC_LINK="https://${APP_FQDN}/"
  SX_DESC_LABEL="SearXNG (public)"
fi
SX_DESC="<a href='${SX_DESC_LINK}' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>${SX_DESC_LABEL}</a>
<details><summary>Details</summary>SearXNG (Podman/Quadlet) on Debian ${DEBIAN_VERSION} LXC
Tag: ${APP_TAG} | Valkey: ${VALKEY_TAG} | public_instance: $([ "$PUBLIC_INSTANCE" -eq 1 ] && echo true || echo false)
Created by searxng-quadlet.sh</details>"
pct set "$CT_ID" --description "$SX_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1


cat <<OPERATIONS

  SEARXNG — OPERATIONS

  CONTAINER     $HN | CT $CT_ID | $CT_IP
  WEB/ADMIN     http://$CT_IP:$APP_PORT/
  ALLOWED FROM  $FIREWALL_ACCESS_LABEL
  FIREWALL      UFW inside the CT, IPv4 and IPv6; no PVE firewall dependency
  AUTO-UPDATE   $AUTO_UPDATE | daily $UPDATE_TIME ($APP_TZ)
  IMAGES        exact local IDs, Pull=never; old images retained for review

  RUN ON THE PROXMOX HOST
    pct enter $CT_ID
    pct exec $CT_ID -- /usr/local/bin/searxng-maint.sh version

  RUN INSIDE THE CT
    /usr/local/bin/searxng-maint.sh check
    /usr/local/bin/searxng-maint.sh update $APP_TAG
    ufw status verbose
    journalctl -u searxng.service --no-pager -n 80

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
echo "    Image:   ${APP_IMAGE}"
echo "    Valkey:  ${VALKEY_IMAGE} (127.0.0.1:6379, limiter backend, no persistence)"
echo "    Mode:    $([ "$PUBLIC_INSTANCE" -eq 1 ] && echo "public (limiter + link_token bot detection)" || echo "local (limiter, no link_token)")"
echo "    Quadlet: ${QUADLET_FILE}"
echo "             ${VALKEY_QUADLET_FILE}"
echo "    Config:  ${APP_DIR}/config/settings.yml  (contains secret_key)"
echo "             ${APP_DIR}/config/limiter.toml  (trusted_proxies: ${TRUSTED_PROXIES:-none})"
echo "    Cache:   ${APP_DIR}/cache"
echo "    Policy:  $([ "$AUTO_UPDATE" -eq 1 ] && echo "auto-update daily at ${UPDATE_TIME} (re-pull ${APP_TAG} / ${VALKEY_TAG})" || echo "manual updates only (${APP_TAG} / ${VALKEY_TAG})")"
echo ""
echo "    pct exec $CT_ID -- systemctl status searxng.service"
echo "    pct exec $CT_ID -- journalctl -u searxng.service --no-pager -n 50"
echo "    pct exec $CT_ID -- /usr/local/bin/searxng-maint.sh update <tag>         # latest, or pin e.g. 2026.9.1-248e37991"
echo "    pct exec $CT_ID -- /usr/local/bin/searxng-maint.sh update-valkey <tag>  # latest, or pin e.g. 9.0.6"
echo "    pct exec $CT_ID -- /usr/local/bin/searxng-maint.sh auto-update          # re-pull current tags now (if AUTO_UPDATE=1)"
echo "    pct exec $CT_ID -- /usr/local/bin/searxng-maint.sh version"
echo "    Backup/restore: use PBS or PVE snapshots"
echo ""
echo "    NPM reverse proxy: http | ${CT_IP}:${APP_PORT} (no websockets needed)"
echo "    Port ${APP_PORT} listens on all CT interfaces (Network=host) — access follows the UFW source choice shown above."
echo "    Health probe (limiter-exempt): curl -sI http://${CT_IP}:${APP_PORT}/healthz"
echo "    JSON API is enabled (search.formats: json) — e.g. http://${CT_IP}:${APP_PORT}/search?q=test&format=json"
if [[ "$PUBLIC_INSTANCE" -eq 0 ]]; then
  echo "    Set APP_FQDN + TRUSTED_PROXIES=<npm-ct-ip>/32 to enable public_instance (link_token bot detection) when exposing this instance."
fi
echo "    Log line 'X-Forwarded-For nor X-Real-IP header is set' is logged once per worker for direct (non-proxied) requests — harmless."
echo "    Valkey logs a vm.overcommit_memory warning at start — harmless here (no RDB/AOF persistence); host sysctl is not touched."
if [[ "$PODMAN_FUSE_OVERLAY" -eq 1 ]]; then
  echo "    Backups: fuse=1 + fuse-overlayfs can deadlock under snapshot-mode vzdump/PBS (freezer)."
  echo "             Use stop-mode backups for this CT, or test PODMAN_FUSE_OVERLAY=0."
fi
echo "    To change settings: edit ${APP_DIR}/config/settings.yml then systemctl restart searxng.service"
echo ""
