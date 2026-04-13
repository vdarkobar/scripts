#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID="$(pvesh get /cluster/nextid)"
HN="searxng"
CPU=2
RAM=3072
DISK=16
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# SearXNG / Podman
APP_PORT=8080                        # host-side port; SearXNG listens on 8080 internally
APP_TZ="Europe/Berlin"
INSTANCE_NAME="SearXNG"              # displayed in the web UI title and results page
PUBLIC_FQDN=""                       # e.g. search.example.com — sets base_url and enables public_instance: true
                                     # (link_token bot detection); leave blank for local-only mode
TAGS="searxng;podman;lxc"

# Images / versions
# SearXNG uses date-based tags, e.g. 2025.8.1-3d96414
# Verify and pin a specific tag from: https://hub.docker.com/r/searxng/searxng/tags
# GHCR alternative: ghcr.io/searxng/searxng (avoids DockerHub pull-rate limits)
SEARXNG_IMAGE_REPO="docker.io/searxng/searxng"
SEARXNG_TAG="latest"                 # IMPORTANT: replace with a pinned date-based tag
# Valkey is always deployed — the limiter requires it regardless of public/local mode.
VALKEY_IMAGE_REPO="docker.io/valkey/valkey"
VALKEY_TAG="9"
DEBIAN_VERSION=13

# SearXNG settings.yml overrides
# Full reference: https://docs.searxng.org/admin/settings/settings.html
SEARCH_SAFE_SEARCH=0                 # 0 = off, 1 = moderate, 2 = strict
SEARCH_DEFAULT_LANG=""               # blank = detect from browser; e.g. "en" or "de"
SEARCH_AUTOCOMPLETE=""               # blank = off; options: google, duckduckgo, brave, etc.
ENABLE_IMAGE_PROXY=1                 # 1 = proxy images through SearXNG (uses memory)
OUTGOING_TIMEOUT=4.0                 # seconds before giving up on an upstream search engine
OUTGOING_MAX_TIMEOUT=10.0            # hard ceiling for upstream request timeouts

# Optional features / policy
AUTO_UPDATE=0                        # 1 = enable timer-driven update runs
TRACK_LATEST=0                       # 1 = auto-update follows :latest
KEEP_BACKUPS=7

# Extra packages to install (space-separated or array)
EXTRA_PACKAGES=()

# Behavior
CLEANUP_ON_FAIL=1

# Derived
APP_DIR="/opt/searxng"
BACKUP_DIR="/opt/searxng-backups"
SEARXNG_IMAGE="${SEARXNG_IMAGE_REPO}:${SEARXNG_TAG}"
VALKEY_IMAGE="${VALKEY_IMAGE_REPO}:${VALKEY_TAG}"
BASE_URL=""
[[ -n "$PUBLIC_FQDN" ]] && BASE_URL="https://${PUBLIC_FQDN}/"
# PUBLIC_INSTANCE controls only public_instance: in settings.yml
# (enables link_token bot detection for internet-facing instances).
# Valkey and the limiter are always deployed regardless of this flag.
PUBLIC_INSTANCE=0
[[ -n "$PUBLIC_FQDN" ]] && PUBLIC_INSTANCE=1

# ── Custom configs created by this script ─────────────────────────────────────
#   /opt/searxng/docker-compose.yml         (Podman compose stack)
#   /opt/searxng/.env                       (runtime configuration and update policy)
#   /opt/searxng/config/settings.yml        (SearXNG application configuration)
#   /opt/searxng/config/limiter.toml         (bot detection config)
#   /opt/searxng/cache/                     (favicon DB and SearXNG persistent cache)
#   /opt/searxng/valkey/                    (Valkey data — rate-limit counters)
#   /opt/searxng-backups/                   (operational backups)
#   /usr/local/bin/searxng-maint.sh         (maintenance helper)
#   /etc/sysctl.d/99-valkey-overcommit.conf (HOST -- vm.overcommit_memory)
#   /etc/systemd/system/searxng-stack.service
#   /etc/systemd/system/searxng-update.service
#   /etc/systemd/system/searxng-update.timer
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/sysctl.d/99-hardening.conf

