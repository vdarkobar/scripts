#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID="$(pvesh get /cluster/nextid)"
HN="uptime-kuma"
CPU=2
RAM=2048
DISK=8
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Uptime Kuma / Podman
APP_PORT=3001
APP_TZ="Europe/Berlin"
APP_FQDN=""                          # e.g. status.example.com ; blank = local IP mode
TAGS="uptime-kuma;podman;lxc"

# Images / versions
APP_IMAGE_REPO="docker.io/louislam/uptime-kuma"
APP_TAG="2.2.1"                      # pinned default; do not default to :latest
DEBIAN_VERSION=13

# Optional features / policy
AUTO_UPDATE=0                        # 1 = enable timer-driven maintenance/update runs
TRACK_LATEST=0                       # 1 = auto-update follows louislam/uptime-kuma:latest

# Extra packages to install (space-separated or array)
EXTRA_PACKAGES=(
  qemu-guest-agent
)

# Behavior
CLEANUP_ON_FAIL=1

# Derived
APP_DIR="/opt/uptime-kuma"
APP_IMAGE="${APP_IMAGE_REPO}:${APP_TAG}"

# ── Custom configs created by this script ─────────────────────────────────────
#   /opt/uptime-kuma/docker-compose.yml       (Podman compose stack)
#   /opt/uptime-kuma/.env                     (runtime configuration)
#   /opt/uptime-kuma/data/                    (Uptime Kuma persistent data — SQLite DB, uploads)
#   /usr/local/bin/uptime-kuma-maint.sh       (maintenance helper)
#   /etc/systemd/system/uptime-kuma-stack.service
#   /etc/systemd/system/uptime-kuma-update.service
#   /etc/systemd/system/uptime-kuma-update.timer
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/sysctl.d/99-hardening.conf

