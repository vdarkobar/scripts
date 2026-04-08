#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID=""                             # assigned after preflight validates pvesh
HN="npm"
CPU=4
RAM=4096
DISK=8
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Nginx Proxy Manager / Podman + Quadlet
APP_PORT=81                          # hardcoded by NPM; not remappable with Network=host
APP_TZ="Europe/Berlin"
TAGS="npm;podman;quadlet;lxc"

# Images / versions
APP_IMAGE_REPO="docker.io/jc21/nginx-proxy-manager"
APP_TAG="2.14.0"                     # pinned default; ignored when AUTO_UPDATE=1
DEBIAN_VERSION=13

# Optional features / policy
INSTALL_CLOUDFLARED=0                # 1 = install cloudflared inside CT
NPM_DISABLE_IPV6=0                   # 1 = set DISABLE_IPV6=true for NPM app container

# Initial admin account (optional)
# When both are set, NPM skips the first-run setup wizard and creates this
# admin user automatically. Leave empty for interactive setup on first visit.
INITIAL_ADMIN_EMAIL=""               # e.g. admin@example.com
INITIAL_ADMIN_PASSWORD=""            # min 8 characters

# Auto-update policy
# AUTO_UPDATE=0 (default): installs the pinned APP_TAG, timer disabled, manual
#   updates via npm-maint.sh update <tag>
# AUTO_UPDATE=1: ignores APP_TAG, installs and tracks :latest, timer enabled —
#   the timer re-pulls :latest and restarts on schedule
AUTO_UPDATE=0

# Behavior
CLEANUP_ON_FAIL=1

# Derived — resolved after validation; APP_IMAGE set below
APP_DIR="/opt/npm"
QUADLET_FILE="/etc/containers/systemd/npm.container"
QUADLET_SERVICE="npm.service"

