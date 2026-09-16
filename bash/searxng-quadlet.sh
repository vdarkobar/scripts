#!/usr/bin/env bash
set -Eeo pipefail
umask 022
export LC_ALL=C
# Common-contract integration: 2026-09-16; contract 1.0.0.
# Fresh Proxmox Debian 13 unprivileged LXC creator; standalone and inline.
# Canonical hardening v1.2.0 is embedded unchanged (50,761 bytes), SHA-256:
# c1255455c38d2e3d95f25491664912513db437dfa20da8d6e62730eb951276b4
# SearXNG keeps its supplied release policy and image-derived startup contract.
# Static/isolated validation is documented separately; live acceptance is required.

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
# BEGIN COMMON TIMEZONE INPUTS
# COMMON TIMEZONE INPUTS
SERVER_TIMEZONE="${SERVER_TIMEZONE-Europe/Berlin}"
PRESERVE_EXISTING_TIMEZONE="${PRESERVE_EXISTING_TIMEZONE-0}"
APP_TZ=""
# END COMMON TIMEZONE INPUTS
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
#   searxng-maint.sh update <tag> / update-valkey <tag> (auto-update honors AUTO_UPDATE)
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
CLEANUP_ON_FAIL=0                    # preserve failed CTs for diagnosis (also disarmed before startup)


# Service verification and in-CT firewall
INITIAL_WAIT_SECONDS=180
UPDATE_WAIT_SECONDS=1800             # permit migrations; a timeout does not stop the app
# Bare IPs (192.168.1.20) or network CIDRs (192.168.1.0/24).
# Empty array prompts before CT creation; pressing Enter allows any source
# on APP_PORT (IPv4/IPv6). UFW stays enabled. Set client/NPM sources to restrict.
UFW_ALLOWED_SOURCES=()
SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/searxng-quadlet.sh"
SCRIPT_LOCAL="/root/searxng-quadlet.sh"

# Shared LXC hardening (the embedded block retains its own unchanged defaults)
HARDENING_PROFILE="lxc"              # Debian 13 service LXC; no forwarding
HARDENING_RP_FILTER=1                # 1=strict; 2=loose for asymmetric paths
HARDENING_KEEP_SSH=0                 # 0=remove SSH; 1=preserve, without opening UFW
HARDENING_REMOVE_POSTFIX=1           # 1=remove Postfix; 0=preserve intentional mail service
HARDENING_JOURNAL_DAYS=14
HARDENING_JOURNAL_MAX_MB=256
HARDENING_JOURNAL_RUNTIME_MB=64
HARDENING_UPDATE_MAX_AGE_HOURS=72
# Creator-only "auto" becomes the finalized APP_PORT before dispatch. For SSH
# preservation, supply its actual ports explicitly and review UFW separately.
# Final empty list = inventory-only for that protocol; these lists NEVER open UFW.
HARDENING_TCP_PORTS="auto"
HARDENING_UDP_PORTS="68 546"          # DHCPv4/DHCPv6, including scoped IPv6 sockets

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
#   /etc/localtime; existing /etc/timezone        (common timezone policy)
#   /usr/local/sbin/lab-timezone                  (LXC timezone plan/apply/check)
#   /usr/local/sbin/searxng-ufw-check                  (service-start firewall guard)
#   /usr/local/sbin/searxng-image-check                (isolated image compatibility probe)
#   /etc/default/ufw, /etc/ufw/ufw.conf               (in-CT IPv4/IPv6 policy)
#   /etc/ufw/user.rules, /etc/ufw/user6.rules         (configured source allows)
#   /etc/containers/systemd/searxng.container         (Quadlet unit — source of truth)
#   /etc/containers/systemd/searxng-valkey.container  (Quadlet unit — limiter backend)
#   /etc/containers/{storage,containers}.conf       (Podman storage/logging)
#   /etc/locale.gen, /etc/default/locale             (en_US.UTF-8)
#   /root/.bashrc                                    (terminal setting)
#   /etc/motd, /etc/update-motd.d/*                  (fresh-CT MOTD before hardening)
#   /run/lock/searxng-{creator,maint}.lock            (host/guest locks)
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
#   /opt/searxng/ufw-policy.json                     (selected sources/port for startup checks)
#   /etc/sysctl.d/99-hardening.conf                 (shared dual-stack policy)
#   /etc/apt/apt.conf.d/99-lab-hardening
#   /etc/needrestart/conf.d/99-lab-hardening.conf
#   /etc/systemd/journald.conf.d/99-lab-hardening.conf
#   /etc/systemd/system/apt-daily{,-upgrade}.service.d/90-lab-readiness.conf
#   /etc/systemd/system/lab-hardening-check.{service,timer}
#   /usr/local/sbin/lab-{apt-wait-online,hardening-check,postfix-check}
#   /etc/update-motd.d/25-lab-hardening
#   /etc/systemd/system/ssh.{service,socket}          (masks when SSH removed)
#   /etc/systemd/system/postfix*.{service,socket,path} (masks when Postfix removed)
#   /var/lib/lab-hardening/{policy.json,status.json,last-index-refresh,check.lock}
#   /var/backups/lab-hardening/<run>/                 (shared config backups/dry-run log)

# BEGIN COMMON CREATOR TRAPS
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
[[ $HARDENING_PROFILE == lxc ]] || { echo "ERROR: This creator requires HARDENING_PROFILE=lxc." >&2; exit 1; }
[[ $HARDENING_RP_FILTER =~ ^[12]$ && $HARDENING_KEEP_SSH =~ ^[01]$ && $HARDENING_REMOVE_POSTFIX =~ ^[01]$ ]] \
  || { echo "ERROR: Invalid hardening flag." >&2; exit 1; }
for policy_var in HARDENING_JOURNAL_DAYS HARDENING_JOURNAL_MAX_MB HARDENING_JOURNAL_RUNTIME_MB HARDENING_UPDATE_MAX_AGE_HOURS; do
  [[ ${!policy_var} =~ ^[1-9][0-9]{0,3}$ ]] || { echo "ERROR: $policy_var must be 1..9999." >&2; exit 1; }
done
for policy_var in HARDENING_TCP_PORTS HARDENING_UDP_PORTS; do
  [[ $policy_var != HARDENING_TCP_PORTS || ${!policy_var} != auto ]] || continue
  read -r -a policy_ports <<< "${!policy_var}"
  [[ ${!policy_var} != *$'\n'* && ${!policy_var} != *$'\r'* ]] || { echo "ERROR: $policy_var must be one line." >&2; exit 1; }
  for policy_port in "${policy_ports[@]}"; do
    [[ $policy_port =~ ^[1-9][0-9]{0,4}$ ]] && (( policy_port <= 65535 )) \
      || { echo "ERROR: $policy_var requires ports 1..65535, separated by spaces." >&2; exit 1; }
  done
done
if [[ $HARDENING_KEEP_SSH == 1 && $HARDENING_TCP_PORTS == auto ]]; then
  echo "ERROR: With SSH preserved, set HARDENING_TCP_PORTS explicitly (actual SSH and app ports, or empty for inventory). Review SSH UFW access separately." >&2
  exit 1
fi
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
# BEGIN COMMON TIMEZONE VALIDATION
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

# ── Preflight — root & commands ───────────────────────────────────────────────
INSTALL_STAGE="preflight"
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pveversion pvesh pveam pct pvesm qm curl python3 ip awk grep sed sort paste seq readlink cp chmod dpkg head tr flock mktemp mv rm tail bash stat timeout cat cut sleep; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

# Prove the caller is the Proxmox host before the unchanged block dispatches.
[[ -d /etc/pve ]] || { echo "ERROR: /etc/pve is absent; run on the Proxmox host." >&2; exit 1; }
pveversion >/dev/null

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
  [[ $CT_ID =~ ^[1-9][0-9]{2,8}$ ]] && (( CT_ID <= 999999999 )) \
    || { echo "  ERROR: Could not obtain a valid unused CT ID." >&2; exit 1; }
  if pct status "$CT_ID" >/dev/null 2>&1 || qm status "$CT_ID" >/dev/null 2>&1; then
    echo "  ERROR: Assigned CT ID is already in use." >&2
    exit 1
  fi
