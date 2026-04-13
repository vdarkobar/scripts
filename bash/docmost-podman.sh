#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID=""                             # empty = auto-assign via pvesh; set e.g. CT_ID=120 to pin
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
HN="docmost"
CPU=4
RAM=4096
DISK=16
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Docmost / Podman
APP_PORT=3000
APP_TZ="Europe/Berlin"
PUBLIC_FQDN=""                      # e.g. docmost.example.com ; blank = local IP mode
TAGS="docmost;podman;lxc"

# Images / versions
DOCMOST_TAG="0.25.2"
DOCMOST_IMAGE="docker.io/docmost/docmost:${DOCMOST_TAG}"
POSTGRES_IMAGE="docker.io/library/postgres:18"
REDIS_IMAGE="docker.io/library/redis:8"
DEBIAN_VERSION=13

# Optional features
AUTO_UPDATE=0                        # 1 = enable timer-driven maintenance/update runs
TRACK_LATEST=0                     # 1 = auto-update follows docker.io/docmost/docmost:latest
KEEP_BACKUPS=7

# Extra packages to install (space-separated or array)
EXTRA_PACKAGES=(
  qemu-guest-agent
)

# Behavior
CLEANUP_ON_FAIL=1

# Derived
APP_DIR="/opt/docmost"
BACKUP_DIR="/opt/docmost-backups"
APP_URL=""
[[ -n "$PUBLIC_FQDN" ]] && APP_URL="https://${PUBLIC_FQDN}"

