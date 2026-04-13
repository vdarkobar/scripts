#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID=""                             # assigned after preflight validates pvesh
HN="changedetection"
CPU=2
RAM=2048
DISK=8
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# changedetection.io / Podman
APP_PORT=5000
APP_TZ="Europe/Berlin"
PUBLIC_FQDN=""                       # e.g. watch.example.com ; blank = local IP mode
TAGS="changedetection;podman;lxc"

# Images / versions
APP_IMAGE_REPO="ghcr.io/dgtlmoon/changedetection.io"
APP_TAG="0.54.7"                     # pinned stable; do not default to :latest
BROWSER_IMAGE_REPO="docker.io/dgtlmoon/sockpuppetbrowser"
BROWSER_TAG="0.0.3"                  # pinned; upstream also publishes :latest
DEBIAN_VERSION=13

# Optional features / policy
AUTO_UPDATE=0                        # 1 = enable timer-driven maintenance/update runs
TRACK_LATEST=0                       # 1 = auto-update follows :latest instead of pinned tag
BROWSER_SYS_ADMIN=1                  # pragmatic default for Chrome in LXC/Podman; try 0 first if tightening

# Extra packages to install (space-separated or array)
EXTRA_PACKAGES=(
  qemu-guest-agent
)

# Behavior
CLEANUP_ON_FAIL=1

# Derived
APP_DIR="/opt/changedetection"
APP_IMAGE="${APP_IMAGE_REPO}:${APP_TAG}"
BROWSER_IMAGE="${BROWSER_IMAGE_REPO}:${BROWSER_TAG}"

# ── Custom configs created by this script ─────────────────────────────────────
#   /opt/changedetection/docker-compose.yml   (Podman compose stack)
#   /opt/changedetection/.env                 (runtime configuration)
#   /opt/changedetection/datastore/           (app data — watches, snapshots, DB)
#   /usr/local/bin/changedetection-maint.sh   (maintenance helper)
#   /etc/systemd/system/changedetection-stack.service
#   /etc/systemd/system/changedetection-update.service
#   /etc/systemd/system/changedetection-update.timer
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/sysctl.d/99-hardening.conf