# ── Config validation ─────────────────────────────────────────────────────────
[[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }
[[ "$HN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || { echo "  ERROR: HN is not a valid hostname: $HN" >&2; exit 1; }
[[ "$CPU" =~ ^[0-9]+$ ]] && (( CPU >= 1 )) || { echo "  ERROR: CPU must be a positive integer." >&2; exit 1; }
[[ "$RAM" =~ ^[0-9]+$ ]] && (( RAM >= 256 )) || { echo "  ERROR: RAM must be >= 256 MB." >&2; exit 1; }
[[ "$DISK" =~ ^[0-9]+$ ]] && (( DISK >= 1 )) || { echo "  ERROR: DISK must be >= 1 GB." >&2; exit 1; }
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }
[[ "$APP_PORT" =~ ^[0-9]+$ ]] || { echo "  ERROR: APP_PORT must be numeric." >&2; exit 1; }
(( APP_PORT >= 1 && APP_PORT <= 65535 )) || { echo "  ERROR: APP_PORT must be between 1 and 65535." >&2; exit 1; }
[[ "$AUTO_UPDATE" =~ ^[01]$ ]] || { echo "  ERROR: AUTO_UPDATE must be 0 or 1." >&2; exit 1; }
[[ "$TRACK_LATEST" =~ ^[01]$ ]] || { echo "  ERROR: TRACK_LATEST must be 0 or 1." >&2; exit 1; }
[[ "$APP_TAG" == "latest" || "$APP_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: APP_TAG must look like 2.2.1 or latest." >&2
  exit 1
}
[[ -e "/usr/share/zoneinfo/${APP_TZ}" ]] || { echo "  ERROR: APP_TZ not found in /usr/share/zoneinfo: $APP_TZ" >&2; exit 1; }
if [[ -n "$APP_FQDN" ]]; then
  [[ "$APP_FQDN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]] \
    || { echo "  ERROR: APP_FQDN is not a valid hostname: $APP_FQDN" >&2; exit 1; }
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

  Uptime-Kuma-Podman LXC Creator — Configuration
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
  App port:          $APP_PORT
  Timezone:          $APP_TZ
  FQDN:              $([ -n "$APP_FQDN" ] && echo "$APP_FQDN" || echo "(local only)")
  Tags:              $TAGS
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled" || echo "disabled")
  Track latest:      $([ "$TRACK_LATEST" -eq 1 ] && echo "enabled" || echo "disabled")
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/uptime-kuma-podman.sh"
SCRIPT_LOCAL="/root/uptime-kuma-podman.sh"
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

# ── Pull image ───────────────────────────────────────────────────────────────
echo "  Pulling Uptime Kuma image ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman pull '${APP_IMAGE}'
"

# ── Prepare persistent paths ──────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  install -d -m 0755 '${APP_DIR}'
  install -d -m 0755 '${APP_DIR}/data'
"

# ── Compose file ──────────────────────────────────────────────────────────────
# Uptime Kuma is a single-container app. Only persistent state is /app/data
# (SQLite DB, uploads, custom certs). NFS is NOT supported for this path.
# Healthcheck uses curl which is present in the official louislam/uptime-kuma image.
# If using a slim/third-party image without curl, replace with:
#   test: ["CMD", "node", "/app/extra/healthcheck.js"]
pct exec "$CT_ID" -- bash -lc "cat > '${APP_DIR}/docker-compose.yml' <<'EOF2'
services:
  uptime-kuma:
    image: \${APP_IMAGE}
    container_name: uptime-kuma
    restart: unless-stopped
    ports:
      - \"\${APP_PORT}:3001\"
    environment:
      TZ: \${APP_TZ}
    volumes:
      - ${APP_DIR}/data:/app/data:Z
    healthcheck:
      test: [\"CMD\", \"curl\", \"-f\", \"http://localhost:3001\"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: \"3\"
EOF2"

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > '${APP_DIR}/.env' <<EOF2
COMPOSE_PROJECT_NAME=uptime-kuma
APP_IMAGE_REPO=${APP_IMAGE_REPO}
APP_TAG=${APP_TAG}
APP_IMAGE=${APP_IMAGE}
APP_PORT=${APP_PORT}
APP_TZ=${APP_TZ}
APP_FQDN=${APP_FQDN}
AUTO_UPDATE=${AUTO_UPDATE}
TRACK_LATEST=${TRACK_LATEST}
EOF2
  chmod 0600 '${APP_DIR}/.env' '${APP_DIR}/docker-compose.yml'
"

# ── Maintenance script ────────────────────────────────────────────────────────
# Backup and restore are handled by PBS and PVE snapshots.
# This helper covers update operations only.
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/uptime-kuma-maint.sh && chmod 0755 /usr/local/bin/uptime-kuma-maint.sh' <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR="${APP_DIR:-/opt/uptime-kuma}"
SERVICE="uptime-kuma-stack.service"
ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"

need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF2
  Uptime Kuma Maintenance
  ───────────────────────
  Usage:
    $0 update <tag|latest>
    $0 auto-update
    $0 version

  Notes:
    - update pulls the new image tag and recreates the container
    - auto-update only runs when AUTO_UPDATE=1 and TRACK_LATEST=1
    - pinned tags (TRACK_LATEST=0) are only updated manually
    - backup and restore are handled by PBS and PVE snapshots
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

app_port() {
  local port
  port="$(awk -F= '/^APP_PORT=/{print $2}' "$ENV_FILE" | tail -n1 | tr -d '[:space:]')"
  [[ "$port" =~ ^[0-9]+$ ]] && printf '%s' "$port" || printf '3001'
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

wait_for_app() {
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

update_app() {
  local new_tag="" skip_confirm=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) skip_confirm=1; shift ;;
      *) new_tag="$1"; shift ;;
    esac
  done
  local old_image new_image tmp_env old_tag repo
  [[ -n "$new_tag" ]] || die "Usage: uptime-kuma-maint.sh update <tag|latest>"
  [[ "$new_tag" == "latest" || "$new_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || die "Invalid tag: $new_tag"

  old_image="$(current_image)"
  old_tag="$(current_tag)"
  repo="$(current_repo)"
  [[ -n "$old_image" ]] || die "Could not read current APP_IMAGE from .env"
  [[ -n "$repo" ]] || die "Could not read APP_IMAGE_REPO from .env"
  new_image="${repo}:${new_tag}"
  tmp_env="$(mktemp)"

  echo "  Current tag: $old_tag"
  echo "  Target  tag: $new_tag"

  if [[ "$skip_confirm" -eq 0 ]]; then
    echo ""
    echo "  IMPORTANT: Take a PVE snapshot before proceeding with the update."
    echo "  Use: pct snapshot <CT_ID> pre-update-$(date +%Y%m%d)"
    echo ""
    read -r -p "  Continue? [y/N]: " confirm
    case "$confirm" in
      [yY][eE][sS]|[yY]) ;;
      *) echo "  Aborted."; rm -f "$tmp_env"; exit 0 ;;
    esac
  fi

  cp -a "$ENV_FILE" "$tmp_env"

  cleanup() { rm -f "$tmp_env"; }
  rollback() {
    echo "  !! Update failed — rolling back .env and container ..." >&2
    cp -a "$tmp_env" "$ENV_FILE"
    cd "$APP_DIR"
    /usr/bin/podman-compose up -d --force-recreate uptime-kuma || true
  }
  trap rollback ERR

  echo "  Pulling target image ..."
  podman pull "$new_image"

  sed -i \
    -e "s|^APP_TAG=.*|APP_TAG=$new_tag|" \
    -e "s|^APP_IMAGE=.*|APP_IMAGE=$new_image|" \
    "$ENV_FILE"

  echo "  Recreating Uptime Kuma container ..."
  cd "$APP_DIR"
  /usr/bin/podman-compose up -d --force-recreate uptime-kuma

  echo "  Waiting for UI ..."
  wait_for_app || die "Uptime Kuma did not become reachable after update."

  trap - ERR
  cleanup
  echo "  OK: Uptime Kuma updated to $new_tag"
}

auto_update_app() {
  if ! auto_update_enabled; then
    echo "  Auto-update disabled in ${ENV_FILE}; nothing to do."
    return 0
  fi

  if ! track_latest_enabled; then
    echo "  TRACK_LATEST=0 and tag is pinned; skipping scheduled recreate."
    return 0
  fi

  echo "  Auto-update policy: TRACK_LATEST=1 -> following latest"
  update_app --yes latest
}

need_root
cmd="${1:-}"
case "$cmd" in
  update) shift; update_app "$@" ;;
  auto-update) auto_update_app ;;
  version)
    echo "Configured image: $(current_image)"
    echo "AUTO_UPDATE=$(env_flag AUTO_UPDATE)"
    echo "TRACK_LATEST=$(env_flag TRACK_LATEST)"
    ;;
  ""|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
MAINT
echo "  Maintenance script deployed: /usr/local/bin/uptime-kuma-maint.sh"

# ── Systemd stack unit ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/uptime-kuma-stack.service <<EOF2
[Unit]
Description=Uptime Kuma (Podman) stack
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/uptime-kuma
ExecStart=/usr/bin/podman-compose up -d
ExecStop=/usr/bin/podman-compose down
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF2

  systemctl daemon-reload
  systemctl enable --now uptime-kuma-stack.service
'

# ── Verification ──────────────────────────────────────────────────────────────
sleep 3
if pct exec "$CT_ID" -- systemctl is-active --quiet uptime-kuma-stack.service 2>/dev/null; then
  echo "  Uptime Kuma stack service is active"
else
  echo "  WARNING: uptime-kuma-stack.service may not be active — check: pct exec $CT_ID -- journalctl -u uptime-kuma-stack --no-pager -n 50" >&2
fi

RUNNING=0
for i in $(seq 1 60); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc 'podman ps --format "{{.Names}}" 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge 1 ]] && break
  sleep 2
done
pct exec "$CT_ID" -- bash -lc 'cd /opt/uptime-kuma && podman-compose ps' || true

UK_HEALTHY=0
for i in $(seq 1 45); do
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc "curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:${APP_PORT}/ 2>/dev/null" 2>/dev/null || echo 000)"
  case "$HTTP_CODE" in
    200|301|302|401|403)
      UK_HEALTHY=1
      break
      ;;
  esac
  sleep 2
done

if [[ "$UK_HEALTHY" -eq 1 ]]; then
  echo "  Uptime Kuma health check passed (HTTP $HTTP_CODE)"
else
  echo "  WARNING: Uptime Kuma did not become reachable yet" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u uptime-kuma-stack.service --no-pager -n 80" >&2
  echo "  Check: pct exec $CT_ID -- bash -lc 'cd /opt/uptime-kuma && podman-compose logs --tail=80'" >&2
fi

# ── Auto-update timer (policy-driven) ─────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/uptime-kuma-update.service <<EOF2
[Unit]
Description=Uptime Kuma auto-update maintenance run
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/uptime-kuma-maint.sh auto-update
EOF2

  cat > /etc/systemd/system/uptime-kuma-update.timer <<EOF2
[Unit]
Description=Uptime Kuma auto-update timer

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
  pct exec "$CT_ID" -- bash -lc 'systemctl enable --now uptime-kuma-update.timer'
  echo "  Auto-update timer enabled"
else
  pct exec "$CT_ID" -- bash -lc 'systemctl disable --now uptime-kuma-update.timer >/dev/null 2>&1 || true'
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
printf '\n  Uptime Kuma (Podman)\n'
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
fqdn=\"\$(awk -F= '/^APP_FQDN=/{print \$2}' /opt/uptime-kuma/.env 2>/dev/null | tail -n1)\"
port=\"\$(awk -F= '/^APP_PORT=/{print \$2}' /opt/uptime-kuma/.env 2>/dev/null | tail -n1)\"
port=\"\${port:-3001}\"
printf '  Stack:     /opt/uptime-kuma (%s containers running)\n' \"\$running\"
printf '  Compose:   cd /opt/uptime-kuma && podman-compose [up -d|down|logs|ps]\n'
printf '  Maintain:  /usr/local/bin/uptime-kuma-maint.sh [update|auto-update|version]\n'
printf '  Updates:   systemctl status uptime-kuma-update.timer\n'
if [ -n \"\$fqdn\" ]; then
  printf '  Web UI:    https://%s\n' \"\$fqdn\"
fi
printf '  Web UI:    http://%s:%s\n' \"\${ip:-n/a}\" \"\$port\"
printf '  NPM proxy: http → %s:%s + Websockets Support on\n' \"\${ip:-n/a}\" \"\$port\"
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
UK_DESC_LINK="http://${CT_IP}:${APP_PORT}"
if [[ -n "$APP_FQDN" ]]; then
  UK_DESC_LINK="https://${APP_FQDN}"
fi
UK_DESC="<a href='${UK_DESC_LINK}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Uptime Kuma</a>
<details><summary>Details</summary>Uptime Kuma (Podman) on Debian ${DEBIAN_VERSION} LXC
Created by uptime-kuma-podman.sh</details>"
pct set "$CT_ID" --description "$UK_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "CT: $CT_ID | IP: ${CT_IP} | Web UI: http://${CT_IP}:${APP_PORT}"
if [[ -n "$APP_FQDN" ]]; then
  echo "    Public: https://${APP_FQDN}"
fi
echo "    Policy: AUTO_UPDATE=${AUTO_UPDATE} TRACK_LATEST=${TRACK_LATEST}"
echo "    pct exec $CT_ID -- /usr/local/bin/uptime-kuma-maint.sh update <tag|latest>"
echo "    pct exec $CT_ID -- /usr/local/bin/uptime-kuma-maint.sh auto-update"
echo "    pct exec $CT_ID -- /usr/local/bin/uptime-kuma-maint.sh version"
echo "    Backup/restore: use PBS or PVE snapshots"
echo ""
echo "  NPM reverse proxy:"
echo "    Scheme: http  |  Forward: ${CT_IP}  |  Port: ${APP_PORT}"
echo "    Enable 'Websockets Support' toggle (no advanced config needed)"
echo "  First visit creates the admin account."
echo ""
