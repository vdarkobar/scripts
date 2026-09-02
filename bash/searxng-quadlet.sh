#!/usr/bin/env bash
set -Eeo pipefail

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
VALKEY_TAG="latest"                  # "latest" or a full version like 9.0.5; floating majors (9, 9.0) are rejected
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
# AUTO_UPDATE=1 (default): searxng-update.timer re-pulls the CURRENT tags
#   (latest or pinned) daily at UPDATE_TIME and restarts only the services
#   whose image ID changed; a failed health check rolls back to the previous image.
# AUTO_UPDATE=0: timer installed but disabled; manual updates via
#   searxng-maint.sh update <tag> / update-valkey <tag> / auto-update
AUTO_UPDATE=1
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
[[ "$CPU" =~ ^[0-9]+$ ]] && (( CPU >= 1 )) || { echo "  ERROR: CPU must be a positive integer." >&2; exit 1; }
[[ "$RAM" =~ ^[0-9]+$ ]] && (( RAM >= 256 )) || { echo "  ERROR: RAM must be >= 256 MB." >&2; exit 1; }
[[ "$DISK" =~ ^[0-9]+$ ]] && (( DISK >= 1 )) || { echo "  ERROR: DISK must be >= 1 GB." >&2; exit 1; }
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }
[[ "$APP_PORT" =~ ^[0-9]+$ ]] || { echo "  ERROR: APP_PORT must be numeric." >&2; exit 1; }
(( APP_PORT >= 1 && APP_PORT <= 65535 )) || { echo "  ERROR: APP_PORT must be between 1 and 65535." >&2; exit 1; }
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
# Valkey: "latest" (default) or full semver (9.0.5). Floating majors (9, 9.0) are rejected —
# they hide which line is running without the simplicity of "latest".
[[ "$VALKEY_TAG" == "latest" || "$VALKEY_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: VALKEY_TAG must be 'latest' or a full version like 9.0.5 (floating tags like 9 are not accepted)." >&2
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
  Listens on:        0.0.0.0:${APP_PORT} inside the CT (Network=host) — reachable from the whole LAN
                     Valkey on 127.0.0.1:6379 only (not reachable from the LAN)
  Podman storage:    $([ "$PODMAN_FUSE_OVERLAY" -eq 1 ] && echo "fuse-overlayfs (fuse=1)" || echo "native overlay (no FUSE)")
  Tags:              $TAGS
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled — daily at ${UPDATE_TIME} (re-pull $APP_TAG / $VALKEY_TAG)" || echo "disabled ($APP_TAG / $VALKEY_TAG, manual)")
  Cleanup on fail:   $CLEANUP_ON_FAIL (until first service start; CT preserved after that)
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/searxng-quadlet.sh"
SCRIPT_LOCAL="/root/searxng-quadlet.sh"
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
Image=${VALKEY_IMAGE}
ContainerName=searxng-valkey
Network=host
Exec=valkey-server /etc/valkey/valkey.conf
Volume=${APP_DIR}/valkey.conf:/etc/valkey/valkey.conf:ro
LogDriver=journald

[Service]
Restart=always
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF2

  cat > '${QUADLET_FILE}' <<EOF2
[Unit]
Description=SearXNG
After=network-online.target ${VALKEY_QUADLET_SERVICE}
Wants=network-online.target
Requires=${VALKEY_QUADLET_SERVICE}

[Container]
Image=${APP_IMAGE}
ContainerName=searxng
Network=host
Environment=TZ=${APP_TZ}
Environment=SEARXNG_BIND_ADDRESS=0.0.0.0
Environment=SEARXNG_PORT=${APP_PORT}
Environment=FORCE_OWNERSHIP=true
Volume=${APP_DIR}/config:/etc/searxng
Volume=${APP_DIR}/cache:/var/cache/searxng
LogDriver=journald

[Service]
Restart=always
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
VALKEY_IMAGE_REPO=${VALKEY_IMAGE_REPO}
VALKEY_TAG=${VALKEY_TAG}
VALKEY_IMAGE=${VALKEY_IMAGE}
APP_PORT=${APP_PORT}
APP_TZ=${APP_TZ}
APP_FQDN=${APP_FQDN}
PUBLIC_INSTANCE=${PUBLIC_INSTANCE}
AUTO_UPDATE=${AUTO_UPDATE}
EOF2
  chmod 0600 '${APP_DIR}/.env'
"

# ── Maintenance script ────────────────────────────────────────────────────────
# update <tag>:        SearXNG — pull → sed Image= in Quadlet file → sed .env →
#   daemon-reload → restart → /healthz check; rollback restores both files,
#   daemon-reload, restart.
# update-valkey <tag>: same flow for the Valkey unit; SearXNG is restarted
#   afterwards so it reconnects cleanly to the new backend.
# auto-update:  re-pull BOTH current tags (latest or pinned); restart only what
#   changed; rollback re-tags the previous image ID and restarts.
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/searxng-maint.sh && chmod 0755 /usr/local/bin/searxng-maint.sh' <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR="${APP_DIR:-/opt/searxng}"
QUADLET_FILE="/etc/containers/systemd/searxng.container"
VALKEY_QUADLET_FILE="/etc/containers/systemd/searxng-valkey.container"
SERVICE="searxng.service"
VALKEY_SERVICE="searxng-valkey.service"
CONTAINER="searxng"
VALKEY_CONTAINER="searxng-valkey"
ENV_FILE="${APP_DIR}/.env"

need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF2
  SearXNG Maintenance (Quadlet)
  ─────────────────────────────
  Usage:
    $0 update <tag> [--yes]          # SearXNG: latest, or pin e.g. 2026.9.1-248e37991
    $0 update-valkey <tag> [--yes]   # Valkey:  latest, or pin e.g. 9.0.6
    $0 auto-update                   # re-pull current tags (only if AUTO_UPDATE=1)
    $0 version

  Notes:
    - update pulls the tag, updates the Quadlet unit and .env, restarts the service
    - auto-update is called by searxng-update.timer; it never changes the tags
    - to switch between tracking and pinning: update latest / update <full tag>
    - settings.yml / limiter.toml changes: systemctl restart ${SERVICE}
    - backup and restore are handled by PBS and PVE snapshots
    - take a PVE snapshot before manual updates: pct snapshot <CT_ID> pre-update-\$(date +%Y%m%d)
EOF2
}

[[ -d "$APP_DIR" ]]             || die "APP_DIR not found: $APP_DIR"
[[ -f "$ENV_FILE" ]]            || die "Missing env file: $ENV_FILE"
[[ -f "$QUADLET_FILE" ]]        || die "Missing Quadlet unit: $QUADLET_FILE"
[[ -f "$VALKEY_QUADLET_FILE" ]] || die "Missing Quadlet unit: $VALKEY_QUADLET_FILE"

# One maintenance operation at a time — a manual update must not overlap the timer.
LOCK_FILE="/run/lock/searxng-maint.lock"
mkdir -p /run/lock
exec 9>"$LOCK_FILE"
flock -n 9 || die "Another searxng-maint.sh operation is already running."

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
  [[ "$port" =~ ^[0-9]+$ ]] && printf '%s' "$port" || printf '8080'
}