# ── Config validation ─────────────────────────────────────────────────────────
[[ "$CPU" =~ ^[0-9]+$ ]] || { echo "  ERROR: CPU must be numeric." >&2; exit 1; }
(( CPU >= 1 && CPU <= 128 )) || { echo "  ERROR: CPU must be between 1 and 128." >&2; exit 1; }
[[ "$RAM" =~ ^[0-9]+$ ]] || { echo "  ERROR: RAM must be numeric." >&2; exit 1; }
(( RAM >= 256 )) || { echo "  ERROR: RAM must be at least 256 MB." >&2; exit 1; }
[[ "$DISK" =~ ^[0-9]+$ ]] || { echo "  ERROR: DISK must be numeric." >&2; exit 1; }
(( DISK >= 2 )) || { echo "  ERROR: DISK must be at least 2 GB." >&2; exit 1; }
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }
[[ "$APP_PORT" =~ ^[0-9]+$ ]] || { echo "  ERROR: APP_PORT must be numeric." >&2; exit 1; }
(( APP_PORT >= 1 && APP_PORT <= 65535 )) || { echo "  ERROR: APP_PORT must be between 1 and 65535." >&2; exit 1; }
[[ "$AUTO_UPDATE" =~ ^[01]$ ]] || { echo "  ERROR: AUTO_UPDATE must be 0 or 1." >&2; exit 1; }
[[ "$TRACK_LATEST" =~ ^[01]$ ]] || { echo "  ERROR: TRACK_LATEST must be 0 or 1." >&2; exit 1; }
[[ "$BROWSER_SYS_ADMIN" =~ ^[01]$ ]] || { echo "  ERROR: BROWSER_SYS_ADMIN must be 0 or 1." >&2; exit 1; }
[[ "$APP_TAG" == "latest" || "$APP_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: APP_TAG must look like 0.54.7 or latest." >&2
  exit 1
}
[[ "$BROWSER_TAG" == "latest" || "$BROWSER_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: BROWSER_TAG must look like 0.0.3 or latest." >&2
  exit 1
}
[[ "$APP_IMAGE_REPO" =~ ^[a-z0-9] ]] || { echo "  ERROR: APP_IMAGE_REPO looks invalid." >&2; exit 1; }
[[ "$BROWSER_IMAGE_REPO" =~ ^[a-z0-9] ]] || { echo "  ERROR: BROWSER_IMAGE_REPO looks invalid." >&2; exit 1; }
[[ -e "/usr/share/zoneinfo/${APP_TZ}" ]] || { echo "  ERROR: APP_TZ not found in /usr/share/zoneinfo: $APP_TZ" >&2; exit 1; }
if [[ -n "$PUBLIC_FQDN" ]]; then
  [[ "$PUBLIC_FQDN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || {
    echo "  ERROR: PUBLIC_FQDN must be a bare hostname (e.g. watch.example.com), not a URL." >&2
    exit 1
  }
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

  changedetection.io Podman LXC Creator — Configuration
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
  Browser image:     $BROWSER_IMAGE
  App port:          $APP_PORT
  Timezone:          $APP_TZ
  Public FQDN:       ${PUBLIC_FQDN:-<none — local IP mode>}
  Browser SYS_ADMIN: $([ "$BROWSER_SYS_ADMIN" -eq 1 ] && echo "yes" || echo "no")
  Tags:              $TAGS
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled" || echo "disabled")
  Track latest:      $([ "$TRACK_LATEST" -eq 1 ] && echo "enabled" || echo "disabled")
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/changedetection-podman.sh"
SCRIPT_LOCAL="/root/changedetection-podman.sh"
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
pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json
storages=json.load(sys.stdin)
match=[s for s in storages if s['storage']=='$TEMPLATE_STORAGE']
if not match or 'vztmpl' not in match[0].get('content',''):
    print('  ERROR: $TEMPLATE_STORAGE does not support vztmpl content.',file=sys.stderr); sys.exit(1)" \
  || exit 1

pvesm status | awk -v s="$CONTAINER_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Container storage not found: $CONTAINER_STORAGE" >&2; exit 1; }
pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json
storages=json.load(sys.stdin)
match=[s for s in storages if s['storage']=='$CONTAINER_STORAGE']
if not match or 'rootdir' not in match[0].get('content',''):
    print('  ERROR: $CONTAINER_STORAGE does not support rootdir content.',file=sys.stderr); sys.exit(1)" \
  || exit 1

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
  apt-get install -y locales curl ca-certificates iproute2 podman podman-compose fuse-overlayfs
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

# ── Pull images ───────────────────────────────────────────────────────────────
echo "  Pulling changedetection.io images ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman pull '${APP_IMAGE}'
  podman pull '${BROWSER_IMAGE}'
"

# ── Prepare persistent paths ──────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  install -d -m 0755 '${APP_DIR}'
  install -d -m 0755 '${APP_DIR}/datastore'
"

# ── Compose file ──────────────────────────────────────────────────────────────
BROWSER_CAP_BLOCK=""
if [[ "$BROWSER_SYS_ADMIN" -eq 1 ]]; then
  BROWSER_CAP_BLOCK=$'    cap_add:\n      - SYS_ADMIN'
fi

PROXY_ENV_BLOCK=""
if [[ -n "$PUBLIC_FQDN" ]]; then
  PROXY_ENV_BLOCK="      BASE_URL: \${BASE_URL}
      USE_X_SETTINGS: \${USE_X_SETTINGS}"
fi

pct exec "$CT_ID" -- bash -lc "cat > '${APP_DIR}/docker-compose.yml'" <<EOF2
services:
  app:
    image: \${APP_IMAGE}
    container_name: changedetection_app
    restart: unless-stopped
    ports:
      - "\${APP_PORT}:5000"
    environment:
      TZ: \${APP_TZ}
      PLAYWRIGHT_DRIVER_URL: ws://sockpuppetbrowser:3000${PROXY_ENV_BLOCK:+
${PROXY_ENV_BLOCK}}
    volumes:
      - ${APP_DIR}/datastore:/datastore:Z
    depends_on:
      sockpuppetbrowser:
        condition: service_started

  sockpuppetbrowser:
    image: \${BROWSER_IMAGE}
    container_name: changedetection_browser
    hostname: sockpuppetbrowser
    restart: unless-stopped
    environment:
      SCREEN_WIDTH: 1920
      SCREEN_HEIGHT: 1080
      SCREEN_DEPTH: 24
      MAX_CONCURRENT_CHROME_PROCESSES: 10${BROWSER_CAP_BLOCK:+
${BROWSER_CAP_BLOCK}}
EOF2

PROXY_ENV_LINES=""
if [[ -n "$PUBLIC_FQDN" ]]; then
  PROXY_ENV_LINES="BASE_URL=https://${PUBLIC_FQDN}
USE_X_SETTINGS=1"
fi

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > '${APP_DIR}/.env' <<EOF2
COMPOSE_PROJECT_NAME=changedetection
APP_IMAGE_REPO=${APP_IMAGE_REPO}
APP_TAG=${APP_TAG}
APP_IMAGE=${APP_IMAGE}
BROWSER_IMAGE_REPO=${BROWSER_IMAGE_REPO}
BROWSER_TAG=${BROWSER_TAG}
BROWSER_IMAGE=${BROWSER_IMAGE}
APP_PORT=${APP_PORT}
APP_TZ=${APP_TZ}${PROXY_ENV_LINES:+
${PROXY_ENV_LINES}}
AUTO_UPDATE=${AUTO_UPDATE}
TRACK_LATEST=${TRACK_LATEST}
EOF2
  chmod 0600 '${APP_DIR}/.env' '${APP_DIR}/docker-compose.yml'
"

# ── Maintenance script ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/changedetection-maint.sh && chmod 0755 /usr/local/bin/changedetection-maint.sh' <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR="${APP_DIR:-/opt/changedetection}"
SERVICE="changedetection-stack.service"
ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"

need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF2
  changedetection.io Maintenance
  ───────────────────────────────
  Usage:
    $0 update [<tag|latest>]
    $0 update-browser [<tag|latest>]
    $0 auto-update
    $0 version

  Notes:
    - update pulls the new app image and recreates the full stack
      (podman-compose single-service recreation is unreliable)
    - update-browser changes the browser sidecar image tag
    - take a PVE snapshot before manual updates (pct snapshot <CT_ID> pre-update)
    - auto-update obeys AUTO_UPDATE and TRACK_LATEST from ${ENV_FILE}
    - all backup and restore is handled by PBS and PVE snapshots
EOF2
}