fi

# Creator scripts are not idempotent: a re-run would create a second CT with the
# same hostname. Refuse if one already exists on this node (e.g. a preserved
# failed install). Preserve it and choose a new, non-conflicting ID and HN.
EXISTING_CT="$(pct list 2>/dev/null | awk -v h="$HN" 'NR>1 && $NF==h {print $1}' | head -n1)"
if [[ -n "$EXISTING_CT" ]]; then
  echo "  ERROR: A CT with hostname '${HN}' already exists on this node (CT ${EXISTING_CT})." >&2
  echo "  Preserve that CT. For a fresh installation, select a new unused CT_ID and HN." >&2
  exit 1
fi

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
  Timezone:          $TIMEZONE_LABEL
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
  Cleanup on fail:   $CLEANUP_ON_FAIL (opt-in: only ordinary early failure; disarmed before app start)
  Interruptions:     INT/TERM/HUP and exit 129/130/143 always preserve CT and external data
  Hardening:         v1.2.0 | SSH keep=$HARDENING_KEEP_SSH | Postfix remove=$HARDENING_REMOVE_POSTFIX
  Listener policy:   TCP=$HARDENING_TCP_PORTS (auto=app port); UDP=$HARDENING_UDP_PORTS
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

response=""
read -r -p "  Continue with these settings? [y/N]: " response <&8 || {
  echo 'ERROR: Confirmation input interrupted.' >&2
  exit 1
}
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

# All prompts that can select app ports/sources have now completed.
FINALIZED_APP_TCP_PORTS=$APP_PORT
# BEGIN COMMON TCP RESOLUTION
# COMMON TCP RESOLUTION
[[ $HARDENING_TCP_PORTS != auto ]] || HARDENING_TCP_PORTS=$FINALIZED_APP_TCP_PORTS
# END COMMON TCP RESOLUTION
# Explicit and empty inventories are preserved; validate the final TCP result.
read -r -a policy_ports <<< "$HARDENING_TCP_PORTS"
[[ $HARDENING_TCP_PORTS != *$'\n'* && $HARDENING_TCP_PORTS != *$'\r'* ]] || exit 1
for policy_port in "${policy_ports[@]}"; do
  [[ $policy_port =~ ^[1-9][0-9]{0,4}$ ]] && (( policy_port <= 65535 )) \
    || { echo 'ERROR: Invalid finalized TCP listener inventory.' >&2; exit 1; }
done
# Validate actual proxy networks before creating the CT; access rules stay separate.
python3 - "$TRUSTED_PROXIES" <<'TRUST_VALIDATE'
import ipaddress, sys
try:
    for value in sys.argv[1].split(','):
        if value.strip():
            network = ipaddress.ip_network(value.strip(), strict=True)
            if network.network_address.is_multicast:
                raise ValueError('multicast proxy')
except ValueError:
    raise SystemExit('ERROR: TRUSTED_PROXIES requires valid network CIDRs without host bits.')
TRUST_VALIDATE

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

# ── Base packages and locale         ───────────────────────────────────────────
PODMAN_FUSE_PKG=""
[[ "$PODMAN_FUSE_OVERLAY" -eq 1 ]] && PODMAN_FUSE_PKG="fuse-overlayfs"

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  apt-get update -qq
  apt-get install -y tzdata locales curl ca-certificates iproute2 python3 python3-yaml ufw iptables util-linux podman tar gzip ${PODMAN_FUSE_PKG}
  sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
"

# ── Timezone planning before persistent application startup ──────────────────
# The helper bytes match the implementation embedded in the common block below.
# This early call installs the helper and READS a plan; only late hardening applies it.
INSTALL_STAGE="guest timezone validation"
pct exec "$CT_ID" -- bash -s <<'TIMEZONE_BOOTSTRAP'
set -euo pipefail
install -d -m 0755 /usr/local/sbin
[[ ! -L /usr/local/sbin/lab-timezone && ( ! -e /usr/local/sbin/lab-timezone || -f /usr/local/sbin/lab-timezone ) ]] || {
  echo 'ERROR: Refusing a symlink/nonregular timezone helper destination.' >&2
  exit 1
}
cat > /usr/local/sbin/lab-timezone <<'TIMEZONE_BOOTSTRAP_HELPER'
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
TIMEZONE_BOOTSTRAP_HELPER
chown root:root /usr/local/sbin/lab-timezone
chmod 0755 /usr/local/sbin/lab-timezone
TIMEZONE_BOOTSTRAP
# BEGIN COMMON EARLY TIMEZONE PLAN
# COMMON EARLY TIMEZONE PLAN
INSTALL_STAGE="guest timezone validation"
TIMEZONE_PLAN=$(pct exec "$CT_ID" -- /usr/local/sbin/lab-timezone plan "$PRESERVE_EXISTING_TIMEZONE" "$SERVER_TIMEZONE")
APP_TZ=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["effective"])' "$TIMEZONE_PLAN")
printf '  Guest timezone plan: %s (%s during shared hardening).\n' "$APP_TZ" "$TIMEZONE_ACTION"
# END COMMON EARLY TIMEZONE PLAN