# ── Config validation ─────────────────────────────────────────────────────────
[[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }
[[ "$APP_PORT" =~ ^[0-9]+$ ]] || { echo "  ERROR: APP_PORT must be numeric." >&2; exit 1; }
(( APP_PORT >= 1 && APP_PORT <= 65535 )) || { echo "  ERROR: APP_PORT must be between 1 and 65535." >&2; exit 1; }
[[ "$KEEP_BACKUPS" =~ ^[0-9]+$ ]] || { echo "  ERROR: KEEP_BACKUPS must be numeric." >&2; exit 1; }
[[ "$AUTO_UPDATE" =~ ^[01]$ ]] || { echo "  ERROR: AUTO_UPDATE must be 0 or 1." >&2; exit 1; }
[[ "$TRACK_LATEST" =~ ^[01]$ ]] || { echo "  ERROR: TRACK_LATEST must be 0 or 1." >&2; exit 1; }
[[ "$ENABLE_IMAGE_PROXY" =~ ^[01]$ ]] || { echo "  ERROR: ENABLE_IMAGE_PROXY must be 0 or 1." >&2; exit 1; }
[[ "$SEARCH_SAFE_SEARCH" =~ ^[012]$ ]] || { echo "  ERROR: SEARCH_SAFE_SEARCH must be 0, 1, or 2." >&2; exit 1; }
[[ -n "$SEARXNG_TAG" && "$SEARXNG_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
  echo "  ERROR: SEARXNG_TAG is empty or contains invalid characters: $SEARXNG_TAG" >&2
  exit 1
}
[[ -n "$VALKEY_TAG" && "$VALKEY_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
  echo "  ERROR: VALKEY_TAG is empty or contains invalid characters: $VALKEY_TAG" >&2
  exit 1
}
[[ -n "$INSTANCE_NAME" ]] || { echo "  ERROR: INSTANCE_NAME cannot be blank." >&2; exit 1; }
[[ -e "/usr/share/zoneinfo/${APP_TZ}" ]] || {
  echo "  ERROR: APP_TZ not found in /usr/share/zoneinfo: $APP_TZ" >&2; exit 1;
}
if [[ -n "$PUBLIC_FQDN" && ! "$PUBLIC_FQDN" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "  ERROR: PUBLIC_FQDN contains invalid characters: $PUBLIC_FQDN" >&2
  exit 1
fi

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

for cmd in pvesh pveam pct pvesm curl python3 ip awk sort paste readlink cp chmod; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

# ── Discover available resources ──────────────────────────────────────────────
AVAIL_TMPL_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'vztmpl' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_CT_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^vmbr' | sort | paste -sd, | sed 's/,/, /g' || echo "n/a")"

# ── Show defaults & confirm ───────────────────────────────────────────────────
cat <<EOF2

  SearXNG-Podman LXC Creator — Configuration
  ────────────────────────────────────────
  CT ID:             $CT_ID
  Hostname:          $HN
  CPU cores:         $CPU
  RAM (MB):          $RAM
  Disk (GB):         $DISK
  Bridge:            $BRIDGE ($AVAIL_BRIDGES)
  Template storage:  $TEMPLATE_STORAGE ($AVAIL_TMPL_STORES)
  Container storage: $CONTAINER_STORAGE ($AVAIL_CT_STORES)
  Debian:            $DEBIAN_VERSION
  SearXNG tag:       $SEARXNG_TAG
  App port:          $APP_PORT
  Instance name:     $INSTANCE_NAME
  Public FQDN:       ${PUBLIC_FQDN:-"(not set — local IP mode)"}
  Timezone:          $APP_TZ
  Safe search:       ${SEARCH_SAFE_SEARCH} (0=off, 1=moderate, 2=strict)
  Autocomplete:      ${SEARCH_AUTOCOMPLETE:-"(disabled)"}
  Image proxy:       $([ "$ENABLE_IMAGE_PROXY" -eq 1 ] && echo "enabled" || echo "disabled")
  Limiter + Valkey:  always (Valkey ${VALKEY_TAG})
  public_instance:   $([ "$PUBLIC_INSTANCE" -eq 1 ] && echo "true (link_token enabled)" || echo "false (local/private)")
  Outgoing timeout:  ${OUTGOING_TIMEOUT}s / max ${OUTGOING_MAX_TIMEOUT}s
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled" || echo "disabled")
  Track latest:      $([ "$TRACK_LATEST" -eq 1 ] && echo "enabled" || echo "disabled")
  Keep backups:      $KEEP_BACKUPS
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/searxng-podman.sh"
SCRIPT_LOCAL="/root/searxng-podman.sh"
SCRIPT_SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

read -r -p "  Continue with these settings? [y/N]: " response
case "$response" in
  [yY][eE][sS]|[yY]) ;;
  *)
    echo ""
    echo "  Saving current script to ${SCRIPT_LOCAL} for editing..."
    if [[ -f "$SCRIPT_SELF" ]] && cp -f -- "$SCRIPT_SELF" "$SCRIPT_LOCAL"; then
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
    fi
    exit 0
    ;;
esac

echo ""

# ── Preflight — environment ───────────────────────────────────────────────────
pvesm status | awk -v s="$TEMPLATE_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Template storage not found: $TEMPLATE_STORAGE" >&2; exit 1; }
pvesm status | awk -v s="$CONTAINER_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Container storage not found: $CONTAINER_STORAGE" >&2; exit 1; }
ip link show "$BRIDGE" >/dev/null 2>&1 \
  || { echo "  ERROR: Bridge not found: $BRIDGE" >&2; exit 1; }

# ── Root password ─────────────────────────────────────────────────────────────
PASSWORD=""
while true; do
  read -r -s -p "  Set root password: " PW1; echo
  if [[ -z "$PW1" ]]; then echo "  Password cannot be blank."; continue; fi
  if [[ "$PW1" == *" "* ]]; then echo "  Password cannot contain spaces."; continue; fi
  if [[ ${#PW1} -lt 8 ]]; then echo "  Password must be at least 8 characters."; continue; fi
  read -r -s -p "  Verify root password: " PW2; echo
  if [[ "$PW1" == "$PW2" ]]; then PASSWORD="$PW1"; break; fi
  echo "  Passwords do not match. Try again."
done

echo ""

# ── Template discovery & download ─────────────────────────────────────────────
pveam update

echo ""
TEMPLATE="$(pveam available -section system | awk -v p="debian-${DEBIAN_VERSION}" '$2 ~ ("^" p) {print $2}' | sort -V | tail -n1)"
if [[ -z "$TEMPLATE" ]]; then
  echo "  WARNING: No Debian ${DEBIAN_VERSION} template found, trying any Debian..." >&2
  TEMPLATE="$(pveam available -section system | awk '$2 ~ /^debian-/ {print $2}' | sort -V | tail -n1)"
fi
[[ -n "$TEMPLATE" ]] || { echo "  ERROR: No Debian template found via pveam." >&2; exit 1; }
echo "  Template: $TEMPLATE"

if [[ "$TEMPLATE_STORAGE" == "local" && -f "/var/lib/vz/template/cache/$TEMPLATE" ]]; then
  echo "  Template already present: $TEMPLATE"
else
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

# ── Create LXC ────────────────────────────────────────────────────────────────
PCT_OPTIONS=(
  -hostname "$HN"
  -cores "$CPU"
  -memory "$RAM"
  -rootfs "${CONTAINER_STORAGE}:${DISK}"
  -onboot 1
  -ostype debian
  -unprivileged 1
  -features "nesting=1,keyctl=1,fuse=1"
  -tags "$TAGS"
  -net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,ip6=manual"
  -password "$PASSWORD"
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

if [[ -z "$BASE_URL" ]]; then
  BASE_URL="http://${CT_IP}:${APP_PORT}/"
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
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y locales curl ca-certificates iproute2 podman podman-compose fuse-overlayfs tar gzip
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
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  mkdir -p /etc/containers

  cat > /etc/containers/storage.conf <<EOF2
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
EOF2

  cat > /etc/containers/containers.conf <<EOF2
[containers]
log_size_max = 10485760
EOF2
'

pct exec "$CT_ID" -- podman info >/dev/null 2>&1
pct exec "$CT_ID" -- podman --version
pct exec "$CT_ID" -- podman-compose --version

# ── Generate secret key ───────────────────────────────────────────────────────
SEARXNG_SECRET="$(tr -dc 'a-f0-9' </dev/urandom | head -c 64 || true)"
[[ ${#SEARXNG_SECRET} -eq 64 ]] || { echo "  ERROR: Failed to generate SEARXNG_SECRET." >&2; exit 1; }

# ── Pull images ───────────────────────────────────────────────────────────────
echo "  Pulling SearXNG image: ${SEARXNG_IMAGE} ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman pull '${SEARXNG_IMAGE}'
"

echo "  Pulling Valkey image: ${VALKEY_IMAGE} ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman pull '${VALKEY_IMAGE}'
"

# ── Detect Valkey UID/GID for bind mount ─────────────────────────────────────
VALKEY_UID="$(pct exec "$CT_ID" -- bash -lc "podman run --rm --entrypoint sh '${VALKEY_IMAGE}' -lc 'id -u valkey 2>/dev/null || id -u'" 2>/dev/null | tr -d '\r')"
VALKEY_GID="$(pct exec "$CT_ID" -- bash -lc "podman run --rm --entrypoint sh '${VALKEY_IMAGE}' -lc 'id -g valkey 2>/dev/null || id -g'" 2>/dev/null | tr -d '\r')"
[[ "$VALKEY_UID" =~ ^[0-9]+$ ]] || { echo "  ERROR: Failed to detect numeric VALKEY_UID from image." >&2; exit 1; }
[[ "$VALKEY_GID" =~ ^[0-9]+$ ]] || { echo "  ERROR: Failed to detect numeric VALKEY_GID from image." >&2; exit 1; }
echo "  Detected Valkey bind-mount ownership: ${VALKEY_UID}:${VALKEY_GID}"

# ── Prepare persistent paths ──────────────────────────────────────────────────
# FORCE_OWNERSHIP=true (SearXNG container default) chowns /etc/searxng and
# /var/cache/searxng to the searxng user on every (re)start, so no UID detection
# is needed for those paths. Directories just need to exist.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  install -d -m 0755 '${APP_DIR}' '${BACKUP_DIR}'
  install -d -m 0755 '${APP_DIR}/config' '${APP_DIR}/cache'
"

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  install -d -m 0750 '${APP_DIR}/valkey'
  chown ${VALKEY_UID}:${VALKEY_GID} '${APP_DIR}/valkey'
"

# ── SearXNG settings.yml ──────────────────────────────────────────────────────
# Written before the stack starts so SearXNG picks it up on first boot.
# Uses use_default_settings: true — only listed keys override the upstream defaults.
# Full reference: https://docs.searxng.org/admin/settings/settings.html
#
# Note on secret_key: also passed as SEARXNG_SECRET env var; the env var takes
# precedence over the file value when both are present. Both are set so the file
# remains self-contained if the env var is later removed.
IMAGE_PROXY_YML=$([[ "$ENABLE_IMAGE_PROXY" -eq 1 ]] && echo "true" || echo "false")
# Limiter is always enabled — Valkey is always deployed.
LIMITER_YML="true"
# public_instance activates link_token bot detection (internet-facing only).
PUBLIC_INSTANCE_YML=$([[ "$PUBLIC_INSTANCE" -eq 1 ]] && echo "true" || echo "false")

# valkey: is a top-level settings.yml key, not nested under server:.
# Service name in compose is searxng_valkey.
VALKEY_SECTION="
valkey:
  url: valkey://searxng_valkey:6379/0"

pct exec "$CT_ID" -- bash -lc "cat > '${APP_DIR}/config/settings.yml' && chmod 0640 '${APP_DIR}/config/settings.yml'" <<SETTINGS
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
  bind_address: "[::]"
  base_url: "${BASE_URL}"
  image_proxy: ${IMAGE_PROXY_YML}
  limiter: ${LIMITER_YML}
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

# Disable engines that require Tor -- leaving them enabled causes ERROR log
# entries on every startup on a standard (non-Tor) instance.
engines:
  - name: ahmia
    disabled: true
  - name: torch
    disabled: true
${VALKEY_SECTION}
SETTINGS

# ── limiter.toml (public mode only) ──────────────────────────────────────────
# SearXNG expects this file when the limiter is enabled; without it the
# botdetection module logs a warning on every startup.
# Per docs: only override what you need — all other values inherit upstream defaults.
# The only necessary override for a homelab reverse-proxy setup is trusted_proxies,
# which tells the limiter to read the real client IP from X-Forwarded-For.
# Full reference: https://docs.searxng.org/admin/searx.limiter.html
pct exec "$CT_ID" -- bash -lc "cat > '${APP_DIR}/config/limiter.toml' && chmod 0640 '${APP_DIR}/config/limiter.toml'" <<'LIMITER'
[botdetection]
# Trust X-Forwarded-For / X-Real-IP from these reverse proxy address ranges.
# All RFC-1918 private ranges are included so any homelab proxy topology works.
trusted_proxies = [
  "127.0.0.0/8",
  "::1",
  "192.168.0.0/16",
  "172.16.0.0/12",
  "10.0.0.0/8",
  "fd00::/8",
]
LIMITER

# ── Compose file ──────────────────────────────────────────────────────────────
# Single-quoted heredoc: all dollar-brace refs stay literal, resolved by
# podman-compose from .env at runtime. This is intentional.
pct exec "$CT_ID" -- bash -lc "cat > '${APP_DIR}/docker-compose.yml' && chmod 0600 '${APP_DIR}/docker-compose.yml'" <<'COMPOSE'
services:
  searxng:
    image: ${SEARXNG_IMAGE}
    container_name: searxng
    restart: unless-stopped
    ports:
      - "${APP_PORT}:8080"
    environment:
      # SEARXNG_SECRET overrides settings.yml server.secret_key if set.
      SEARXNG_SECRET: ${SEARXNG_SECRET}
      # SEARXNG_BASE_URL overrides settings.yml server.base_url if set.
      SEARXNG_BASE_URL: ${SEARXNG_BASE_URL}
      SEARXNG_BIND_ADDRESS: "[::]"
      # FORCE_OWNERSHIP=true: entrypoint chowns /etc/searxng and /var/cache/searxng
      # to the searxng user automatically on each (re)start.
      FORCE_OWNERSHIP: "true"
      TZ: ${APP_TZ}
    volumes:
      - /opt/searxng/config:/etc/searxng:Z
      - /opt/searxng/cache:/var/cache/searxng:Z
COMPOSE

# Single-quoted heredoc keeps dollar-brace refs literal for podman-compose.
pct exec "$CT_ID" -- bash -lc "cat >> '${APP_DIR}/docker-compose.yml'" <<'COMPOSE_VALKEY'

  searxng_valkey:
    image: ${VALKEY_IMAGE}
    container_name: searxng_valkey
    restart: unless-stopped
    # Persistence disabled: Valkey only holds rate-limit counters which reset
    # harmlessly on restart. --save "" turns off RDB snapshots.
    command: valkey-server --save "" --loglevel warning
    volumes:
      - /opt/searxng/valkey:/data:Z
COMPOSE_VALKEY

# ── .env file ─────────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > '${APP_DIR}/.env' <<EOF2
COMPOSE_PROJECT_NAME=searxng
SEARXNG_IMAGE_REPO=${SEARXNG_IMAGE_REPO}
SEARXNG_TAG=${SEARXNG_TAG}
SEARXNG_IMAGE=${SEARXNG_IMAGE}
VALKEY_IMAGE_REPO=${VALKEY_IMAGE_REPO}
VALKEY_TAG=${VALKEY_TAG}
VALKEY_IMAGE=${VALKEY_IMAGE}
APP_PORT=${APP_PORT}
APP_TZ=${APP_TZ}
PUBLIC_FQDN=${PUBLIC_FQDN}
PUBLIC_INSTANCE=${PUBLIC_INSTANCE}
SEARXNG_BASE_URL=${BASE_URL}
SEARXNG_SECRET=${SEARXNG_SECRET}
KEEP_BACKUPS=${KEEP_BACKUPS}
AUTO_UPDATE=${AUTO_UPDATE}
TRACK_LATEST=${TRACK_LATEST}
EOF2
  chmod 0600 '${APP_DIR}/.env'
"

# ── Maintenance script ────────────────────────────────────────────────────────
# Backup scope:
#   .env, docker-compose.yml, config/settings.yml, cache/
#   + valkey/ (Valkey is always deployed; holds rate-limit counters only)
# PBS handles the full CT-level backup independently of this helper.
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/searxng-maint.sh && chmod 0755 /usr/local/bin/searxng-maint.sh' <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR="${APP_DIR:-/opt/searxng}"
BACKUP_DIR="${BACKUP_DIR:-/opt/searxng-backups}"
SERVICE="searxng-stack.service"
ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
KEEP_BACKUPS="${KEEP_BACKUPS:-7}"

need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF2
  SearXNG Maintenance
  -------------------
  Usage: $0 <command>

  Commands:
    backup                    Stop stack, archive config + cache + valkey, restart
    list                      List available backup archives
    restore  <file>           Stop stack, restore archive, restart
    update   <tag|latest>     Pull a new SearXNG tag and recreate container
    auto-update               Run update according to AUTO_UPDATE/TRACK_LATEST in .env
    version                   Show configured images and policy flags

  Backup scope:
    .env, docker-compose.yml, config/settings.yml, cache/, valkey/
  Note: PBS handles the full CT-level backup independently of this helper.
EOF2
}

[[ -f "$ENV_FILE" ]] || die "Missing .env file: $ENV_FILE"
[[ -f "$COMPOSE_FILE" ]] || die "Missing compose file: $COMPOSE_FILE"

env_keep_backups="$(awk -F= '/^KEEP_BACKUPS=/{print $2}' "$ENV_FILE" | tail -n1)"
if [[ "$env_keep_backups" =~ ^[0-9]+$ ]]; then
  KEEP_BACKUPS="$env_keep_backups"
fi

current_image() {
  awk -F= '/^SEARXNG_IMAGE=/{print $2}' "$ENV_FILE" | tail -n1
}

current_tag() {
  local img
  img="$(current_image)"
  echo "${img##*:}"
}

current_repo() {
  awk -F= '/^SEARXNG_IMAGE_REPO=/{print $2}' "$ENV_FILE" | tail -n1
}

env_flag() {
  local key="$1" raw
  raw="$(awk -F= -v key="$key" '$1==key{print $2}' "$ENV_FILE" | tail -n1 | tr -d '[:space:]')"
  [[ "$raw" =~ ^[01]$ ]] && printf '%s' "$raw" || printf '0'
}

auto_update_enabled()  { [[ "$(env_flag AUTO_UPDATE)" == "1" ]]; }
track_latest_enabled() { [[ "$(env_flag TRACK_LATEST)" == "1" ]]; }

resolve_auto_tag() {
  if track_latest_enabled; then
    printf '%s\n' latest
  else
    current_tag
  fi
}

backup_stack() {
  local ts out started=0
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$BACKUP_DIR/searxng-backup-$ts.tar.gz"

  mkdir -p "$BACKUP_DIR"

  if systemctl is-active --quiet "$SERVICE"; then
    started=1
    echo "  Stopping SearXNG stack for consistent backup ..."
    systemctl stop "$SERVICE"
  fi

  trap 'if [[ $started -eq 1 ]]; then systemctl start "$SERVICE" || true; fi' RETURN

  echo "  Creating backup: $out"
  tar -C / -czf "$out" \
    opt/searxng/.env \
    opt/searxng/docker-compose.yml \
    opt/searxng/config \
    opt/searxng/cache \
    opt/searxng/valkey

  if [[ "$KEEP_BACKUPS" =~ ^[0-9]+$ ]] && (( KEEP_BACKUPS > 0 )); then
    ls -1t "$BACKUP_DIR"/searxng-backup-*.tar.gz 2>/dev/null \
      | awk -v keep="$KEEP_BACKUPS" 'NR>keep' \
      | xargs -r rm -f --
  fi

  echo "  OK: $out"
}

restore_stack() {
  local backup="$1"
  [[ -n "$backup" ]] || die "Usage: searxng-maint.sh restore <backup.tar.gz>"
  [[ -f "$backup" ]] || die "Backup not found: $backup"

  echo "  Stopping SearXNG stack ..."
  systemctl stop "$SERVICE" 2>/dev/null || true

  echo "  Removing current persistent state ..."
  rm -rf \
    "$APP_DIR/config" \
    "$APP_DIR/cache" \
    "$APP_DIR/valkey" \
    "$APP_DIR/.env" \
    "$APP_DIR/docker-compose.yml"

  echo "  Restoring backup ..."
  tar -C / -xzf "$backup"

  echo "  Starting SearXNG stack ..."
  systemctl start "$SERVICE"
  echo "  OK: restore completed."
}

update_searxng() {
  local new_tag="$1"
  local old_image new_image repo tmp_env old_tag
  [[ -n "$new_tag" ]] || die "Usage: searxng-maint.sh update <tag|latest>"
  [[ "$new_tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid SearXNG tag: $new_tag"

  old_image="$(current_image)"
  old_tag="$(current_tag)"
  repo="$(current_repo)"
  [[ -n "$old_image" ]] || die "Could not read current SEARXNG_IMAGE from .env"
  [[ -n "$repo" ]] || die "Could not read SEARXNG_IMAGE_REPO from .env"
  new_image="${repo}:${new_tag}"
  tmp_env="$(mktemp)"

  echo "  Current SearXNG tag: $old_tag"
  echo "  Target  SearXNG tag: $new_tag"

  backup_stack
  cp -a "$ENV_FILE" "$tmp_env"

  cleanup() { rm -f "$tmp_env"; }
  rollback() {
    echo "  !! Update failed -- rolling back .env and container ..." >&2
    cp -a "$tmp_env" "$ENV_FILE"
    cd "$APP_DIR"
    /usr/bin/podman-compose up -d --force-recreate searxng || true
  }
  trap rollback ERR

  echo "  Pulling target image ..."
  podman pull "$new_image"

  sed -i \
    -e "s|^SEARXNG_TAG=.*|SEARXNG_TAG=$new_tag|" \
    -e "s|^SEARXNG_IMAGE=.*|SEARXNG_IMAGE=$new_image|" \
    "$ENV_FILE"

  echo "  Recreating SearXNG container ..."
  cd "$APP_DIR"
  /usr/bin/podman-compose up -d --force-recreate searxng

  echo "  Waiting for SearXNG to become available ..."
  local port
  port="$(awk -F= '/^APP_PORT=/{print $2}' "$ENV_FILE" | tail -n1)"
  port="${port:-8080}"
  # The limiter is always active — skip HTTP check, check container instead.
  sleep 5
  if podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^searxng$"; then
    echo "  SearXNG container is running (HTTP check skipped — limiter blocks localhost curl)"
  else
    die "SearXNG container is not running after update."
  fi

  trap - ERR
  cleanup
  echo "  OK: SearXNG updated to $new_tag"
}

auto_update_searxng() {
  local target_tag

  if ! auto_update_enabled; then
    echo "  Auto-update disabled in ${ENV_FILE}; nothing to do."
    return 0
  fi

  target_tag="$(resolve_auto_tag)"
  if track_latest_enabled; then
    echo "  Auto-update policy: TRACK_LATEST=1 -> following latest"
  else
    echo "  Auto-update policy: TRACK_LATEST=0 -> reapplying configured tag $(current_tag)"
  fi

  update_searxng "$target_tag"
}

need_root
cmd="${1:-}"
case "$cmd" in
  backup)      backup_stack ;;
  list)        ls -1t "$BACKUP_DIR"/searxng-backup-*.tar.gz 2>/dev/null || true ;;
  restore)     shift; restore_stack "${1:-}" ;;
  update)      shift; update_searxng "${1:-}" ;;
  auto-update) auto_update_searxng ;;
  version)
    echo "Configured SearXNG image: $(current_image)"
    echo "Configured Valkey image:  $(awk -F= '/^VALKEY_IMAGE=/{print $2}' "$ENV_FILE" | tail -n1)"
    echo "PUBLIC_INSTANCE=$(env_flag PUBLIC_INSTANCE)"
    echo "AUTO_UPDATE=$(env_flag AUTO_UPDATE)"
    echo "TRACK_LATEST=$(env_flag TRACK_LATEST)"
    ;;
  ""|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
MAINT
echo "  Maintenance script deployed: /usr/local/bin/searxng-maint.sh"

# ── Systemd stack unit ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/searxng-stack.service <<EOF2
[Unit]
Description=SearXNG (Podman) stack
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/searxng
ExecStart=/usr/bin/podman-compose up -d
ExecStop=/usr/bin/podman-compose down
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF2

  systemctl daemon-reload
  systemctl enable --now searxng-stack.service
'

# ── Auto-update timer (policy-driven) ─────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
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
  pct exec "$CT_ID" -- bash -lc 'systemctl enable --now searxng-update.timer'
  echo "  Auto-update timer enabled"
else
  pct exec "$CT_ID" -- bash -lc 'systemctl disable --now searxng-update.timer >/dev/null 2>&1 || true'
  echo "  Auto-update timer installed but disabled"
fi

# ── Verification ──────────────────────────────────────────────────────────────
EXPECTED_CONTAINERS=2

sleep 5
if pct exec "$CT_ID" -- systemctl is-active --quiet searxng-stack.service 2>/dev/null; then
  echo "  SearXNG stack service is active"
else
  echo "  WARNING: searxng-stack.service may not be active -- check: pct exec $CT_ID -- journalctl -u searxng-stack --no-pager -n 50" >&2
fi

RUNNING=0
echo -n "  Waiting for containers to start ."
for i in $(seq 1 60); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc 'podman ps --format "{{.Names}}" 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  if [[ "$RUNNING" -ge "$EXPECTED_CONTAINERS" ]]; then
    echo " ok"
    break
  fi
  echo -n "."
  sleep 2
done
pct exec "$CT_ID" -- bash -lc 'cd /opt/searxng && podman-compose ps' || true

# The limiter is always active and rejects plain curl from localhost
# (no X-Forwarded-For header). Skip HTTP check — container count and service
# state above are sufficient confirmation.
echo "  HTTP health check skipped (limiter blocks localhost curl — verify from browser)"
echo "  Verify: curl -I http://${CT_IP}:${APP_PORT}/"

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
  sysctl --system >/dev/null 2>&1 || true
'

# ── Host sysctl — Valkey memory overcommit (public mode only) ─────────────────
# vm.overcommit_memory is a host kernel parameter. Unprivileged LXC containers
# share the host kernel and cannot set it themselves. Valkey logs a warning when
# it is not set, which indicates background saves or replication may fail under
# memory pressure. For rate-limit-only use the risk is minimal, but the warning
# is still noise. Setting it on the host silences it for all LXCs on this node.
OVERCOMMIT_CONF="/etc/sysctl.d/99-valkey-overcommit.conf"
  if [[ ! -f "$OVERCOMMIT_CONF" ]] || ! grep -q "^vm.overcommit_memory" "$OVERCOMMIT_CONF" 2>/dev/null; then
    echo "  Applying vm.overcommit_memory = 1 on Proxmox host ..."
    echo "vm.overcommit_memory = 1" > "$OVERCOMMIT_CONF"
    sysctl -w vm.overcommit_memory=1 >/dev/null
    echo "  Host sysctl: vm.overcommit_memory = 1 (written to ${OVERCOMMIT_CONF})"
  else
    echo "  Host sysctl: vm.overcommit_memory already configured, skipping."
  fi

# ── Cleanup packages ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y man-db manpages 2>/dev/null || true
  apt-get -y autoremove
  apt-get clean
'

# ── MOTD (dynamic drop-ins) ───────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  > /etc/motd
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
  rm -f /etc/update-motd.d/*
'

pct exec "$CT_ID" -- bash -lc 'cat > /etc/update-motd.d/00-header && chmod +x /etc/update-motd.d/00-header' <<'MOTD'
#!/bin/sh
printf '\n  SearXNG (Podman)\n'
printf '  ────────────────────────────────────\n'
MOTD

pct exec "$CT_ID" -- bash -lc 'cat > /etc/update-motd.d/10-sysinfo && chmod +x /etc/update-motd.d/10-sysinfo' <<'MOTD'
#!/bin/sh
ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
printf '  Hostname:  %s\n' "$(hostname)"
printf '  IP:        %s\n' "${ip:-n/a}"
printf '  Uptime:    %s\n' "$(uptime -p 2>/dev/null || uptime)"
printf '  Disk:      %s\n' "$(df -h / | awk 'NR==2{printf "%s/%s (%s used)", $3, $2, $5}')"
MOTD

# Unquoted heredoc: APP_PORT, PUBLIC_FQDN, MODE_LABEL expand at script run time.
# Runtime vars (service_active, ip, etc.) use \$ -- evaluated by the MOTD script on login.
MODE_LABEL="local (limiter + Valkey)"
[[ "$PUBLIC_INSTANCE" -eq 1 ]] && MODE_LABEL="public (limiter + Valkey + public_instance)"

pct exec "$CT_ID" -- bash -lc 'cat > /etc/update-motd.d/30-app && chmod +x /etc/update-motd.d/30-app' <<MOTD_APP
#!/bin/sh
service_active=\$(systemctl is-active searxng-stack.service 2>/dev/null || echo 'unknown')
configured_image=\$(awk -F= '/^SEARXNG_IMAGE=/{print \$2}' /opt/searxng/.env 2>/dev/null | tail -n1)
running=\$(podman ps --format '{{.Names}}' 2>/dev/null | wc -l)
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '  Mode:      ${MODE_LABEL}\n'
printf '  Stack:     /opt/searxng (%s containers running)\n' "\$running"
printf '  Service:   %s\n' "\$service_active"
printf '  Image:     %s\n' "\${configured_image:-n/a}"
printf '  Backup:    /opt/searxng-backups\n'
printf '  Compose:   cd /opt/searxng && podman-compose [up -d|down|logs|ps]\n'
printf '  Maintain:  searxng-maint.sh [backup|list|restore|update|version]\n'
printf '  Web UI:    http://%s:${APP_PORT}/\n' "\${ip:-n/a}"
[ -n '${PUBLIC_FQDN}' ] && printf '  Public:    https://${PUBLIC_FQDN}/\n' || true
MOTD_APP

pct exec "$CT_ID" -- bash -lc 'cat > /etc/update-motd.d/99-footer && chmod +x /etc/update-motd.d/99-footer' <<'MOTD'
#!/bin/sh
printf '  ────────────────────────────────────\n\n'
MOTD

# ── Proxmox UI description ────────────────────────────────────────────────────
INSTANCE_MODE_DESC="local (limiter + Valkey)"
[[ "$PUBLIC_INSTANCE" -eq 1 ]] && INSTANCE_MODE_DESC="public (limiter + Valkey + public_instance)"

if [[ -n "$PUBLIC_FQDN" ]]; then
  SEARXNG_DESC="<a href='https://${PUBLIC_FQDN}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>SearXNG (public)</a>
<details><summary>Details</summary>SearXNG ${SEARXNG_TAG} on Debian ${DEBIAN_VERSION} LXC
Podman -- ${INSTANCE_MODE_DESC}
Created by searxng-podman.sh</details>"
else
  SEARXNG_DESC="<a href='http://${CT_IP}:${APP_PORT}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>SearXNG (local)</a>
<details><summary>Details</summary>SearXNG ${SEARXNG_TAG} on Debian ${DEBIAN_VERSION} LXC
Podman -- ${INSTANCE_MODE_DESC}
Created by searxng-podman.sh</details>"
fi
pct set "$CT_ID" --description "$SEARXNG_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── TERM fix ──────────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  CT: $CT_ID | IP: ${CT_IP} | Login: $([ -n "$PASSWORD" ] && echo 'password set' || echo 'no password set')"
echo ""
echo "  Mode: $([ "$PUBLIC_INSTANCE" -eq 1 ] && echo "public (limiter + Valkey + public_instance)" || echo "local (limiter + Valkey)")"
echo ""
echo "  Access (local):"
echo "    Web UI: http://${CT_IP}:${APP_PORT}/"
if [[ -n "$PUBLIC_FQDN" ]]; then
  echo ""
  echo "  Access (public):"
  echo "    Web UI: https://${PUBLIC_FQDN}/"
fi
echo ""
echo "  Config files:"
echo "    ${APP_DIR}/config/settings.yml   (SearXNG configuration)"
echo "    ${APP_DIR}/.env                  (runtime policy)"
echo "    ${APP_DIR}/docker-compose.yml    (compose stack)"
echo ""
echo "  Persistent paths:"
echo "    ${APP_DIR}/config/              (settings.yml)"
echo "    ${APP_DIR}/cache/               (favicon DB, request cache)"
echo "    ${APP_DIR}/valkey/              (Valkey rate-limit counters)"
echo ""
echo "  Maintenance:"
echo "    Policy: AUTO_UPDATE=${AUTO_UPDATE} TRACK_LATEST=${TRACK_LATEST}"
echo "    pct exec $CT_ID -- searxng-maint.sh backup"
echo "    pct exec $CT_ID -- searxng-maint.sh list"
echo "    pct exec $CT_ID -- searxng-maint.sh update <tag|latest>"
echo "    pct exec $CT_ID -- searxng-maint.sh restore /opt/searxng-backups/<backup.tar.gz>"
echo "    pct exec $CT_ID -- searxng-maint.sh auto-update"
if [[ -n "$PUBLIC_FQDN" ]]; then
  echo ""
  echo "  Reverse proxy (NPM):"
  echo "    ${PUBLIC_FQDN} -> http://${CT_IP}:${APP_PORT}"
  echo "    Enable WebSockets in NPM for full SearXNG compatibility."
fi
echo ""
echo "  Done."