[[ -d "$APP_DIR" ]] || die "APP_DIR not found: $APP_DIR"
[[ -f "$ENV_FILE" ]] || die "Missing env file: $ENV_FILE"
[[ -f "$COMPOSE_FILE" ]] || die "Missing compose file: $COMPOSE_FILE"

current_image() {
  awk -F= '/^APP_IMAGE=/{print $2}' "$ENV_FILE" | tail -n1
}

current_repo() {
  awk -F= '/^APP_IMAGE_REPO=/{print $2}' "$ENV_FILE" | tail -n1
}

current_tag() {
  local img
  img="$(current_image)"
  echo "${img##*:}"
}

current_browser_image() {
  awk -F= '/^BROWSER_IMAGE=/{print $2}' "$ENV_FILE" | tail -n1
}

current_browser_repo() {
  awk -F= '/^BROWSER_IMAGE_REPO=/{print $2}' "$ENV_FILE" | tail -n1
}

current_browser_tag() {
  local img
  img="$(current_browser_image)"
  echo "${img##*:}"
}

env_flag() {
  local key="$1" raw
  raw="$(awk -F= -v key="$key" '$1==key{print $2}' "$ENV_FILE" | tail -n1 | tr -d '[:space:]')"
  [[ "$raw" =~ ^[01]$ ]] && printf '%s' "$raw" || printf '0'
}