# ── Custom configs created by this script ─────────────────────────────────────
#   /opt/docmost/docker-compose.yml         (Podman compose stack)
#   /opt/docmost/.env                       (runtime configuration)
#   /opt/docmost/postgresdata/              (PostgreSQL data)
#   /opt/docmost/redis/                     (Redis appendonly data)
#   /opt/docmost/storage/                   (Docmost file storage)
#   /opt/docmost-backups/                   (compressed backups)
#   /usr/local/bin/docmost-maint.sh         (maintenance helper)
#   /etc/systemd/system/docmost-stack.service
#   /etc/systemd/system/docmost-update.service
#   /etc/systemd/system/docmost-update.timer
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
[[ "$DOCMOST_TAG" == "latest" || "$DOCMOST_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: DOCMOST_TAG must look like 0.25.2 or latest." >&2
  exit 1
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

for cmd in pvesh pveam pct pvesm curl python3 ip awk sort paste; do
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

  Docmost-Podman LXC Creator — Configuration
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
  Docmost tag:       $DOCMOST_TAG
  App port:          $APP_PORT
  Public FQDN:       ${PUBLIC_FQDN:-"(not set — local IP mode)"}
  Timezone:          $APP_TZ
  Tags:              $TAGS
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled" || echo "disabled")
  Track latest:      $([ "$TRACK_LATEST" -eq 1 ] && echo "enabled" || echo "disabled")
  Keep backups:      $KEEP_BACKUPS
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/docmost-podman.sh"
SCRIPT_LOCAL="/root/docmost-podman.sh"
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

if [[ -z "$APP_URL" ]]; then
  APP_URL="http://${CT_IP}:${APP_PORT}"
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
  apt-get install -y locales curl ca-certificates iproute2 jq podman podman-compose fuse-overlayfs rsync tar gzip
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

# ── Secrets ───────────────────────────────────────────────────────────────────
DB_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40 || true)"
APP_SECRET="$(tr -dc 'a-f0-9' </dev/urandom | head -c 64 || true)"
[[ ${#DB_PASSWORD} -eq 40 && ${#APP_SECRET} -eq 64 ]] || { echo "  ERROR: Failed to generate secrets." >&2; exit 1; }

# ── Pull images ───────────────────────────────────────────────────────────────
echo "  Pulling Docmost images ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman pull '${DOCMOST_IMAGE}'
  podman pull '${POSTGRES_IMAGE}'
  podman pull '${REDIS_IMAGE}'
"

# ── Detect container UIDs/GIDs for bind mounts ────────────────────────────────
POSTGRES_UID="$(pct exec "$CT_ID" -- bash -lc "podman run --rm --entrypoint sh '${POSTGRES_IMAGE}' -lc 'id -u postgres 2>/dev/null || id -u'" 2>/dev/null | tr -d '\r')"
POSTGRES_GID="$(pct exec "$CT_ID" -- bash -lc "podman run --rm --entrypoint sh '${POSTGRES_IMAGE}' -lc 'id -g postgres 2>/dev/null || id -g'" 2>/dev/null | tr -d '\r')"
REDIS_UID="$(pct exec "$CT_ID" -- bash -lc "podman run --rm --entrypoint sh '${REDIS_IMAGE}' -lc 'id -u redis 2>/dev/null || id -u'" 2>/dev/null | tr -d '\r')"
REDIS_GID="$(pct exec "$CT_ID" -- bash -lc "podman run --rm --entrypoint sh '${REDIS_IMAGE}' -lc 'id -g redis 2>/dev/null || id -g'" 2>/dev/null | tr -d '\r')"
DOCMOST_UID="$(pct exec "$CT_ID" -- bash -lc "podman run --rm --entrypoint sh '${DOCMOST_IMAGE}' -lc 'id -u node 2>/dev/null || id -u'" 2>/dev/null | tr -d '\r')"
DOCMOST_GID="$(pct exec "$CT_ID" -- bash -lc "podman run --rm --entrypoint sh '${DOCMOST_IMAGE}' -lc 'id -g node 2>/dev/null || id -g'" 2>/dev/null | tr -d '\r')"

for v in POSTGRES_UID POSTGRES_GID REDIS_UID REDIS_GID DOCMOST_UID DOCMOST_GID; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "  ERROR: Failed to detect numeric $v from container images." >&2; exit 1; }
done

echo "  Detected bind-mount ownership: postgres=${POSTGRES_UID}:${POSTGRES_GID} redis=${REDIS_UID}:${REDIS_GID} docmost=${DOCMOST_UID}:${DOCMOST_GID}"

# ── Prepare persistent paths ──────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  install -d -m 0755 '${APP_DIR}' '${BACKUP_DIR}'
  install -d -m 0750 '${APP_DIR}/postgresdata' '${APP_DIR}/redis' '${APP_DIR}/storage'
  chown -R ${POSTGRES_UID}:${POSTGRES_GID} '${APP_DIR}/postgresdata'
  chown -R ${REDIS_UID}:${REDIS_GID} '${APP_DIR}/redis'
  chown -R ${DOCMOST_UID}:${DOCMOST_GID} '${APP_DIR}/storage'
"

# ── Compose file ──────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "cat > /opt/docmost/docker-compose.yml <<'EOF2'
services:
  docmost:
    image: \${DOCMOST_IMAGE}
    container_name: docmost
    depends_on:
      - db
      - redis
    environment:
      APP_URL: \${APP_URL}
      APP_SECRET: \${APP_SECRET}
      DATABASE_URL: \${DATABASE_URL}
      REDIS_URL: \${REDIS_URL}
      STORAGE_DRIVER: local
      TZ: \${APP_TZ}
    ports:
      - \"\${APP_PORT}:3000\"
    restart: unless-stopped
    volumes:
      - /opt/docmost/storage:/app/data/storage:Z

  db:
    image: \${POSTGRES_IMAGE}
    container_name: docmost_db
    environment:
      POSTGRES_DB: docmost
      POSTGRES_USER: docmost
      POSTGRES_PASSWORD: \${DB_PASSWORD}
      TZ: \${APP_TZ}
    restart: unless-stopped
    volumes:
      - /opt/docmost/postgresdata:/var/lib/postgresql:Z
    healthcheck:
      test: [\"CMD-SHELL\", \"pg_isready -U docmost -d docmost\"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

  redis:
    image: \${REDIS_IMAGE}
    container_name: docmost_redis
    command: [\"redis-server\", \"--appendonly\", \"yes\", \"--maxmemory-policy\", \"noeviction\"]
    restart: unless-stopped
    volumes:
      - /opt/docmost/redis:/data:Z
    healthcheck:
      test: [\"CMD\", \"redis-cli\", \"ping\"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
EOF2" 

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > '${APP_DIR}/.env' <<EOF2
COMPOSE_PROJECT_NAME=docmost
DOCMOST_TAG=${DOCMOST_TAG}
DOCMOST_IMAGE=${DOCMOST_IMAGE}
POSTGRES_IMAGE=${POSTGRES_IMAGE}
REDIS_IMAGE=${REDIS_IMAGE}
APP_PORT=${APP_PORT}
APP_TZ=${APP_TZ}
PUBLIC_FQDN=${PUBLIC_FQDN}
APP_URL=${APP_URL}
APP_SECRET=${APP_SECRET}
DB_PASSWORD=${DB_PASSWORD}
DATABASE_URL=postgresql://docmost:${DB_PASSWORD}@db:5432/docmost
REDIS_URL=redis://redis:6379
KEEP_BACKUPS=${KEEP_BACKUPS}
AUTO_UPDATE=${AUTO_UPDATE}
TRACK_LATEST=${TRACK_LATEST}
EOF2
  chmod 0600 '${APP_DIR}/.env' '${APP_DIR}/docker-compose.yml'
"

# ── Maintenance script ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/docmost-maint.sh && chmod 0755 /usr/local/bin/docmost-maint.sh' <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR="${APP_DIR:-/opt/docmost}"
BACKUP_DIR="${BACKUP_DIR:-/opt/docmost-backups}"
SERVICE="docmost-stack.service"
ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
KEEP_BACKUPS="${KEEP_BACKUPS:-7}"

need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF2
  Docmost Maintenance
  ───────────────────
  Usage:
    $0 backup
    $0 list
    $0 restore <backup.tar.gz>
    $0 update <docmost-tag|latest>
    $0 auto-update
    $0 version

  Notes:
    - backup stops the stack for a consistent snapshot, then starts it again
    - update backs up first, then changes only the Docmost image tag
    - auto-update obeys AUTO_UPDATE and TRACK_LATEST from ${ENV_FILE}
    - PostgreSQL and Redis image changes are intentionally manual
EOF2
}

[[ -d "$APP_DIR" ]] || die "APP_DIR not found: $APP_DIR"
[[ -f "$ENV_FILE" ]] || die "Missing env file: $ENV_FILE"
[[ -f "$COMPOSE_FILE" ]] || die "Missing compose file: $COMPOSE_FILE"

env_keep_backups="$(awk -F= '/^KEEP_BACKUPS=/{print $2}' "$ENV_FILE" | tail -n1)"
if [[ "$env_keep_backups" =~ ^[0-9]+$ ]]; then
  KEEP_BACKUPS="$env_keep_backups"
fi

current_image() {
  awk -F= '/^DOCMOST_IMAGE=/{print $2}' "$ENV_FILE" | tail -n1
}

current_tag() {
  local img
  img="$(current_image)"
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

backup_stack() {
  local ts out started=0
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$BACKUP_DIR/docmost-backup-$ts.tar.gz"

  mkdir -p "$BACKUP_DIR"

  if systemctl is-active --quiet "$SERVICE"; then
    started=1
    echo "  Stopping Docmost stack for consistent backup ..."
    systemctl stop "$SERVICE"
  fi

  trap 'if [[ $started -eq 1 ]]; then systemctl start "$SERVICE" || true; fi' RETURN

  echo "  Creating backup: $out"
  tar -C / -czf "$out" \
    opt/docmost/.env \
    opt/docmost/docker-compose.yml \
    opt/docmost/postgresdata \
    opt/docmost/redis \
    opt/docmost/storage

  if [[ "$KEEP_BACKUPS" =~ ^[0-9]+$ ]] && (( KEEP_BACKUPS > 0 )); then
    ls -1t "$BACKUP_DIR"/docmost-backup-*.tar.gz 2>/dev/null | awk -v keep="$KEEP_BACKUPS" 'NR>keep' | xargs -r rm -f --
  fi

  echo "  OK: $out"
}

restore_stack() {
  local backup="$1"
  [[ -n "$backup" ]] || die "Usage: docmost-maint.sh restore <backup.tar.gz>"
  [[ -f "$backup" ]] || die "Backup not found: $backup"

  echo "  Stopping Docmost stack ..."
  systemctl stop "$SERVICE" 2>/dev/null || true

  echo "  Removing current persistent state ..."
  rm -rf \
    "$APP_DIR/postgresdata" \
    "$APP_DIR/redis" \
    "$APP_DIR/storage"

  echo "  Restoring backup ..."
  tar -C / -xzf "$backup"

  echo "  Starting Docmost stack ..."
  systemctl start "$SERVICE"
  echo "  OK: restore completed."
}

update_docmost() {
  local new_tag="$1"
  local old_image new_image tmp_env health old_tag
  [[ -n "$new_tag" ]] || die "Usage: docmost-maint.sh update <docmost-tag|latest>"
  [[ "$new_tag" == "latest" || "$new_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || die "Invalid Docmost tag: $new_tag"

  old_image="$(current_image)"
  old_tag="$(current_tag)"
  [[ -n "$old_image" ]] || die "Could not read current DOCMOST_IMAGE from .env"
  new_image="docker.io/docmost/docmost:$new_tag"
  tmp_env="$(mktemp)"

  echo "  Current Docmost tag: $old_tag"
  echo "  Target  Docmost tag: $new_tag"

  backup_stack
  cp -a "$ENV_FILE" "$tmp_env"

  cleanup() { rm -f "$tmp_env"; }
  rollback() {
    echo "  !! Update failed — rolling back .env and container ..." >&2
    cp -a "$tmp_env" "$ENV_FILE"
    cd "$APP_DIR"
    /usr/bin/podman-compose up -d --force-recreate docmost || true
  }
  trap rollback ERR

  echo "  Pulling target image ..."
  podman pull "$new_image"

  sed -i \
    -e "s|^DOCMOST_TAG=.*|DOCMOST_TAG=$new_tag|" \
    -e "s|^DOCMOST_IMAGE=.*|DOCMOST_IMAGE=$new_image|" \
    "$ENV_FILE"

  echo "  Recreating Docmost container ..."
  cd "$APP_DIR"
  /usr/bin/podman-compose up -d --force-recreate docmost

  echo "  Waiting for health endpoint ..."
  health=0
  for i in $(seq 1 45); do
    if curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:3000/api/health; then
      health=1
      break
    fi
    sleep 2
  done
  [[ "$health" -eq 1 ]] || die "Docmost health endpoint did not return 200 after update."

  trap - ERR
  cleanup
  echo "  OK: Docmost updated to $new_tag"
}

auto_update_docmost() {
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

  update_docmost "$target_tag"
}

need_root
cmd="${1:-}"
case "$cmd" in
  backup) backup_stack ;;
  list) ls -1t "$BACKUP_DIR"/docmost-backup-*.tar.gz 2>/dev/null || true ;;
  restore) shift; restore_stack "${1:-}" ;;
  update) shift; update_docmost "${1:-}" ;;
  auto-update) auto_update_docmost ;;
  version)
    echo "Configured Docmost image: $(current_image)"
    echo "AUTO_UPDATE=$(env_flag AUTO_UPDATE)"
    echo "TRACK_LATEST=$(env_flag TRACK_LATEST)"
    ;;
  ""|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
MAINT
echo "  Maintenance script deployed: /usr/local/bin/docmost-maint.sh"

# ── Systemd stack unit ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/docmost-stack.service <<EOF2
[Unit]
Description=Docmost (Podman) stack
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/docmost
ExecStart=/usr/bin/podman-compose up -d
ExecStop=/usr/bin/podman-compose down
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF2

  systemctl daemon-reload
  systemctl enable --now docmost-stack.service
'

# ── Verification ──────────────────────────────────────────────────────────────
sleep 3
if pct exec "$CT_ID" -- systemctl is-active --quiet docmost-stack.service 2>/dev/null; then
  echo "  Docmost stack service is active"
else
  echo "  WARNING: docmost-stack.service may not be active — check: pct exec $CT_ID -- journalctl -u docmost-stack --no-pager -n 50" >&2
fi

RUNNING=0
for i in $(seq 1 90); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc 'podman ps --format "{{.Names}}" 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge 3 ]] && break
  sleep 2
done
pct exec "$CT_ID" -- bash -lc 'cd /opt/docmost && podman-compose ps' || true

DOCMOST_HEALTHY=0
for i in $(seq 1 45); do
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${APP_PORT}/api/health 2>/dev/null" 2>/dev/null || echo 000)"
  if [[ "$HTTP_CODE" == "200" ]]; then
    DOCMOST_HEALTHY=1
    break
  fi
  sleep 2
done

if [[ "$DOCMOST_HEALTHY" -eq 1 ]]; then
  echo "  Docmost health check passed (HTTP 200)"
else
  echo "  WARNING: Docmost health endpoint did not return 200 yet" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u docmost-stack.service --no-pager -n 80" >&2
  echo "  Check: pct exec $CT_ID -- bash -lc 'cd /opt/docmost && podman-compose logs --tail=80'" >&2
fi

# ── Auto-update timer (policy-driven) ──────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/docmost-update.service <<EOF2
[Unit]
Description=Docmost auto-update maintenance run
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/docmost-maint.sh auto-update
EOF2

  cat > /etc/systemd/system/docmost-update.timer <<EOF2
[Unit]
Description=Docmost auto-update timer

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
  pct exec "$CT_ID" -- bash -lc 'systemctl enable --now docmost-update.timer'
  echo "  Auto-update timer enabled"
else
  pct exec "$CT_ID" -- bash -lc 'systemctl disable --now docmost-update.timer >/dev/null 2>&1 || true'
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
  apt-get clean
'

# ── MOTD (dynamic drop-ins) ───────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  > /etc/motd
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
  rm -f /etc/update-motd.d/*

  cat > /etc/update-motd.d/00-header <<'EOF2'
#!/bin/sh
printf '\n  Docmost (Podman)\n'
printf '  ────────────────────────────────────\n'
EOF2

  cat > /etc/update-motd.d/10-sysinfo <<'EOF2'
#!/bin/sh
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '  Hostname:  %s\n' \"\$(hostname)\"
printf '  IP:        %s\n' \"\${ip:-n/a}\"
printf '  Uptime:    %s\n' \"\$(uptime -p 2>/dev/null || uptime)\"
printf '  Disk:      %s\n' \"\$(df -h / | awk 'NR==2{printf \"%s/%s (%s used)\", \$3, \$2, \$5}')\"
EOF2

  cat > /etc/update-motd.d/30-app <<'EOF2'
#!/bin/sh
running=\$(podman ps --format '{{.Names}}' 2>/dev/null | wc -l)
service_active=\$(systemctl is-active docmost-stack.service 2>/dev/null || echo 'unknown')
configured_image=\$(awk -F= '/^DOCMOST_IMAGE=/{print \$2}' /opt/docmost/.env 2>/dev/null | tail -n1)
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '  Stack:     /opt/docmost (%s containers running)\n' \"\$running\"
printf '  Service:   %s\n' \"\$service_active\"
printf '  Image:     %s\n' \"\${configured_image:-n/a}\"
printf '  Backup:    /opt/docmost-backups\n'
printf '  Compose:   cd /opt/docmost && podman-compose [up -d|down|logs|ps]\n'
printf '  Maintain:  docmost-maint.sh [backup|list|restore|update|auto-update|version]\n'
printf '  Web UI:    http://%s:${APP_PORT}\n' \"\${ip:-n/a}\"
printf '  Health:    http://%s:${APP_PORT}/api/health\n' \"\${ip:-n/a}\"
[ -n '${PUBLIC_FQDN}' ] && printf '  Public:    https://${PUBLIC_FQDN}\n' || true
EOF2

  cat > /etc/update-motd.d/99-footer <<'EOF2'
#!/bin/sh
printf '  ────────────────────────────────────\n\n'
EOF2

  chmod +x /etc/update-motd.d/*
"

# Set TERM for console
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Proxmox UI description ────────────────────────────────────────────────────
if [[ -n "$PUBLIC_FQDN" ]]; then
  DOCMOST_LINK="https://${PUBLIC_FQDN}/"
else
  DOCMOST_LINK="http://${CT_IP}:${APP_PORT}/"
fi
DOCMOST_DESC="<a href='${DOCMOST_LINK}' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Docmost Web UI</a>
<details><summary>Details</summary>Docmost ${DOCMOST_TAG} on Debian ${DEBIAN_VERSION} LXC
Podman stack with PostgreSQL + Redis
Created by docmost-podman.sh</details>"
pct set "$CT_ID" --description "$DOCMOST_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  CT: $CT_ID | IP: ${CT_IP} | Login: password set"
echo ""
echo "  Access (local):"
echo "    Main: http://${CT_IP}:${APP_PORT}/"
echo "    Health: http://${CT_IP}:${APP_PORT}/api/health"
if [[ -n "$PUBLIC_FQDN" ]]; then
  echo ""
  echo "  Access (public):"
  echo "    Main: https://${PUBLIC_FQDN}/"
fi
echo ""
echo "  Config files:"
echo "    ${APP_DIR}/docker-compose.yml"
echo "    ${APP_DIR}/.env"
echo ""
echo "  Persistent paths:"
echo "    ${APP_DIR}/postgresdata"
echo "    ${APP_DIR}/redis"
echo "    ${APP_DIR}/storage"
echo ""
echo "  Maintenance:"
echo "    Policy: AUTO_UPDATE=${AUTO_UPDATE} TRACK_LATEST=${TRACK_LATEST}"
echo "    pct exec $CT_ID -- docmost-maint.sh backup"
echo "    pct exec $CT_ID -- docmost-maint.sh list"
echo "    pct exec $CT_ID -- docmost-maint.sh update <docmost-tag|latest>"
echo "    pct exec $CT_ID -- docmost-maint.sh restore /opt/docmost-backups/<backup.tar.gz>"
echo "    pct exec $CT_ID -- docmost-maint.sh auto-update"
echo ""
if [[ -n "$PUBLIC_FQDN" ]]; then
  echo "  Reverse proxy (NPM):"
  echo "    ${PUBLIC_FQDN} -> http://${CT_IP}:${APP_PORT}"
  echo "    Enable SSL and WebSockets in NPM."
  echo ""
fi
echo "  Done."