current_image()  { env_val APP_IMAGE; }
current_repo()   { env_val APP_IMAGE_REPO; }
current_tag()    { local img; img="$(current_image)"; echo "${img##*:}"; }
valkey_image()   { env_val VALKEY_IMAGE; }
valkey_repo()    { env_val VALKEY_IMAGE_REPO; }
valkey_tag()     { local img; img="$(valkey_image)"; echo "${img##*:}"; }

running_image_id() {
  podman inspect --format '{{.Image}}' "$1" 2>/dev/null || true
}

image_id_of() {
  podman image inspect --format '{{.Id}}' "$1" 2>/dev/null || true
}

# /healthz is exempt from the limiter, so a plain curl from inside the CT is a
# valid readiness probe even though the limiter is always active.
wait_for_app() {
  local port code
  port="$(app_port)"
  for i in $(seq 1 45); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${port}/healthz" 2>/dev/null || echo 000)"
    [[ "$code" == "200" ]] && return 0
    sleep 2
  done
  return 1
}

wait_for_valkey() {
  local pong
  for i in $(seq 1 20); do
    pong="$(podman exec "$VALKEY_CONTAINER" valkey-cli -h 127.0.0.1 ping 2>/dev/null || true)"
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

# update <tag> [--yes] — switch SearXNG to "latest" or a pinned version
update_app() {
  local new_tag="" skip_confirm=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) skip_confirm=1; shift ;;
      *) new_tag="$1"; shift ;;
    esac
  done

  local old_tag repo old_image new_image old_id tmp_env tmp_quadlet
  [[ -n "$new_tag" ]] || die "Usage: searxng-maint.sh update <tag>"
  [[ "$new_tag" == "latest" || "$new_tag" =~ ^[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}-[0-9a-f]{7,12}$ ]] \
    || die "Invalid tag: $new_tag — use 'latest' or a SearXNG tag like 2026.9.1-248e37991."

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

  echo "  Waiting for SearXNG ..."
  if ! wait_for_app; then
    trap - ERR
    rollback
    die "SearXNG did not become healthy after update."
  fi

  trap - ERR
  cleanup
  if [[ -n "$old_id" && "$old_id" != "$(image_id_of "$new_image")" ]]; then
    podman rmi "$old_id" >/dev/null 2>&1 || true
  fi
  echo "  OK: SearXNG updated to $new_tag"
}