auto_update_enabled() {
  [[ "$(env_flag AUTO_UPDATE)" == "1" ]]
}

track_latest_enabled() {
  [[ "$(env_flag TRACK_LATEST)" == "1" ]]
}

resolve_auto_tag() {
  if track_latest_enabled; then
    printf '%s\n' latest
  else
    current_tag
  fi
}

wait_for_app() {
  local port code
  port="$(awk -F= '/^APP_PORT=/{print $2}' "$ENV_FILE" | tail -n1 | tr -d '[:space:]')"
  [[ "$port" =~ ^[0-9]+$ ]] || port=5000
  for i in $(seq 1 45); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${port}/" 2>/dev/null || echo 000)"
    case "$code" in
      200|301|302|401|403) return 0 ;;
    esac
    sleep 2
  done
  return 1
}

recreate_stack() {
  cd "$APP_DIR"
  /usr/bin/podman-compose down || true
  /usr/bin/podman-compose up -d
}

update_app() {
  local new_tag="$1"
  local old_image new_image tmp_env old_tag repo

  [[ -n "$new_tag" ]] || {
    new_tag="$(current_tag)"
    echo "  No tag specified — re-pulling current tag: $new_tag"
  }
  [[ "$new_tag" == "latest" || "$new_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || die "Invalid tag: $new_tag"

  old_image="$(current_image)"
  old_tag="$(current_tag)"
  repo="$(current_repo)"
  [[ -n "$old_image" ]] || die "Could not read current APP_IMAGE from .env"
  [[ -n "$repo" ]] || die "Could not read APP_IMAGE_REPO from .env"
  new_image="${repo}:${new_tag}"
  tmp_env="$(mktemp)"

  echo "  Current app tag: $old_tag"
  echo "  Target  app tag: $new_tag"

  if [[ -t 0 ]]; then
    echo ""
    echo "  REMINDER: Take a PVE snapshot before proceeding."
    echo "            pct snapshot <CT_ID> pre-update"
    echo ""
    read -r -p "  Continue with update? [y/N]: " confirm
    case "$confirm" in
      [yY][eE][sS]|[yY]) ;;
      *) echo "  Aborted."; exit 0 ;;
    esac
  fi

  cp -a "$ENV_FILE" "$tmp_env"

  cleanup() { rm -f "$tmp_env"; }
  rollback() {
    echo "  !! Update failed — rolling back .env and recreating stack ..." >&2
    cp -a "$tmp_env" "$ENV_FILE"
    recreate_stack || true
  }
  trap rollback ERR

  echo "  Pulling target image ..."
  podman pull "$new_image"

  sed -i \
    -e "s|^APP_TAG=.*|APP_TAG=$new_tag|" \
    -e "s|^APP_IMAGE=.*|APP_IMAGE=$new_image|" \
    "$ENV_FILE"

  echo "  Recreating stack ..."
  recreate_stack

  echo "  Waiting for web UI ..."
  if ! wait_for_app; then
    trap - ERR
    rollback
    cleanup
    die "Web UI did not become reachable after update."
  fi

  trap - ERR
  cleanup
  echo "  OK: changedetection.io updated to $new_tag"
}