# ── UFW inside the CT ─────────────────────────────────────────────────────────
# Fresh CT only. Network=host uses this CT's INPUT chain.
# Preserve existing before/after/user rules; no UFW reset.
INSTALL_STAGE="UFW setup"
pct exec "$CT_ID" -- bash -s -- "$APP_PORT" "${UFW_ALLOWED_SOURCES[@]}" <<'UFWSETUP'
set -euo pipefail
export LC_ALL=C
port=$1; shift
(( $# > 0 )) || { echo "ERROR: No allowed source addresses."; false; }
iptables -w 5 -S INPUT >/dev/null
ip6tables -w 5 -S INPUT >/dev/null
sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
grep -qx 'IPV6=yes' /etc/default/ufw
# The shared block owns sysctl hardening; avoid a second writer in ufw-init.
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
python3 - "$port" "$@" <<'UFW_SAVE_POLICY'
import json, os, pathlib, sys
path = pathlib.Path('/opt/searxng/ufw-policy.json')
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps({'port': int(sys.argv[1]), 'sources': sys.argv[2:]}) + '\n')
os.chmod(path, 0o644)
UFW_SAVE_POLICY
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
  "$tool" -w 5 -S OUTPUT | grep -qx -- '-P OUTPUT ACCEPT'
  for chain in INPUT FORWARD OUTPUT; do
    suffix=${chain,,}
    "$tool" -w 5 -C "$chain" -j "$prefix-before-$suffix"
  done
  "$tool" -w 5 -S "$prefix-user-input" >/dev/null
done
# Check the selected source allows on every boot and maintenance verification.
python3 - <<'UFW_CHECK_POLICY'
import ipaddress
import json
from pathlib import Path
import re
import shlex
import subprocess

def require(ok, message):
    if not ok:
        raise SystemExit('ERROR: SearXNG UFW: ' + message)

def capture(args):
    result = subprocess.run(args, text=True, capture_output=True, timeout=20)
    require(result.returncode == 0, 'cannot inspect selected rule/table')
    return result.stdout

def option(words, *names):
    found = [words[i + 1] for i, word in enumerate(words[:-1]) if word in names]
    require(len(found) <= 1, 'ambiguous rule option; review custom filtering')
    return found[0] if found else None

def port_matches(spec, port):
    if spec is None:
        return True
    for item in spec.split(','):
        bounds = item.split(':')
        require(len(bounds) <= 2 and all(x.isdecimal() for x in bounds),
                'unrecognized TCP port expression; review custom filtering')
        low, high = int(bounds[0]), int(bounds[-1])
        if low <= port <= high:
            return True
    return False

def persistent_with_policy_chain(persistent, effective, prefix):
    # ufw-init creates this chain; before/after/user.rules only reference it.
    # The persistent DEFAULT_INPUT_POLICY=DROP is checked by the caller.
    # Require the entire live chain to be exactly DROP, never trust its name.
    chain = prefix + '-skip-to-policy-input'
    rules = [shlex.split(line) for line in effective.splitlines()
             if line.startswith('-A ' + chain + ' ')]
    require(rules == [['-A', chain, '-j', 'DROP']],
            'generated input policy chain is missing or is not an unconditional DROP')
    for line in persistent.splitlines():
        words = shlex.split(line, comments=True)
        require(not words or not (words[0] == ':' + chain or
                (words[0] in ('-A', '-N', '-F', '-I', '-R', '-X') and
                 len(words) > 1 and words[1] == chain)),
                'persistent rules redefine the generated input policy chain')
    # In-memory audit model only: no firewall file/table is written or changed.
    return persistent + '\n:' + chain + ' - [0:0]\n-A ' + chain + ' -j DROP\n'

def audit(text, roots, allowed, port, family):
    chains = {}
    for line in text.splitlines():
        if line.startswith('-N '):
            chains.setdefault(shlex.split(line)[1], [])
        elif line.startswith(':'):
            chains.setdefault(line.split()[0][1:], [])
        if not line.startswith('-A '):
            continue
        words = shlex.split(line)
        chains.setdefault(words[1], []).append(words[2:])
    pending, visited = list(roots), set()
    while pending:
        chain = pending.pop()
        if chain in visited:
            continue
        visited.add(chain)
        for words in chains.get(chain, []):
            # Conservative policy proof for new TCP connections to this app.
            # Unsupported/negated paths fail closed instead of assuming isolation.
            negated = '!' in words
            proto = option(words, '-p', '--protocol')
            if not negated and proto in ('udp', '17', 'icmp', '1', 'ipv6-icmp', 'icmpv6', '58'):
                continue
            if not negated and option(words, '-i', '--in-interface') == 'lo':
                continue
            states = option(words, '--ctstate', '--state')
            if not negated and states and set(states.split(',')) <= {'RELATED', 'ESTABLISHED'}:
                continue
            ports = option(words, '--dport', '--destination-port', '--dports', '--destination-ports')
            if not negated and not port_matches(ports, port):
                continue
            target = option(words, '-j', '--jump', '-g', '--goto')
            if target in ('DROP', 'REJECT', 'RETURN', 'LOG', 'NFLOG', None):
                continue
            if target in chains:
                pending.append(target)
                continue
            require(target == 'ACCEPT', 'unrecognized reachable input target; review custom filtering')
            require(not negated, 'negated TCP access rule requires review')
            source = option(words, '-s', '--source') or ('0.0.0.0/0' if family == 4 else '::/0')
            network = ipaddress.ip_network(source, strict=False)
            require(any(network.subnet_of(entry) for entry in allowed),
                    'a persistent/effective rule permits broader app access than the selected sources')

try:
    policy = json.loads(Path('/opt/searxng/ufw-policy.json').read_text())
    require(type(policy['port']) is int and 1024 <= policy['port'] <= 65535 and policy['sources'],
            'invalid app port/source policy')
    networks = [ipaddress.ip_network(value, strict=True) for value in policy['sources']]
    defaults = Path('/etc/default/ufw').read_text()
    for key, expected in {'DEFAULT_INPUT_POLICY': 'DROP', 'DEFAULT_OUTPUT_POLICY': 'ACCEPT',
                          'DEFAULT_FORWARD_POLICY': 'DROP'}.items():
        values = re.findall(r'^' + key + r'=["\']?([A-Z]+)["\']?\s*$', defaults, re.M)
        require(values == [expected], 'persistent default policy differs: ' + key)
    for family, tool, prefix, suffix in ((4, '/usr/sbin/iptables', 'ufw', ''),
                                        (6, '/usr/sbin/ip6tables', 'ufw6', '6')):
        allowed = [network for network in networks if network.version == family]
        effective = capture([tool, '-w', '5', '-S'])
        persistent = '\n'.join(Path('/etc/ufw/' + stem + suffix + '.rules').read_text()
                               for stem in ('before', 'after', 'user'))
        persistent = persistent_with_policy_chain(persistent, effective, prefix)
        for source in allowed:
            # The exact selected allow must exist both now and after a reload.
            capture([tool, '-w', '5', '-C', prefix + '-user-input', '-s', str(source),
                     '-p', 'tcp', '-m', 'tcp', '--dport', str(policy['port']), '-j', 'ACCEPT'])
            present = False
            for line in persistent.splitlines():
                if not line.startswith('-A ' + prefix + '-user-input '):
                    continue
                words = shlex.split(line)[2:]
                rule_source = option(words, '-s', '--source') or ('0.0.0.0/0' if family == 4 else '::/0')
                if ('!' not in words and option(words, '-p', '--protocol') == 'tcp'
                        and option(words, '--dport', '--destination-port') == str(policy['port'])
                        and option(words, '-j', '--jump') == 'ACCEPT'
                        and ipaddress.ip_network(rule_source, strict=False) == source):
                    present = True
            require(present, 'selected source allow is missing from persistent rules')
        audit(effective, ['INPUT'], allowed, policy['port'], family)
        audit(persistent, [prefix + '-' + leaf + '-input'
                           for leaf in ('before', 'after', 'user', 'reject', 'track')],
              allowed, policy['port'], family)
except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as exc:
    # Do not print command arguments or rule/config contents on parsing failure.
    raise SystemExit('ERROR: SearXNG UFW inspection could not complete: ' + type(exc).__name__)
UFW_CHECK_POLICY
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
INSTALL_STAGE="image compatibility"
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
echo "  Resolved SearXNG image ID: $APP_IMAGE_ID"
echo "  Resolved Valkey image ID:  $VALKEY_IMAGE_ID"

# ── Selected-image initialization contract ────────────────────────────────────
# Source: searxng/searxng ca49650407a04cc0cc043759d5cb2cd2c92efd20,
# container/entrypoint.sh and dist.dockerfile; Granian 2.8.2 CLI/worker/socket code.
# Re-exercise the selected immutable image rather than trusting a moving tag.
pct exec "$CT_ID" -- bash -s <<'IMAGE_CHECK_INSTALL'
set -euo pipefail
cat > /usr/local/sbin/searxng-image-check <<'IMAGE_CHECK_HELPER'
#!/usr/bin/python3
"""Inspect an immutable image, then probe its initializer without application data."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid

PROBE = '''#!/usr/local/searxng/.venv/bin/python
import json
import os
from pathlib import Path
import sys

class ContractError(Exception):
    pass

def require(ok, message):
    if not ok:
        raise ContractError(message)

try:
    require(sys.argv[1:] == ['searx.webapp:app'], 'Unexpected Granian startup arguments')
    require(os.geteuid() != 0 and os.getegid() != 0, 'Initializer did not retain a non-root identity')
    from granian.cli import cli
    with cli.make_context('granian', sys.argv[1:], auto_envvar_prefix='GRANIAN') as context:
        options = context.params
    require(options['host'] == '0.0.0.0', 'Initializer/Granian did not retain the IPv4 bind')
    require(options['port'] == int(os.environ['SEARXNG_PORT']), 'Initializer/Granian port mismatch')
    require(getattr(options['interface'], 'value', options['interface']) == 'wsgi', 'Expected WSGI interface')
    require(not options.get('env_files'), 'Unreviewed worker environment files')
    require(not options.get('metrics_enabled'), 'Unreviewed metrics listener')
    require(not options.get('uds'), 'Unexpected Unix socket override')
    require(os.environ.get('__SEARXNG_CONFIG_PATH') == '/etc/searxng', 'Configuration path changed')
    require(os.environ.get('__SEARXNG_DATA_PATH') == '/var/cache/searxng', 'Data path changed')
    require(os.environ.get('__SEARXNG_SETTINGS_PATH') == '/etc/searxng/settings.yml', 'Settings path changed')
    for directory in ('/etc/searxng', '/var/cache/searxng'):
        info = Path(directory).stat()
        require((info.st_uid, info.st_gid) == (os.geteuid(), os.getegid()), 'Probe mount ownership mismatch')
        marker = Path(directory, '.lab-write-probe')
        marker.write_text('temporary compatibility probe')
        marker.unlink()
    require(os.access('/etc/searxng/settings.yml', os.R_OK), 'Initialized settings are unreadable')
    require(os.access('/usr/local/searxng/searx/webapp.py', os.R_OK), 'Application module is unreadable')
    print('LAB_SEARXNG_PROBE=' + json.dumps({'uid': os.geteuid(), 'gid': os.getegid(),
          'host': options['host'], 'port': options['port'], 'tz': os.environ.get('TZ')}))
except Exception as exc:
    detail = str(exc) if isinstance(exc, ContractError) else type(exc).__name__
    print('LAB_SEARXNG_PROBE_ERROR=' + detail)
    raise SystemExit(1)
'''

def diagnostic(step, stderr):
    if not stderr:
        return
    if isinstance(stderr, bytes):
        stderr = stderr.decode('utf-8', errors='replace')
    # Probe commands receive no production credentials or application data.
    # Keep useful engine errors, with bounded output and common secret fields redacted.
    stderr = re.sub(r'(?im)(\bauthorization\s*[:=]\s*)[^\r\n]+', r'\1<redacted>', stderr)
    stderr = re.sub(r'(?i)((?:password|passwd|secret(?:_key)?|token|authorization)\s*[:=]\s*)'
                    r'''(?:"[^"]*"|'[^']*'|[^\s,;]+)''', r'\1<redacted>', stderr)
    stderr = ''.join(char if char.isprintable() or char in '\n\t' else '?' for char in stderr)
    print('  ' + step + ' stderr:\n' + stderr[:4000].rstrip(), file=sys.stderr)
    if len(stderr) > 4000:
        print('  [remaining diagnostic truncated]', file=sys.stderr)

def run(args, *, step, timeout=60):
    try:
        result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        diagnostic(step, exc.stderr)
        raise RuntimeError(step + ' timed out after ' + str(timeout) + ' seconds') from None
    if result.returncode:
        diagnostic(step, result.stderr)
        # Application stdout is restricted to the generated probe's error marker.
        detail = next((line for line in result.stdout.splitlines()
                       if line.startswith('LAB_SEARXNG_PROBE_ERROR=')), '')
        raise RuntimeError(step + ' failed (rc=' + str(result.returncode)
                           + (', ' + detail if detail else '') + ')')
    return result.stdout.strip()

def main():
    if len(sys.argv) != 4 or not re.fullmatch(r'sha256:[a-f0-9]{64}', sys.argv[1]):
        raise ValueError('Usage: searxng-image-check sha256:IMAGE_ID PORT TIMEZONE')
    image, port_text, timezone = sys.argv[1:]
    port = int(port_text)
    if not 1024 <= port <= 65535:
        raise ValueError('Expected an unprivileged application port')
    info = json.loads(run(['podman', 'image', 'inspect', image], step='image metadata inspection'))
    if len(info) != 1:
        raise ValueError('Ambiguous image identity')
    config = info[0]['Config']
    if config.get('Entrypoint') != ['/usr/local/searxng/entrypoint.sh'] or config.get('Cmd'):
        raise ValueError('Unreviewed image entrypoint/CMD; inspect its startup contract')
    name = 'searxng-image-probe-' + uuid.uuid4().hex
    base = ['podman', 'run', '--rm', '--name', name, '--pull=never', '--network=none',
            '--user=searxng:searxng']
    try:
        identity = run(base + ['--entrypoint=/bin/sh', image, '-c', 'id -u; id -g'],
                       step='service-account inspection')
        if not re.fullmatch(r'[1-9][0-9]*\n[1-9][0-9]*', identity):
            raise ValueError('Image has no usable non-root searxng:searxng account')
        uid, gid = map(int, identity.splitlines())
        with tempfile.TemporaryDirectory(prefix='searxng-image-probe-', dir='/run') as tmp:
            # Instrument ONLY the temporary container's final Granian executable.
            # The real initializer and installed Granian parser run; no server/app
            # callback is invoked. Production keeps its unmodified image entrypoint.
            probe = Path(tmp, 'granian-probe')
            probe.write_text(PROBE)
            probe.chmod(0o555)
            os.chmod(tmp, 0o755)
            args = base + ['--env=TZ=' + timezone, '--env=GRANIAN_HOST=0.0.0.0',
                           '--env=SEARXNG_PORT=' + str(port), '--env=FORCE_OWNERSHIP=false',
                           '--volume=' + str(probe) + ':/usr/local/searxng/.venv/bin/granian:ro']
            # Podman 5.4.2 rejects uid=/gid= in --tmpfs options. Prepare owned
            # disposable bind directories instead, matching production mount semantics.
            for directory, leaf in (('/etc/searxng', 'config'), ('/var/cache/searxng', 'cache')):
                source = Path(tmp, leaf)
                source.mkdir(mode=0o755)
                os.chown(source, uid, gid)
                args += ['--volume=' + str(source) + ':' + directory + ':rw']
            output = run(args + [image], step='initializer/Granian probe')
            records = [line.removeprefix('LAB_SEARXNG_PROBE=') for line in output.splitlines()
                       if line.startswith('LAB_SEARXNG_PROBE=')]
            expected = dict(uid=uid, gid=gid, host='0.0.0.0', port=port, tz=timezone)
            if len(records) != 1 or json.loads(records[0]) != expected:
                raise ValueError('Initializer/Granian identity or environment contract changed')
    finally:
        # --rm handles success. This unique disposable name also covers timeouts;
        # neither installed service nor any production volume is targeted.
        subprocess.run(['podman', 'rm', '--force', '--ignore', name],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    print(str(uid) + ':' + str(gid))

if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print('ERROR: SearXNG image compatibility: ' + str(exc), file=sys.stderr)
        raise SystemExit(1)
IMAGE_CHECK_HELPER
chmod 0755 /usr/local/sbin/searxng-image-check
IMAGE_CHECK_INSTALL
APP_OWNER=$(pct exec "$CT_ID" -- /usr/local/sbin/searxng-image-check "$APP_IMAGE_ID" "$APP_PORT" "$APP_TZ")
[[ $APP_OWNER =~ ^[1-9][0-9]*:[1-9][0-9]*$ ]] || { echo "ERROR: Invalid SearXNG service identity." >&2; false; }
APP_UID=${APP_OWNER%%:*}
APP_GID=${APP_OWNER##*:}
echo "  SearXNG image initializer and Granian options verified; service UID:GID=$APP_OWNER"

# ── Prepare persistent paths ──────────────────────────────────────────────────
INSTALL_STAGE="application configuration"
# SearXNG persistent state (all of it):
#   /opt/searxng/config/   settings.yml, limiter.toml  (→ /etc/searxng)
#   /opt/searxng/cache/    faviconcache.db, other persistent cache (→ /var/cache/searxng)
# The inspected image entrypoint chowns files but does NOT drop privileges.
# Resolve its service account before startup, pre-own the mounts, and set
# Quadlet's container User/Group explicitly. Keep the image entrypoint intact.
# Valkey has no persistent state here: it only holds
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

# Fresh-CT paths only. Maintenance rejects an image UID/GID change before switch;
# it never recursively changes an existing deployment's data ownership.
pct exec "$CT_ID" -- chown -R -- "$APP_OWNER" "$APP_DIR/config" "$APP_DIR/cache"

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
# Rootful Quadlet: /etc/containers/systemd/ — no linger or user-systemd instance.
# [Container] User/Group selects the application identity inside the container.
# systemd daemon-reload triggers the Quadlet generator; searxng.service and
# searxng-valkey.service are created as transient units and
# WantedBy=multi-user.target handles boot start.
# Network=host bypasses Netavark NAT issues on Debian LXC; the image maps
# SEARXNG_PORT to GRANIAN_PORT. GRANIAN_HOST controls the production listener;
# settings.yml's bind_address/SEARXNG_BIND_ADDRESS affects the development server.
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
User=${APP_UID}
Group=${APP_GID}
Environment=TZ=${APP_TZ}
Environment=GRANIAN_HOST=0.0.0.0
Environment=SEARXNG_PORT=${APP_PORT}
Environment=FORCE_OWNERSHIP=false
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
TRUSTED_PROXIES=${TRUSTED_PROXIES}
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
  [[ ${STATE[APP_TZ]:-} =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || die "Invalid APP_TZ."
  [[ ${STATE[UPDATE_TIME]:-} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "Invalid UPDATE_TIME."
  [[ ${STATE[PUBLIC_INSTANCE]:-} =~ ^[01]$ ]] || die "Invalid PUBLIC_INSTANCE."
  for key in APP_PORT INITIAL_WAIT_SECONDS UPDATE_WAIT_SECONDS PODMAN_FUSE_OVERLAY AUTO_UPDATE; do
    [[ ${STATE[$key]:-} =~ ^(0|[1-9][0-9]{0,5})$ ]] || die "Invalid $key."
  done
  (( STATE[APP_PORT] >= 1024 && STATE[APP_PORT] <= 65535 )) || die "Invalid APP_PORT."
  (( STATE[INITIAL_WAIT_SECONDS] >= 30 && STATE[INITIAL_WAIT_SECONDS] <= 86400 )) || die "Invalid initial wait."
  (( STATE[UPDATE_WAIT_SECONDS] >= 30 && STATE[UPDATE_WAIT_SECONDS] <= 86400 )) || die "Invalid update wait."
  [[ ${STATE[AUTO_UPDATE]} =~ ^[01]$ && ${STATE[PODMAN_FUSE_OVERLAY]} =~ ^[01]$ ]] || die "Invalid policy flag."
  (( STATE[APP_PORT] != 6379 )) || die "Backend port collision."
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
          code=$(curl -sS -w '\n%{http_code}' --connect-timeout 2 --max-time 3 \
            "http://127.0.0.1:${STATE[APP_PORT]}/healthz") || code=""
          [[ $code == $'OK\n200' || $code == $'OK\n\n200' ]] && value=1
          ;;
        valkey)
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
  local id=$1 old_user new_user candidate_owner current_uid current_gid
  if [[ $COMPONENT == APP ]]; then
    candidate_owner=$(/usr/local/sbin/searxng-image-check "$id" "${STATE[APP_PORT]}" "${STATE[APP_TZ]}")
    current_uid=$(podman exec searxng id -u searxng)
    current_gid=$(podman exec searxng id -g searxng)
    [[ $candidate_owner == "$current_uid:$current_gid" ]] \
      || die "SearXNG image UID/GID changed; review ownership before updating. No image switch performed."
    return 0
  fi
  # Only the image shell runs, without network or data mounts. The candidate
  # application never gets production data during validation.
  podman run --rm --pull=never --network none --entrypoint /bin/sh "$id" -c true
  old_user=$(podman image inspect --format '{{.Config.User}}' "$OLD_ID")
  new_user=$(podman image inspect --format '{{.Config.User}}' "$id")
  [[ $old_user == "$new_user" ]] || die "Image USER changed; review ownership before updating."

}
runtime_checks() {
python3 - "${STATE[APP_PORT]}" "${STATE[APP_TZ]}" "${BOOTSTRAP_ALLOWED:-0}" "${STATE[APP_FQDN]}" "${STATE[PUBLIC_INSTANCE]}" "${STATE[TRUSTED_PROXIES]}" <<'RUNTIME_CHECK'
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tomllib
import yaml

class VerificationError(Exception):
    pass

def capture(args):
    result = subprocess.run(args, text=True, capture_output=True, timeout=20)
    if result.returncode:
        raise VerificationError('Inspection failed: ' + args[0] + ' (rc=' + str(result.returncode) + ')')
    return result.stdout.strip()

def require(ok, label):
    if not ok:
        raise VerificationError(label)

try:
    port = int(sys.argv[1])
    firewall = json.loads(Path('/opt/searxng/ufw-policy.json').read_text())
    require(firewall['port'] == port, 'Application and firewall ports disagree')
    # Only the creator's explicit initial invocation may precede common hardening.
    timezone_policy = Path('/var/lib/lab-hardening/policy.json')
    if timezone_policy.exists():
        policy = json.loads(timezone_policy.read_text())
        require(policy.get('version') == '1.2.0', 'Unexpected common hardening policy version')
        actual_timezone = capture(['/usr/local/sbin/lab-timezone', 'check', str(timezone_policy)])
        require(actual_timezone == sys.argv[2], 'SearXNG TZ differs from the effective guest timezone')
    else:
        require(sys.argv[3] == '1', 'Common hardening policy is missing; installation is incomplete')
    settings = yaml.safe_load(Path('/opt/searxng/config/settings.yml').read_text())
    server = settings['server']
    require(server.get('port') == port and server.get('bind_address') == '0.0.0.0',
            'SearXNG settings listener contract differs')
    require(server.get('limiter') is True and server.get('public_instance') is (sys.argv[5] == '1'),
            'SearXNG limiter/public-instance policy differs')
    expected_url = 'https://' + sys.argv[4] + '/' if sys.argv[4] else False
    require(server.get('base_url') == expected_url, 'SearXNG base URL differs')
    require(isinstance(server.get('secret_key'), str) and len(server['secret_key']) >= 32,
            'SearXNG secret is missing or malformed')
    require(settings.get('valkey', {}).get('url') == 'valkey://127.0.0.1:6379/0',
            'SearXNG Valkey endpoint differs')
    limiter = tomllib.loads(Path('/opt/searxng/config/limiter.toml').read_text())
    expected_proxies = {str(ipaddress.ip_network(x.strip(), strict=True))
                        for x in sys.argv[6].split(',') if x.strip()}
    actual_proxies = {str(ipaddress.ip_network(x, strict=True))
                      for x in limiter['botdetection']['trusted_proxies']}
    require(actual_proxies == expected_proxies and (not sys.argv[4] or bool(actual_proxies)),
            'Trusted-proxy policy differs from deployed state')
    # Inspect only the current service invocation; historical recovered errors
    # must not make observational maintenance fail forever.
    invocation = capture(['systemctl', 'show', 'searxng.service', '-p', 'InvocationID', '--value'])
    require(re.fullmatch(r'[a-f0-9]{32}', invocation), 'Missing SearXNG invocation identity')
    journal = capture(['journalctl', '_SYSTEMD_INVOCATION_ID=' + invocation,
                       '--no-pager', '-o', 'cat'])
    require(not re.search(r'limiter requires (a )?valkey|searx\.valkeydb.*(error|refused)', journal, re.I),
            'Current SearXNG invocation reports a limiter/Valkey failure')
    # Volatile cache recovery is valid only while RDB/AOF stay disabled.
    for key, expected in {'bind': '127.0.0.1', 'port': '6379', 'protected-mode': 'yes',
                          'save': '', 'appendonly': 'no', 'maxmemory': str(128 * 1024 * 1024),
                          'maxmemory-policy': 'allkeys-lru'}.items():
        result = capture(['podman', 'exec', 'searxng-valkey', 'valkey-cli', '--raw',
                          '-h', '127.0.0.1', 'CONFIG', 'GET', key]).splitlines()
        require(result == ([key, expected] if expected else [key]),
                'Valkey runtime configuration differs: ' + key)

    processes = {}
    for name, user, mounts, files in (
        ('searxng', 'searxng',
         {'/etc/searxng': '/opt/searxng/config', '/var/cache/searxng': '/opt/searxng/cache'},
         {'/etc/searxng/settings.yml': '/opt/searxng/config/settings.yml',
          '/etc/searxng/limiter.toml': '/opt/searxng/config/limiter.toml'}),
        ('searxng-valkey', 'valkey',
         {'/etc/valkey/valkey.conf': '/opt/searxng/valkey.conf'},
         {'/etc/valkey/valkey.conf': '/opt/searxng/valkey.conf'}),
    ):
        inspection = json.loads(capture(['podman', 'inspect', name]))
        require(len(inspection) == 1, name + ': ambiguous container identity')
        data = inspection[0]
        require(data['Name'].lstrip('/') == name and data['State']['Running'], name + ': not running')
        require(data['HostConfig']['NetworkMode'] == 'host', name + ': expected host networking')
        actual = {item['Destination']: item for item in data['Mounts']}
        for destination, source in mounts.items():
            item = actual.get(destination, {})
            require(item.get('Type') == 'bind' and item.get('Source') == source,
                    name + ': incorrect persistent/config mount ' + destination)
            require(item.get('RW') == (name == 'searxng'), name + ': wrong mount write access ' + destination)
        for destination, source in files.items():
            expected = hashlib.sha256(Path(source).read_bytes()).hexdigest()
            seen = capture(['podman', 'exec', name, 'sha256sum', destination]).split()[0]
            require(seen == expected, name + ': configuration delivery mismatch ' + destination)
        uid = int(capture(['podman', 'exec', name, 'id', '-u', user]))
        gid = int(capture(['podman', 'exec', name, 'id', '-g', user]))
        require(uid != 0, name + ': service account is root')
        rows = capture(['podman', 'top', name, 'hpid']).splitlines()
        require(rows and rows[0].strip() == 'HPID', name + ': unrecognized process inventory')
        pids = {int(row.strip()) for row in rows[1:]}
        require(pids, name + ': missing process inventory')
        owned = set()
        unexpected = []
        for pid in pids:
            try:
                status = Path('/proc', str(pid), 'status').read_text()
            except FileNotFoundError:
                continue
            values = re.search(r'^Uid:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)', status, re.M)
            groups = re.search(r'^Gid:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)', status, re.M)
            if values and groups and all(int(value) == uid for value in values.groups()) \
                    and all(int(value) == gid for value in groups.groups()):
                owned.add(pid)
            else:
                unexpected.append(str(pid) + ':UID=' + (values[2] if values else '?')
                                  + ':GID=' + (groups[2] if groups else '?'))
        require(not unexpected, name + ': expected every process to use UID:GID='
                + str(uid) + ':' + str(gid) + '; observed ' + ', '.join(unexpected))
        require(owned, name + ': no readable process running under the expected service UID/GID')
        processes[name] = owned
        if name == 'searxng':
            require(data['Config'].get('User') == str(uid) + ':' + str(gid),
                    'SearXNG container User/Group does not match its service account')
            for path in (*mounts.values(), *files.values()):
                info = Path(path).stat()
                require((info.st_uid, info.st_gid) == (uid, gid), 'SearXNG ownership mismatch: ' + path)
            require(Path('/opt/searxng/config/settings.yml').stat().st_mode & 0o007 == 0,
                    'SearXNG settings/secret readable by other users')
            require(data['Config'].get('Entrypoint') == ['/usr/local/searxng/entrypoint.sh'],
                    'SearXNG runtime entrypoint changed')
            environment = dict(item.split('=', 1) for item in data['Config']['Env'] if '=' in item)
            for key, expected in {'SEARXNG_PORT': str(port), 'GRANIAN_HOST': '0.0.0.0',
                                  'FORCE_OWNERSHIP': 'false', 'TZ': sys.argv[2]}.items():
                require(environment.get(key) == expected, 'SearXNG environment mismatch: ' + key)
            actual_tz = capture(['podman', 'exec', name, '/usr/local/searxng/.venv/bin/python', '-c',
                                 "import os,time; from datetime import datetime; from zoneinfo import ZoneInfo; "
                                 "assert datetime.now().astimezone().utcoffset() == datetime.now(ZoneInfo(os.environ['TZ'])).utcoffset(); "
                                 "print(os.environ['TZ'])"])
            require(actual_tz == sys.argv[2], 'SearXNG runtime timezone delivery/use mismatch')
        print('  Runtime identity: ' + name + ' UID:GID=' + str(uid) + ':' + str(gid)
              + '; mounts and configuration delivery verified.')

    seen = set()
    for line in capture(['ss', '-H', '-lntp']).splitlines():
        fields = line.split()
        require(len(fields) >= 4, 'Unrecognized TCP socket inventory')
        address, socket_port = fields[3].rsplit(':', 1)
        socket_port = int(socket_port)
        if socket_port not in (port, 6379):
            continue
        address = address.split('%', 1)[0].strip('[]')
        owners = {int(value) for value in re.findall(r'pid=(\d+)', line)}
        name = 'searxng' if socket_port == port else 'searxng-valkey'
        require(bool(owners & processes[name]), name + ': listener has no verified service process owner')
        if socket_port == 6379:
            require(ipaddress.ip_address(address).is_loopback, 'Valkey listener is exposed beyond loopback')
        else:
            require(address == '0.0.0.0', 'SearXNG listener is not on the configured IPv4 address')
        seen.add(socket_port)
    require(seen == {port, 6379}, 'Required SearXNG/Valkey listener missing')
    print('  TCP listener owners verified: SearXNG 0.0.0.0:' + str(port) + '; Valkey loopback:6379.')
except Exception as exc:
    detail = str(exc) if isinstance(exc, VerificationError) else type(exc).__name__
    print('ERROR: SearXNG runtime verification: ' + detail, file=sys.stderr)
    raise SystemExit(1)
RUNTIME_CHECK
}

# All three entry paths use this verifier under the same maintenance lock.
# Subshell locals keep verifier component selection out of update/recovery state.
verify_application() (
  trap - EXIT
  local initial=${1:-0} budget actual component container
  local -A restarts_before=()
  BOOTSTRAP_ALLOWED=0
  if [[ $initial == 1 && ${SEARXNG_CREATOR_BOOTSTRAP:-0} == 1 ]]; then
    BOOTSTRAP_ALLOWED=1
  fi
  /usr/local/sbin/searxng-ufw-check
  budget=${STATE[UPDATE_WAIT_SECONDS]}
  [[ $initial != 1 ]] || budget=${STATE[INITIAL_WAIT_SECONDS]}
  for container in searxng-valkey searxng; do
    restarts_before[$container]=$(systemctl show "$container.service" -p NRestarts --value)
    [[ ${restarts_before[$container]} =~ ^[0-9]+$ ]] || die "Missing restart inventory."
    [[ $initial != 1 || ${restarts_before[$container]} == 0 ]] || die "Unexpected initial restart."
  done
  for component in VALKEY APP; do
    select_component "$component"
    load_unit
    [[ $(unit_value 'Network=' "$UNIT") == host ]] || die "Expected host networking."
    [[ ${STATE[${component}_TAG]:-} == "$OLD_TAG" &&
       ${STATE[${component}_IMAGE]:-} == "$OLD_IMAGE" &&
       ${STATE[${component}_IMAGE_ID]:-} == "$OLD_ID" &&
       ${STATE[${component}_IMAGE_REPO]:-} == "$REPO" ]] || die "State/Quadlet metadata mismatch."
    if [[ $initial == 1 ]]; then
      [[ $(systemctl show "$SERVICE" -p NRestarts --value) == 0 ]] || die "$SERVICE restarted during initial startup."
    fi
    wait_service "$CONTAINER" "$KIND" "$budget" || die "$SERVICE failed readiness or restarted."
    actual=$(podman inspect --format '{{.Image}}' "$CONTAINER")
    [[ $(image_id "$actual") == "$OLD_ID" ]] || die "Running/configured image mismatch: $SERVICE"
  done
  runtime_checks
  for container in searxng-valkey searxng; do
    [[ $(systemctl show "$container.service" -p NRestarts --value) == "${restarts_before[$container]}" ]] \
      || die "Service restarted during application verification."
  done
  printf '  Readiness, stable restart counts, image IDs, mounts, ownership, sockets, timezone and UFW checks passed.\n'
)
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
      (( APP_STOPPED == 0 )) || printf '  Dependent application remains stopped; inspect backend readiness.\n' >&2
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
  /usr/local/sbin/searxng-ufw-check || die "UFW verification failed; inspect the selected access policy before maintenance."
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
  # Full baseline before any candidate sees production state.
  verify_application 0
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
    verify_application 0
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
  read_state
  verify_application 0
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
    [[ $# == 1 || ( $# == 2 && ${2:-} == --initial ) ]] || die "Usage: $0 check [--initial]"
    (( YES == 0 )) || die "check accepts only --initial."
    initial=0
    [[ ${2:-} != --initial ]] || initial=1
    verify_application "$initial"
    ;;
  version)
    (( $# == 1 && YES == 0 )) || die "version takes no argument."
    for component in VALKEY APP; do
      select_component "$component"; load_unit
      printf '  %s\n    tag: %s\n    configured ID: %s\n    running ID: ' "$CONTAINER" "$OLD_TAG" "$OLD_ID"
      podman inspect --format '{{.Image}}' "$CONTAINER" || true
    done
    ;;
  --help|-h|'')
    (( $# <= 1 && YES == 0 )) || die "help takes no arguments."
    printf 'Usage: %s update [tag] [--yes] | update-valkey [tag] [--yes] | auto-update | check [--initial] | version\n' "$0"
    printf '  Exact image IDs; one component per operation; PBS/PVE handles data recovery.\n'
    printf '  Fresh-creator helper: do not replace an older deployed helper without migrating its control files.\n'
    ;;
  *) die "Unknown maintenance command." ;;
esac
MAINT
pct push "$CT_ID" "$tmp" /usr/local/bin/searxng-maint.sh --perms 0755
rm -f -- "$tmp"

# ── Start via Quadlet ─────────────────────────────────────────────────────────
INSTALL_STAGE="Quadlet compatibility"
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
INSTALL_STAGE="application startup"
pct exec "$CT_ID" -- systemctl start searxng.service

# Destructive cleanup was disarmed before the first persistent service start.

# ── Early application readiness ───────────────────────────────────────────────
INSTALL_STAGE="early application verification"
sleep 30
# This one early call explicitly permits an absent common policy, only with --initial.
# No persistent bootstrap flag is written; final/manual/update checks require policy.
pct exec "$CT_ID" -- env SEARXNG_CREATOR_BOOTSTRAP=1 /usr/local/bin/searxng-maint.sh check --initial

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
# Installed definitions stay disabled/inactive until all final gates pass.
pct exec "$CT_ID" -- systemctl disable --now searxng-update.timer

# ── Extra packages ────────────────────────────────────────────────────────────
INSTALL_STAGE="package cleanup and MOTD"
if [[ "${#EXTRA_PACKAGES[@]}" -gt 0 ]]; then
  pct exec "$CT_ID" -- bash -lc "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
    apt-get install -y ${EXTRA_PACKAGES[*]}
  "
fi

# ── Cleanup packages ──────────────────────────────────────────────────────────
INSTALL_STAGE="package cleanup and MOTD"
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  apt-get purge -y man-db manpages
  apt-get -y clean
'

# ── MOTD (dynamic drop-ins) ───────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -s <<'MOTD_INSTALL'
set -euo pipefail
install -d -m 0755 /etc/update-motd.d
> /etc/motd
rm -f /etc/update-motd.d/*
cat > /etc/update-motd.d/00-header <<'MOTD_HEADER'
#!/bin/sh
printf '\n  SearXNG (Podman/Quadlet)\n'
printf '  ────────────────────────────────────\n'
MOTD_HEADER
# BEGIN COMMON MOTD SYSINFO
cat > /etc/update-motd.d/10-sysinfo <<'MOTD_SYSINFO'
#!/bin/sh
ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
printf '  Hostname:  %s\n' "$(hostname)"
printf '  IP:        %s\n' "${ip:-n/a}"
printf '  Uptime:    %s\n' "$(uptime -p 2>/dev/null || uptime)"
printf '  Disk:      %s\n' "$(df -h / | awk 'NR==2{printf "%s/%s (%s used)", $3, $2, $5}')"
MOTD_SYSINFO
# END COMMON MOTD SYSINFO
cat > /etc/update-motd.d/30-app <<'MOTD_APP'
#!/bin/sh
svc=$(systemctl is-active searxng.service 2>/dev/null); svc=${svc:-unknown}
vk=$(systemctl is-active searxng-valkey.service 2>/dev/null); vk=${vk:-unknown}
ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
port=$(awk -F= '$1=="APP_PORT"{print $2}' /opt/searxng/.env 2>/dev/null)
fqdn=$(awk -F= '$1=="APP_FQDN"{print $2}' /opt/searxng/.env 2>/dev/null)
auto=$(awk -F= '$1=="AUTO_UPDATE"{print $2}' /opt/searxng/.env 2>/dev/null)
schedule=$(awk -F= '$1=="UPDATE_TIME"{print $2}' /opt/searxng/.env 2>/dev/null)
zone=$(awk -F= '$1=="APP_TZ"{print $2}' /opt/searxng/.env 2>/dev/null)
printf '  Services:   SearXNG %s | Valkey %s\n' "$svc" "$vk"
printf '  Web UI:     http://%s:%s/\n' "${ip:-n/a}" "${port:-n/a}"
[ -z "$fqdn" ] || printf '  Public URL: https://%s/\n' "$fqdn"
printf '  Backend:    Valkey 127.0.0.1:6379 (no persistence)\n'
printf '  Images:     /etc/containers/systemd/searxng{,-valkey}.container\n'
printf '  Config:     /opt/searxng/config/settings.yml (secret), limiter.toml\n'
printf '  State:      /opt/searxng/.env | Cache: /opt/searxng/cache\n'
printf '  Updates:    AUTO_UPDATE=%s | daily %s (%s)\n' "${auto:-n/a}" "${schedule:-n/a}" "${zone:-n/a}"
printf '  Check:      /usr/local/bin/searxng-maint.sh check\n'
printf '  Version:    /usr/local/bin/searxng-maint.sh version\n'
printf '  Logs:       journalctl -u searxng.service -u searxng-valkey.service\n'
MOTD_APP
# BEGIN COMMON MOTD FOOTER
cat > /etc/update-motd.d/99-footer <<'MOTD_FOOTER'
#!/bin/sh
printf '  ────────────────────────────────────\n\n'
MOTD_FOOTER
# END COMMON MOTD FOOTER
chmod 0755 /etc/update-motd.d/{00-header,10-sysinfo,30-app,99-footer}
MOTD_INSTALL

# BEGIN COMMON TERMINAL WRAPPER
# COMMON TERMINAL WRAPPER
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'
# END COMMON TERMINAL WRAPPER

# BEGIN COMMON TIMEZONE PLAN RECHECK
# COMMON TIMEZONE PLAN RECHECK
TIMEZONE_PLAN_LATE=$(pct exec "$CT_ID" -- /usr/local/sbin/lab-timezone plan "$PRESERVE_EXISTING_TIMEZONE" "$SERVER_TIMEZONE")
[[ $TIMEZONE_PLAN == "$TIMEZONE_PLAN_LATE" ]] || {
  echo 'ERROR: Guest timezone changed since early planning; CT preserved.' >&2
  false
}
unset TIMEZONE_PLAN_LATE
# END COMMON TIMEZONE PLAN RECHECK

# BEGIN COMMON HARDENING CALLER
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

# BEGIN LAB HARDENING v1.2.0 (byte-for-byte canonical standalone)
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
# END LAB HARDENING v1.2.0

# BEGIN COMMON UFW PRESERVATION CHECK
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
pct exec "$CT_ID" -- /usr/local/bin/searxng-maint.sh check --initial
pct exec "$CT_ID" -- /usr/local/sbin/lab-hardening-check
# BEGIN COMMON FINAL TIMEZONE CHECK
# COMMON FINAL TIMEZONE CHECK
EFFECTIVE_GUEST_TIMEZONE=$(pct exec "$CT_ID" -- /usr/local/sbin/lab-timezone check /var/lib/lab-hardening/policy.json)
[[ $EFFECTIVE_GUEST_TIMEZONE == "$APP_TZ" ]] || {
  echo 'ERROR: Planned application timezone differs from the final guest timezone; CT preserved.' >&2
  false
}
unset TIMEZONE_PLAN
# END COMMON FINAL TIMEZONE CHECK
HARDENING_RESULT=$(pct exec "$CT_ID" -- python3 -c 'import json; p=json.load(open("/var/lib/lab-hardening/status.json")); assert p["status"] in ("OK", "WARN"); print(p["status"])')
echo "  Final application checks and persistent/effective IPv4/IPv6 UFW preservation passed."

# ── Activate the image timer only after all final verification gates ──────────
INSTALL_STAGE="timer and protection"
pct exec "$CT_ID" -- bash -s -- "$AUTO_UPDATE" "$UPDATE_TIME" "$APP_TZ" <<'TIMER_FINAL'
set -euo pipefail
policy=$1 schedule=$2 zone=$3
[[ $(/usr/local/sbin/lab-timezone check /var/lib/lab-hardening/policy.json) == "$zone" ]]
systemctl daemon-reload
if [[ $policy == 1 ]]; then
  systemctl enable --now searxng-update.timer
else
  systemctl disable --now searxng-update.timer
fi
python3 - "$policy" "$schedule" <<'TIMER_VERIFY'
from pathlib import Path
import re, subprocess, sys

def require(ok, message):
    if not ok:
        raise SystemExit('ERROR: Image timer: ' + message)

text = Path('/etc/systemd/system/searxng-update.timer').read_text()
calendar = '*-*-* ' + sys.argv[2] + ':00'
require(re.findall(r'^OnCalendar=(.*)$', text, re.M) == [calendar], 'installed calendar differs')
require(re.findall(r'^Persistent=(.*)$', text, re.M) == ['true'], 'persistence differs')
result = subprocess.run(['systemctl', 'show', 'searxng-update.timer',
                         '-p', 'TimersCalendar', '-p', 'NextElapseUSecRealtime',
                         '-p', 'UnitFileState', '-p', 'ActiveState', '-p', 'Persistent',
                         '-p', 'Unit'], text=True, capture_output=True, timeout=20)
require(result.returncode == 0, 'cannot inspect effective timer')
data = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
effective = re.findall(r'OnCalendar=(.*?)\s*;', data.get('TimersCalendar', ''))
require(effective == [calendar], 'effective calendar differs')
require(data.get('Persistent') == 'yes', 'effective persistence differs')
require(data.get('Unit') == 'searxng-update.service', 'wrong target service')
enabled = sys.argv[1] == '1'
require(data.get('UnitFileState') == ('enabled' if enabled else 'disabled'), 'enabled state differs')
require(data.get('ActiveState') == ('active' if enabled else 'inactive'), 'active state differs')
next_run = data.get('NextElapseUSecRealtime', '')
require(not enabled or next_run not in ('', 'n/a', '0'), 'enabled timer has no next elapse')
print('  Image timer: ' + ('enabled/active' if enabled else 'disabled/inactive')
      + '; daily ' + sys.argv[2] + '; next: ' + (next_run or 'n/a'))
TIMER_VERIFY
TIMER_FINAL

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
# BEGIN COMMON PROTECTION
pct set "$CT_ID" --protection 1
# END COMMON PROTECTION
pct config "$CT_ID" | grep -qx 'protection: 1'

# ── Summary ───────────────────────────────────────────────────────────────────
INSTALL_STAGE="summary"
CT_ADDRESSES=$(pct exec "$CT_ID" -- ip -o addr show scope global | awk '{print $4}' | paste -sd ' ')
SSH_LABEL='removed; service/socket masked'
[[ $HARDENING_KEEP_SSH == 0 ]] || SSH_LABEL='preserved; UFW access is a separate policy'
IMAGE_TIMER_LABEL='disabled/inactive'
[[ $AUTO_UPDATE == 0 ]] || IMAGE_TIMER_LABEL='enabled/active'
cat <<SUMMARY

  SEARXNG — VERIFIED INSTALLATION

  CONTAINER
    $HN | CT $CT_ID | $CT_ADDRESSES
    Debian 13 | unprivileged | protection enabled
    Root password set; console via pct enter; no autologin configured.
    SSH: $SSH_LABEL

  ACCESS
    Local: http://$CT_IP:$APP_PORT/
    Public FQDN: ${APP_FQDN:-(not configured)}
    TCP $APP_PORT allowed sources: $FIREWALL_ACCESS_LABEL
    Trusted proxies: ${TRUSTED_PROXIES:-(none; connecting IP identifies clients)}
    Valkey: 127.0.0.1:6379 only; volatile limiter counters.

  FIREWALL
    UFW inside CT, IPv4/IPv6; no Proxmox firewall dependency.
    Six rule files and both complete effective filter tables preserved across hardening.
    Listener inventory (does not grant access):
      TCP: ${HARDENING_TCP_PORTS:-(inventory-only)}
      UDP: ${HARDENING_UDP_PORTS:-(inventory-only)}

  TIMEZONE
    $EFFECTIVE_GUEST_TIMEZONE ($TIMEZONE_ACTION); guest policy and SearXNG TZ/use verified.

  RUNTIME AND FILES
    SearXNG: $APP_IMAGE
      $APP_IMAGE_ID
    Valkey:  $VALKEY_IMAGE
      $VALKEY_IMAGE_ID
    Quadlets: /etc/containers/systemd/searxng{,-valkey}.container
    Config: /opt/searxng/config/settings.yml (contains secret_key), limiter.toml
    Cache: /opt/searxng/cache | Valkey config: /opt/searxng/valkey.conf
    State: /opt/searxng/.env | Access policy: /opt/searxng/ufw-policy.json

  UPDATES AND RECOVERY
    Image timer: $IMAGE_TIMER_LABEL; daily $UPDATE_TIME ($EFFECTIVE_GUEST_TIMEZONE, local/DST).
    Common checker: enabled; after boot and hourly.
    Persistent config/cache are in the CT root disk; no external app bind storage is configured.
    No PBS backup or PVE snapshot was created or verified by this creator.
    Verify matching recovery coverage before updates; --yes only skips confirmation.
    SearXNG target images are retained after attempted starts; image rollback cannot undo data changes.
SUMMARY
if [[ $PODMAN_FUSE_OVERLAY == 1 ]]; then
  echo '    FUSE is enabled: use stop-mode PBS; validate backup/restore for this CT.'
fi
cat <<SUMMARY

  RUN ON PROXMOX
    pct enter $CT_ID
    pct exec $CT_ID -- /usr/local/bin/searxng-maint.sh check
    pct exec $CT_ID -- /usr/local/bin/searxng-maint.sh version
    pct exec $CT_ID -- /usr/local/sbin/lab-hardening-check

  RUN INSIDE THE CT
    /usr/local/bin/searxng-maint.sh check
    /usr/local/bin/searxng-maint.sh version
    /usr/local/bin/searxng-maint.sh update $APP_TAG
    /usr/local/bin/searxng-maint.sh update-valkey $VALKEY_TAG
    /usr/local/sbin/lab-hardening-check
    ufw status verbose
    journalctl -u searxng.service -u searxng-valkey.service --no-pager -n 80

  VERIFICATION
    Application: passed | Common hardening: $HARDENING_RESULT
    Any WARN above requires review; no automatic restart/reboot was performed.
    Still required: intended-client/proxy and denied-source tests, DHCP renewal,
    reviewed reboot persistence and backup/restore acceptance.
SUMMARY