# update-valkey <tag> [--yes] — switch the Valkey backend to "latest" or a pinned version
update_valkey() {
  local new_tag="" skip_confirm=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) skip_confirm=1; shift ;;
      *) new_tag="$1"; shift ;;
    esac
  done

  local old_tag repo old_image new_image old_id tmp_env tmp_quadlet
  [[ -n "$new_tag" ]] || die "Usage: searxng-maint.sh update-valkey <tag>"
  [[ "$new_tag" == "latest" || "$new_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] \
    || die "Invalid tag: $new_tag — use 'latest' or a full version like 9.0.6."

  old_tag="$(valkey_tag)"
  repo="$(valkey_repo)"
  [[ -n "$repo" ]] || die "Could not read VALKEY_IMAGE_REPO from .env"
  old_image="$(valkey_image)"
  new_image="${repo}:${new_tag}"
  old_id="$(image_id_of "$old_image")"
  tmp_env="$(mktemp)"
  tmp_quadlet="$(mktemp)"

  echo "  Current Valkey tag: $old_tag"
  echo "  Target  Valkey tag: $new_tag"

  if [[ "$skip_confirm" -eq 0 ]]; then
    confirm_or_exit || { rm -f "$tmp_env" "$tmp_quadlet"; exit 0; }
  fi

  cp -a "$ENV_FILE"            "$tmp_env"
  cp -a "$VALKEY_QUADLET_FILE" "$tmp_quadlet"

  cleanup() { rm -f "$tmp_env" "$tmp_quadlet"; }
  rollback() {
    echo "  !! Valkey update failed — rolling back and restarting ..." >&2
    cp -a "$tmp_env"     "$ENV_FILE"
    cp -a "$tmp_quadlet" "$VALKEY_QUADLET_FILE"
    [[ -n "$old_id" ]] && podman tag "$old_id" "$old_image" >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl restart "$VALKEY_SERVICE" || true
    systemctl restart "$SERVICE" || true
    rm -f "$tmp_env" "$tmp_quadlet"
    if wait_for_valkey && wait_for_app; then
      echo "  Rollback complete — ${old_image} is healthy again." >&2
    else
      echo "  CRITICAL: rollback to ${old_image} did not become healthy. Restore the CT from the PVE snapshot / PBS." >&2
    fi
  }
  trap rollback ERR

  echo "  Pulling target image ..."
  podman pull "$new_image"

  sed -i "s|^Image=.*|Image=${new_image}|" "$VALKEY_QUADLET_FILE"
  sed -i \
    -e "s|^VALKEY_TAG=.*|VALKEY_TAG=$new_tag|" \
    -e "s|^VALKEY_IMAGE=.*|VALKEY_IMAGE=$new_image|" \
    "$ENV_FILE"

  echo "  Reloading Quadlet and restarting Valkey + SearXNG ..."
  systemctl daemon-reload
  systemctl restart "$VALKEY_SERVICE"
  systemctl restart "$SERVICE"

  echo "  Waiting for Valkey and SearXNG ..."
  if ! wait_for_valkey || ! wait_for_app; then
    trap - ERR
    rollback
    die "Stack did not become healthy after Valkey update."
  fi

  trap - ERR
  cleanup
  if [[ -n "$old_id" && "$old_id" != "$(image_id_of "$new_image")" ]]; then
    podman rmi "$old_id" >/dev/null 2>&1 || true
  fi
  echo "  OK: Valkey updated to $new_tag"
}

# auto-update — re-pull the current tags (latest or pinned); restart only what changed
auto_update_app() {
  if [[ "$(env_flag AUTO_UPDATE)" != "1" ]]; then
    echo "  Auto-update disabled in ${ENV_FILE}; nothing to do."
    return 0
  fi

  local vk_image vk_old_id vk_new_id app_image app_old_id app_new_id
  vk_image="$(valkey_image)"
  app_image="$(current_image)"
  [[ -n "$vk_image" ]]  || die "Could not read VALKEY_IMAGE from .env"
  [[ -n "$app_image" ]] || die "Could not read APP_IMAGE from .env"
  vk_old_id="$(running_image_id "$VALKEY_CONTAINER")"
  app_old_id="$(running_image_id "$CONTAINER")"

  echo "  Auto-update: re-pulling ${vk_image} ..."
  podman pull "$vk_image"
  vk_new_id="$(image_id_of "$vk_image")"
  [[ -n "$vk_new_id" ]] || die "Could not inspect pulled image ${vk_image}"

  echo "  Auto-update: re-pulling ${app_image} ..."
  podman pull "$app_image"
  app_new_id="$(image_id_of "$app_image")"
  [[ -n "$app_new_id" ]] || die "Could not inspect pulled image ${app_image}"

  local vk_changed=0 app_changed=0
  [[ -z "$vk_old_id"  || "$vk_new_id"  != "$vk_old_id"  ]] && vk_changed=1
  [[ -z "$app_old_id" || "$app_new_id" != "$app_old_id" ]] && app_changed=1

  if [[ "$vk_changed" -eq 0 && "$app_changed" -eq 0 ]]; then
    echo "  OK: both images are already current — no restart needed."
    return 0
  fi

  rollback() {
    echo "  !! Auto-update failed — restoring previous images and restarting ..." >&2
    [[ "$vk_changed"  -eq 1 && -n "$vk_old_id"  ]] && podman tag "$vk_old_id"  "$vk_image"  >/dev/null 2>&1 || true
    [[ "$app_changed" -eq 1 && -n "$app_old_id" ]] && podman tag "$app_old_id" "$app_image" >/dev/null 2>&1 || true
    [[ "$vk_changed" -eq 1 ]] && { systemctl restart "$VALKEY_SERVICE" || true; }
    systemctl restart "$SERVICE" || true
    if wait_for_valkey && wait_for_app; then
      echo "  Rollback complete — previous images are healthy again." >&2
    else
      echo "  CRITICAL: rollback did not become healthy. Restore the CT from the PVE snapshot / PBS." >&2
    fi
  }
  trap rollback ERR

  if [[ "$vk_changed" -eq 1 ]]; then
    echo "  Valkey image changed — restarting ${VALKEY_SERVICE} ..."
    systemctl restart "$VALKEY_SERVICE"
  fi
  # SearXNG restarts when its own image changed, or after a Valkey restart so
  # the limiter reconnects cleanly.
  echo "  Restarting ${SERVICE} ..."
  systemctl restart "$SERVICE"

  echo "  Waiting for Valkey and SearXNG ..."
  if ! wait_for_valkey || ! wait_for_app; then
    trap - ERR
    rollback
    die "Stack did not become healthy after auto-update."
  fi

  trap - ERR
  [[ "$vk_changed"  -eq 1 && -n "$vk_old_id"  ]] && podman rmi "$vk_old_id"  >/dev/null 2>&1 || true
  [[ "$app_changed" -eq 1 && -n "$app_old_id" ]] && podman rmi "$app_old_id" >/dev/null 2>&1 || true
  echo "  OK: SearXNG stack refreshed (SearXNG changed: ${app_changed}, Valkey changed: ${vk_changed})"
}

need_root
cmd="${1:-}"
case "$cmd" in
  update)        shift; update_app "$@" ;;
  update-valkey) shift; update_valkey "$@" ;;
  auto-update)   auto_update_app ;;
  version)
    # With "latest" the tag carries no version info; the digest identifies the build.
    echo "Configured SearXNG image: $(current_image)"
    echo "Running SearXNG image ID: $(running_image_id "$CONTAINER")"
    echo "SearXNG digest:           $(podman image inspect --format '{{index .RepoDigests 0}}' "$(current_image)" 2>/dev/null || echo n/a)"
    echo "Configured Valkey image:  $(valkey_image)"
    echo "Running Valkey image ID:  $(running_image_id "$VALKEY_CONTAINER")"
    echo "Valkey digest:            $(podman image inspect --format '{{index .RepoDigests 0}}' "$(valkey_image)" 2>/dev/null || echo n/a)"
    echo "PUBLIC_INSTANCE=$(env_flag PUBLIC_INSTANCE)"
    echo "AUTO_UPDATE=$(env_flag AUTO_UPDATE)"
    ;;
  ""|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