update_browser() {
  local new_tag="$1"
  local old_tag repo new_image tmp_env

  [[ -n "$new_tag" ]] || {
    new_tag="$(current_browser_tag)"
    echo "  No tag specified — re-pulling current browser tag: $new_tag"
  }
  [[ "$new_tag" == "latest" || "$new_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || die "Invalid browser tag: $new_tag"

  old_tag="$(current_browser_tag)"
  repo="$(current_browser_repo)"
  [[ -n "$repo" ]] || die "Could not read BROWSER_IMAGE_REPO from .env"
  new_image="${repo}:${new_tag}"
  tmp_env="$(mktemp)"

  echo "  Current browser tag: $old_tag"
  echo "  Target  browser tag: $new_tag"

  if [[ -t 0 ]]; then
    echo ""
    echo "  REMINDER: Take a PVE snapshot before proceeding."
    echo ""
    read -r -p "  Continue with browser update? [y/N]: " confirm
    case "$confirm" in
      [yY][eE][sS]|[yY]) ;;
      *) echo "  Aborted."; exit 0 ;;
    esac
  fi

  cp -a "$ENV_FILE" "$tmp_env"

  cleanup() { rm -f "$tmp_env"; }
  rollback() {
    echo "  !! Browser update failed — rolling back .env and recreating stack ..." >&2
    cp -a "$tmp_env" "$ENV_FILE"
    recreate_stack || true
  }
  trap rollback ERR

  echo "  Pulling target browser image ..."
  podman pull "$new_image"

  sed -i \
    -e "s|^BROWSER_TAG=.*|BROWSER_TAG=$new_tag|" \
    -e "s|^BROWSER_IMAGE=.*|BROWSER_IMAGE=$new_image|" \
    "$ENV_FILE"

  echo "  Recreating stack ..."
  recreate_stack

  echo "  Waiting for web UI ..."
  if ! wait_for_app; then
    trap - ERR
    rollback
    cleanup
    die "Web UI did not become reachable after browser update."
  fi

  trap - ERR
  cleanup
  echo "  OK: sockpuppetbrowser updated to $new_tag"
}

auto_update_app() {
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

  update_app "$target_tag"
}

need_root
cmd="${1:-}"
case "$cmd" in
  update) shift; update_app "${1:-}" ;;
  update-browser) shift; update_browser "${1:-}" ;;
  auto-update) auto_update_app ;;
  version)
    echo "Configured app image:     $(current_image)"
    echo "Configured browser image: $(current_browser_image)"
    echo "AUTO_UPDATE=$(env_flag AUTO_UPDATE)"
    echo "TRACK_LATEST=$(env_flag TRACK_LATEST)"
    ;;
  ""|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
MAINT
echo "  Maintenance script deployed: /usr/local/bin/changedetection-maint.sh"

# ── Systemd stack unit ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/changedetection-stack.service <<EOF2
[Unit]
Description=changedetection.io (Podman) stack
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/changedetection
ExecStart=/usr/bin/podman-compose up -d
ExecStop=/usr/bin/podman-compose down
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF2

  systemctl daemon-reload
  systemctl enable --now changedetection-stack.service
'

# ── Disarm destructive cleanup ────────────────────────────────────────────────
CLEANUP_ON_FAIL=0

# ── Verification ──────────────────────────────────────────────────────────────
sleep 3

VERIFY_FAIL=0

if pct exec "$CT_ID" -- systemctl is-active --quiet changedetection-stack.service 2>/dev/null; then
  echo "  Stack service is active"
else
  echo "  ERROR: changedetection-stack.service is not active" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u changedetection-stack --no-pager -n 50" >&2
  VERIFY_FAIL=1
fi

RUNNING=0
for i in $(seq 1 90); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc 'podman ps --format "{{.Names}}" 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge 2 ]] && break
  sleep 2
done
pct exec "$CT_ID" -- bash -lc 'cd /opt/changedetection && podman-compose ps' || true

if [[ "$RUNNING" -lt 2 ]]; then
  echo "  ERROR: Expected 2 containers running, found $RUNNING" >&2
  echo "  Check: pct exec $CT_ID -- bash -lc 'cd /opt/changedetection && podman-compose logs --tail=80'" >&2
  VERIFY_FAIL=1
else
  echo "  Container count OK ($RUNNING running)"
fi