# ── Custom configs created by this script ─────────────────────────────────────
#   /etc/containers/systemd/npm.container        (Quadlet unit — source of truth)
#   /opt/npm/.env                                (runtime state — read by maint script)
#   /opt/npm/data/                               (NPM data — SQLite DB, config, nginx)
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
[[ "$AUTO_UPDATE" =~ ^[01]$ ]] || { echo "  ERROR: AUTO_UPDATE must be 0 or 1." >&2; exit 1; }
[[ "$INSTALL_CLOUDFLARED" =~ ^[01]$ ]] || { echo "  ERROR: INSTALL_CLOUDFLARED must be 0 or 1." >&2; exit 1; }
[[ "$NPM_DISABLE_IPV6" =~ ^[01]$ ]] || { echo "  ERROR: NPM_DISABLE_IPV6 must be 0 or 1." >&2; exit 1; }
[[ "$CLEANUP_ON_FAIL" =~ ^[01]$ ]] || { echo "  ERROR: CLEANUP_ON_FAIL must be 0 or 1." >&2; exit 1; }
[[ -n "$APP_IMAGE_REPO" && ! "$APP_IMAGE_REPO" =~ [[:space:]] ]] || {
  echo "  ERROR: APP_IMAGE_REPO must be non-empty and contain no spaces." >&2
  exit 1
}
[[ "$APP_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: APP_TAG must be a pinned version like 2.14.0." >&2
  exit 1
}
[[ -e "/usr/share/zoneinfo/${APP_TZ}" ]] || { echo "  ERROR: APP_TZ not found in /usr/share/zoneinfo: $APP_TZ" >&2; exit 1; }

if [[ -n "$INITIAL_ADMIN_EMAIL" || -n "$INITIAL_ADMIN_PASSWORD" ]]; then
  [[ -n "$INITIAL_ADMIN_EMAIL" && -n "$INITIAL_ADMIN_PASSWORD" ]] || {
    echo "  ERROR: INITIAL_ADMIN_EMAIL and INITIAL_ADMIN_PASSWORD must both be set or both be empty." >&2
    exit 1
  }
  [[ "$INITIAL_ADMIN_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]] || {
    echo "  ERROR: INITIAL_ADMIN_EMAIL does not look like a valid email address." >&2
    exit 1
  }
  [[ ${#INITIAL_ADMIN_PASSWORD} -ge 8 ]] || {
    echo "  ERROR: INITIAL_ADMIN_PASSWORD must be at least 8 characters." >&2
    exit 1
  }
  unsafe_pw_re="['\"\$\`\\\\]"
  if [[ "$INITIAL_ADMIN_PASSWORD" =~ $unsafe_pw_re ]]; then
    echo "  ERROR: INITIAL_ADMIN_PASSWORD must not contain quotes, dollar signs, backticks, or backslashes." >&2
    exit 1
  fi
fi

# Resolve effective image: AUTO_UPDATE=1 overrides the pinned tag with :latest
if [[ "$AUTO_UPDATE" -eq 1 ]]; then
  APP_IMAGE="${APP_IMAGE_REPO}:latest"
else
  APP_IMAGE="${APP_IMAGE_REPO}:${APP_TAG}"
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

CT_ID="$(pvesh get /cluster/nextid)"
[[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }

# ── Discover available resources ──────────────────────────────────────────────
AVAIL_TMPL_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'vztmpl' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_CT_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^vmbr' | sort | paste -sd, | sed 's/,/, /g' || echo "n/a")"

# ── Show defaults & confirm ───────────────────────────────────────────────────
cat <<EOF2

  NPM-Quadlet LXC Creator — Configuration
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
  App image:         $APP_IMAGE
  App port (admin):  $APP_PORT (fixed by NPM)
  Database:          SQLite (embedded)
  Timezone:          $APP_TZ
  Tags:              $TAGS
  Disable IPv6 app:  $([ "$NPM_DISABLE_IPV6" -eq 1 ] && echo "yes" || echo "no")
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled (:latest)" || echo "disabled (pinned $APP_TAG)")
  Initial admin:     $([ -n "$INITIAL_ADMIN_EMAIL" ] && echo "$INITIAL_ADMIN_EMAIL (auto-provisioned)" || echo "(setup wizard on first visit)")
  Cloudflare Tunnel: $([ "$INSTALL_CLOUDFLARED" -eq 1 ] && echo "yes" || echo "no")
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/npm-quadlet.sh"
SCRIPT_LOCAL="/root/npm-quadlet.sh"
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
  read -r -s -p "  Set root password: " PW1; echo
  if [[ -z "$PW1" ]]; then echo "  Password cannot be blank."; continue; fi
  if [[ "$PW1" == *" "* ]]; then echo "  Password cannot contain spaces."; continue; fi
  if [[ ${#PW1} -lt 8 ]]; then echo "  Password must be at least 8 characters."; continue; fi
  read -r -s -p "  Verify root password: " PW2; echo
  if [[ "$PW1" == "$PW2" ]]; then PASSWORD="$PW1"; break; fi
  echo "  Passwords do not match. Try again."
done

echo ""

# ── Cloudflare Tunnel token ───────────────────────────────────────────────────
TUNNEL_TOKEN=""
if [[ "$INSTALL_CLOUDFLARED" -eq 1 ]]; then
  echo "  Cloudflare Tunnel token is required."
  echo "  Get it from: Zero Trust dashboard → Networks → Tunnels"
  echo "  Token looks like: eyJhIjoiNjk2..."
  echo ""
  while true; do
    read -r -p "  Tunnel token: " TUNNEL_TOKEN
    [[ -z "$TUNNEL_TOKEN" ]] && { echo "  Token cannot be empty."; continue; }
    if [[ ! "$TUNNEL_TOKEN" =~ ^eyJ ]]; then
      read -r -p "  Token format looks unusual (should usually start with 'eyJ'). Continue? [y/N]: " cf_confirm
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
  apt-get install -y locales curl ca-certificates iproute2 podman fuse-overlayfs tar gzip
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
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  install -d -m 0755 '${APP_DIR}'
  install -d -m 0755 '${APP_DIR}/data' '${APP_DIR}/letsencrypt'
"

# ── Quadlet unit file ─────────────────────────────────────────────────────────
# Rootful Quadlet: /etc/containers/systemd/ — no linger, no --user flags needed.
# systemd daemon-reload triggers the Quadlet generator; npm.service is created
# as a transient unit and WantedBy=multi-user.target handles boot start.
# Network=host bypasses Netavark NAT issues on Debian LXC.
# No DB_MYSQL_* env vars — NPM defaults to embedded SQLite at /data/database.sqlite.

DISABLE_IPV6_ENV=""
[[ "$NPM_DISABLE_IPV6" -eq 1 ]] && DISABLE_IPV6_ENV="true"

INITIAL_ADMIN_LINES=""
if [[ -n "$INITIAL_ADMIN_EMAIL" && -n "$INITIAL_ADMIN_PASSWORD" ]]; then
  INITIAL_ADMIN_LINES="Environment=INITIAL_ADMIN_EMAIL=${INITIAL_ADMIN_EMAIL}
Environment=INITIAL_ADMIN_PASSWORD=${INITIAL_ADMIN_PASSWORD}"
fi

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
Environment=DISABLE_IPV6=${DISABLE_IPV6_ENV}
${INITIAL_ADMIN_LINES}
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
# truth for current image and policy flags. Keep it in sync with the Quadlet
# unit whenever the image is updated.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > '${APP_DIR}/.env' <<EOF2
APP_IMAGE_REPO=${APP_IMAGE_REPO}
APP_IMAGE=${APP_IMAGE}
APP_PORT=${APP_PORT}
APP_TZ=${APP_TZ}
NPM_DISABLE_IPV6=${NPM_DISABLE_IPV6}
AUTO_UPDATE=${AUTO_UPDATE}
EOF2
  chmod 0600 '${APP_DIR}/.env'
"

# ── Maintenance script ────────────────────────────────────────────────────────
# Manual update: pull new pinned tag → sed Quadlet + .env → daemon-reload → restart
# Auto-update:   re-pull :latest → restart (only when AUTO_UPDATE=1)
# Rollback:      restore both files → daemon-reload → restart
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/npm-maint.sh && chmod 0755 /usr/local/bin/npm-maint.sh' <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR="${APP_DIR:-/opt/npm}"
QUADLET_FILE="/etc/containers/systemd/npm.container"
SERVICE="npm.service"
ENV_FILE="${APP_DIR}/.env"

need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF2
  NPM Maintenance (Quadlet)
  ─────────────────────────
  Usage:
    $0 update <tag>       # pin a specific version (e.g. 2.15.0), disables auto-update
    $0 auto-update        # re-pull :latest and restart (only if AUTO_UPDATE=1)
    $0 version

  Notes:
    - update switches to a pinned tag and sets AUTO_UPDATE=0
    - auto-update is called by the systemd timer when AUTO_UPDATE=1
    - backup and restore are handled by PBS and PVE snapshots
    - take a PVE snapshot before manual updates: pct snapshot <CT_ID> pre-update-\$(date +%Y%m%d)
EOF2
}

[[ -d "$APP_DIR" ]]      || die "APP_DIR not found: $APP_DIR"
[[ -f "$ENV_FILE" ]]     || die "Missing env file: $ENV_FILE"
[[ -f "$QUADLET_FILE" ]] || die "Missing Quadlet unit: $QUADLET_FILE"

env_val() {
  awk -F= -v key="$1" '$1==key{print $2}' "$ENV_FILE" | tail -n1
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

wait_for_admin() {
  local port code
  port="$(app_port)"
  for i in $(seq 1 45); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${port}/" 2>/dev/null || echo 000)"
    case "$code" in
      200|301|302|401|403) return 0 ;;
    esac
    sleep 2
  done
  return 1
}

# update <tag> — switch to a pinned version, disable auto-update
update_app() {
  local new_tag="" skip_confirm=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) skip_confirm=1; shift ;;
      *) new_tag="$1"; shift ;;
    esac
  done

  [[ -n "$new_tag" ]] || die "Usage: npm-maint.sh update <tag>"
  [[ "$new_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] \
    || die "Invalid tag: $new_tag — must be a pinned version (e.g. 2.15.0)."

  local repo new_image tmp_env tmp_quadlet
  repo="$(env_val APP_IMAGE_REPO)"
  [[ -n "$repo" ]] || die "Could not read APP_IMAGE_REPO from .env"
  new_image="${repo}:${new_tag}"
  tmp_env="$(mktemp)"
  tmp_quadlet="$(mktemp)"

  echo "  Current image: $(current_image)"
  echo "  Target  image: $new_image"

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
    systemctl daemon-reload
    systemctl restart "$SERVICE" || true
    rm -f "$tmp_env" "$tmp_quadlet"
  }
  trap rollback ERR

  echo "  Pulling target image ..."
  podman pull "$new_image"

  sed -i "s|^Image=.*|Image=${new_image}|" "$QUADLET_FILE"
  sed -i \
    -e "s|^APP_IMAGE=.*|APP_IMAGE=$new_image|" \
    -e "s|^AUTO_UPDATE=.*|AUTO_UPDATE=0|" \
    "$ENV_FILE"

  echo "  Reloading Quadlet and restarting service ..."
  systemctl daemon-reload
  systemctl restart "$SERVICE"

  echo "  Waiting for admin UI ..."
  if ! wait_for_admin; then
    trap - ERR
    rollback
    die "NPM admin UI did not become reachable after update."
  fi

  trap - ERR
  cleanup

  # Disable the timer since we just pinned a tag
  systemctl disable --now npm-update.timer >/dev/null 2>&1 || true
  echo "  OK: NPM pinned to $new_tag (auto-update disabled)"
}

# auto-update — re-pull :latest and restart (timer-driven)
auto_update_app() {
  if [[ "$(env_flag AUTO_UPDATE)" != "1" ]]; then
    echo "  Auto-update disabled in ${ENV_FILE}; nothing to do."
    return 0
  fi

  local repo image
  repo="$(env_val APP_IMAGE_REPO)"
  [[ -n "$repo" ]] || die "Could not read APP_IMAGE_REPO from .env"
  image="${repo}:latest"

  local tmp_env tmp_quadlet
  tmp_env="$(mktemp)"
  tmp_quadlet="$(mktemp)"

  cp -a "$ENV_FILE"     "$tmp_env"
  cp -a "$QUADLET_FILE" "$tmp_quadlet"

  cleanup() { rm -f "$tmp_env" "$tmp_quadlet"; }
  rollback() {
    echo "  !! Auto-update failed — rolling back and restarting ..." >&2
    cp -a "$tmp_env"     "$ENV_FILE"
    cp -a "$tmp_quadlet" "$QUADLET_FILE"
    systemctl daemon-reload
    systemctl restart "$SERVICE" || true
    rm -f "$tmp_env" "$tmp_quadlet"
  }
  trap rollback ERR

  echo "  Auto-update: pulling ${image} ..."
  podman pull "$image"

  sed -i "s|^Image=.*|Image=${image}|" "$QUADLET_FILE"
  sed -i "s|^APP_IMAGE=.*|APP_IMAGE=$image|" "$ENV_FILE"

  echo "  Reloading Quadlet and restarting service ..."
  systemctl daemon-reload
  systemctl restart "$SERVICE"

  echo "  Waiting for admin UI ..."
  if ! wait_for_admin; then
    trap - ERR
    rollback
    die "NPM admin UI did not become reachable after auto-update."
  fi

  trap - ERR
  cleanup
  echo "  OK: NPM auto-updated to latest"
}

need_root
cmd="${1:-}"
case "$cmd" in
  update)      shift; update_app "$@" ;;
  auto-update) auto_update_app ;;
  version)
    echo "Configured image: $(current_image)"
    echo "AUTO_UPDATE=$(env_flag AUTO_UPDATE)"
    ;;
  ""|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
MAINT
echo "  Maintenance script deployed: /usr/local/bin/npm-maint.sh"

# ── Start via Quadlet ─────────────────────────────────────────────────────────
# daemon-reload triggers the Quadlet generator which produces npm.service as a
# transient systemd unit. WantedBy=multi-user.target handles boot restarts.
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
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc "curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:${APP_PORT}/ 2>/dev/null" 2>/dev/null || echo 000)"
  case "$HTTP_CODE" in
    200|301|302|401|403)
      NPM_HEALTHY=1
      break
      ;;
  esac
  sleep 2
done

if [[ "$NPM_HEALTHY" -eq 1 ]]; then
  echo "  NPM admin check passed (HTTP $HTTP_CODE)"
else
  echo "  ERROR: NPM admin UI is not reachable on port ${APP_PORT}" >&2
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
      | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null

    echo "deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main" \
      > /etc/apt/sources.list.d/cloudflared.list

    apt-get update -qq
    apt-get install -y cloudflared
    cloudflared --version
  '

  pct exec "$CT_ID" -- bash -lc "cloudflared service install '${TUNNEL_TOKEN}'"
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
printf '\n  Nginx Proxy Manager (Podman/Quadlet)\n'
printf '  ────────────────────────────────────\n'
MOTD

  cat > /etc/update-motd.d/10-sysinfo <<'MOTD'
#!/bin/sh
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '  Hostname:  %s\n' \"\$(hostname)\"
printf '  IP:        %s\n' \"\${ip:-n/a}\"
printf '  Uptime:    %s\n' \"\$(uptime -p 2>/dev/null || uptime)\"
printf '  Disk:      %s\n' \"\$(df -h / | awk 'NR==2{printf \"%s/%s (%s used)\", \$3, \$2, \$5}')\"
MOTD

  cat > /etc/update-motd.d/30-app <<'MOTD'
#!/bin/sh
running=\$(podman ps --filter name=^npm$ --format '{{.Names}}' 2>/dev/null | wc -l)
svc_status=\$(systemctl is-active npm.service 2>/dev/null || echo 'unknown')
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
image=\$(awk -F= '/^APP_IMAGE=/{print \$2}' /opt/npm/.env 2>/dev/null | tail -n1)
auto=\$(awk -F= '/^AUTO_UPDATE=/{print \$2}' /opt/npm/.env 2>/dev/null | tail -n1)
printf '  Container: npm (%s running)\n' \"\$running\"
printf '  Service:   npm.service (%s)\n' \"\$svc_status\"
printf '  Image:     %s\n' \"\${image:-n/a}\"
printf '  Database:  SQLite (embedded)\n'
printf '  Policy:    %s\n' \"\$([ \"\$auto\" = '1' ] && echo 'auto-update (:latest)' || echo 'pinned (manual)')\"
printf '  Logs:      journalctl -u npm.service -f\n'
printf '  Maintain:  /usr/local/bin/npm-maint.sh [update|auto-update|version]\n'
printf '  Updates:   systemctl status npm-update.timer\n'
printf '  Admin UI:  http://%s:81\n' \"\${ip:-n/a}\"
MOTD

  cat > /etc/update-motd.d/99-footer <<'MOTD'
#!/bin/sh
printf '  ────────────────────────────────────\n\n'
MOTD

  chmod +x /etc/update-motd.d/*
"

if [[ "$INSTALL_CLOUDFLARED" -eq 1 && -n "$TUNNEL_TOKEN" ]]; then
  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    cat > /etc/update-motd.d/35-cloudflared <<'\''MOTD'\''
#!/bin/sh
if command -v cloudflared >/dev/null 2>&1; then
  status=$(systemctl is-active cloudflared 2>/dev/null || echo "unknown")
  printf "  Tunnel:    cloudflared (%s)\n" "$status"
fi
MOTD
    chmod +x /etc/update-motd.d/35-cloudflared
  '
fi

pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Proxmox UI description ────────────────────────────────────────────────────
CF_NOTE=""
[[ "$INSTALL_CLOUDFLARED" -eq 1 && -n "$TUNNEL_TOKEN" ]] && CF_NOTE=" + Cloudflare Tunnel"
NPM_DESC="<a href='http://${CT_IP}:${APP_PORT}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>NPM Admin</a>
<details><summary>Details</summary>Nginx Proxy Manager (Podman/Quadlet, SQLite)${CF_NOTE} on Debian ${DEBIAN_VERSION} LXC
Created by npm-quadlet.sh</details>"
pct set "$CT_ID" --description "$NPM_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "    CT: $CT_ID | IP: ${CT_IP} | Admin: http://${CT_IP}:${APP_PORT}"
echo "    Image:   ${APP_IMAGE}"
echo "    DB:      SQLite (embedded at /data/database.sqlite)"
echo "    Quadlet: ${QUADLET_FILE}"
echo "    Policy:  $([ "$AUTO_UPDATE" -eq 1 ] && echo "auto-update (:latest)" || echo "pinned (manual)")"
echo ""
echo "    pct exec $CT_ID -- systemctl status npm.service"
echo "    pct exec $CT_ID -- journalctl -u npm.service --no-pager -n 50"
echo "    pct exec $CT_ID -- /usr/local/bin/npm-maint.sh update <tag>  # pin version, disables auto-update"
echo "    pct exec $CT_ID -- /usr/local/bin/npm-maint.sh auto-update   # re-pull :latest (if AUTO_UPDATE=1)"
echo "    pct exec $CT_ID -- /usr/local/bin/npm-maint.sh version"
echo "    Backup/restore: use PBS or PVE snapshots"
echo ""
echo "    NPM reverse proxy (from another host): http | ${CT_IP}:<port> | enable Websockets Support"
if [[ -n "$INITIAL_ADMIN_EMAIL" ]]; then
  echo "    Admin account pre-created: ${INITIAL_ADMIN_EMAIL}"
else
  echo "    First visit opens the setup wizard to create the admin account."
fi
echo ""