MAINT
echo "  Maintenance script deployed: /usr/local/bin/searxng-maint.sh"

# ── Start via Quadlet ─────────────────────────────────────────────────────────
# daemon-reload triggers the Quadlet generator which produces searxng.service
# and searxng-valkey.service as transient systemd units. WantedBy=multi-user.target
# handles boot restarts. Transient units cannot be systemctl-enabled;
# daemon-reload is sufficient. Starting searxng.service pulls in Valkey via Requires=.
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
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > /etc/systemd/system/searxng-update.service <<EOF2
[Unit]
Description=SearXNG auto-update maintenance run
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/searxng-maint.sh auto-update
EOF2

  cat > /etc/systemd/system/searxng-update.timer <<EOF2
[Unit]
Description=SearXNG auto-update timer

[Timer]
OnCalendar=*-*-* ${UPDATE_TIME}:00
Persistent=true

[Install]
WantedBy=timers.target
EOF2

  systemctl daemon-reload
"
if [[ "$AUTO_UPDATE" -eq 1 ]]; then
  pct exec "$CT_ID" -- bash -lc 'systemctl enable --now searxng-update.timer'
  echo "  Auto-update timer enabled"
else
  pct exec "$CT_ID" -- bash -lc 'systemctl disable --now searxng-update.timer >/dev/null 2>&1 || true'
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
echo "    Port ${APP_PORT} listens on all CT interfaces (Network=host) — restrict with the PVE firewall if needed."
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