APP_HEALTHY=0
for i in $(seq 1 45); do
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc "curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:${APP_PORT}/ 2>/dev/null" 2>/dev/null || echo 000)"
  case "$HTTP_CODE" in
    200|301|302|401|403)
      APP_HEALTHY=1
      break
      ;;
  esac
  sleep 2
done

if [[ "$APP_HEALTHY" -eq 1 ]]; then
  echo "  HTTP health check passed (port ${APP_PORT} — HTTP $HTTP_CODE)"
else
  echo "  ERROR: App not responding on port ${APP_PORT}" >&2
  echo "  Check: pct exec $CT_ID -- bash -lc 'cd /opt/changedetection && podman-compose logs --tail=80 app'" >&2
  VERIFY_FAIL=1
fi

if (( VERIFY_FAIL == 1 )); then
  echo "" >&2
  echo "  FATAL: Core verification failed — CT $CT_ID is preserved but the install is incomplete." >&2
  echo "  Inspect the container and fix manually, or destroy and re-run." >&2
  exit 1
fi

# ── Auto-update timer (policy-driven) ─────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/changedetection-update.service <<EOF2
[Unit]
Description=changedetection.io auto-update maintenance run
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/changedetection-maint.sh auto-update
EOF2

  cat > /etc/systemd/system/changedetection-update.timer <<EOF2
[Unit]
Description=changedetection.io auto-update timer

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
  pct exec "$CT_ID" -- bash -lc 'systemctl enable --now changedetection-update.timer'
  echo "  Auto-update timer enabled"
else
  pct exec "$CT_ID" -- bash -lc 'systemctl disable --now changedetection-update.timer >/dev/null 2>&1 || true'
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
printf '\n  changedetection.io (Podman)\n'
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
running=\$(podman ps --format '{{.Names}}' 2>/dev/null | wc -l)
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '  Stack:     /opt/changedetection (%s containers running)\n' \"\$running\"
printf '  Compose:   cd /opt/changedetection && podman-compose [up -d|down|logs|ps]\n'
printf '  Maintain:  /usr/local/bin/changedetection-maint.sh [update|update-browser|auto-update|version]\n'
printf '  Updates:   systemctl status changedetection-update.timer\n'
printf '  Web UI:    http://%s:${APP_PORT}\n' \"\${ip:-n/a}\"
MOTD

  cat > /etc/update-motd.d/99-footer <<'MOTD'
#!/bin/sh
printf '  ────────────────────────────────────\n\n'
MOTD

  chmod +x /etc/update-motd.d/*
"

pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Proxmox UI description ────────────────────────────────────────────────────
CD_DESC="<a href='http://${CT_IP}:${APP_PORT}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>changedetection.io</a>
<details><summary>Details</summary>changedetection.io + sockpuppetbrowser (Podman) on Debian ${DEBIAN_VERSION} LXC
Created by changedetection-podman.sh</details>"
pct set "$CT_ID" --description "$CD_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  CT: $CT_ID | IP: ${CT_IP} | Web UI: http://${CT_IP}:${APP_PORT}"
if [[ -n "$PUBLIC_FQDN" ]]; then
echo "    Public: https://${PUBLIC_FQDN}"
echo "    Reverse-proxy target: http://${CT_IP}:${APP_PORT}"
fi
echo "    App image:     ${APP_IMAGE}"
echo "    Browser image: ${BROWSER_IMAGE}"
echo "    Policy: AUTO_UPDATE=${AUTO_UPDATE} TRACK_LATEST=${TRACK_LATEST}"
echo "    Data:   /opt/changedetection/datastore/"
echo ""
echo "    pct exec $CT_ID -- /usr/local/bin/changedetection-maint.sh update [<tag|latest>]"
echo "    pct exec $CT_ID -- /usr/local/bin/changedetection-maint.sh update-browser [<tag|latest>]"
echo "    pct exec $CT_ID -- /usr/local/bin/changedetection-maint.sh auto-update"
echo "    pct exec $CT_ID -- /usr/local/bin/changedetection-maint.sh version"
echo ""
