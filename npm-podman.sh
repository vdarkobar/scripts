#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID="$(pvesh get /cluster/nextid)"
HN="npm"
CPU=4
RAM=4096
DISK=8
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Nginx Proxy Manager / Podman
NPM_ADMIN_PORT=49152
APP_TZ="Europe/Berlin"
TAGS="npm;podman;lxc"

# Images / versions
NPM_TAG="2.14.0"
NPM_IMAGE="docker.io/jc21/nginx-proxy-manager:${NPM_TAG}"
DB_TAG="10.11.5"
DB_IMAGE="docker.io/jc21/mariadb-aria:${DB_TAG}"
DEBIAN_VERSION=13

# Optional features / policy
INSTALL_CLOUDFLARED=0                # 1 = install cloudflared inside CT
NPM_DISABLE_IPV6=0                   # 1 = set DISABLE_IPV6=true for NPM app container
AUTO_UPDATE=0                        # 1 = enable timer-driven maintenance/update runs
TRACK_LATEST=0                       # 1 = auto-update follows docker.io/jc21/nginx-proxy-manager:latest
ALLOW_CONSOLE_AUTOLOGIN_IF_BLANK=0   # 1 = enable root console autologin when password blank
KEEP_BACKUPS=7

# Behavior
CLEANUP_ON_FAIL=1

# Derived
APP_DIR="/opt/npm"
BACKUP_DIR="/opt/npm-backups"

# ── Custom configs created by this script ─────────────────────────────────────
#   /opt/npm/docker-compose.yml              (Podman compose stack)
#   /opt/npm/.env                            (runtime configuration)
#   /opt/npm/.secrets/                       (small secret files)
#   /opt/npm/data/                           (NPM application data)
#   /opt/npm/letsencrypt/                    (certificates)
#   /opt/npm/mysql/                          (MariaDB data)
#   /opt/npm-backups/                        (compressed operational backups)
#   /usr/local/bin/npm-maint.sh              (maintenance helper)
#   /etc/systemd/system/npm-stack.service
#   /etc/systemd/system/npm-update.service
#   /etc/systemd/system/npm-update.timer
#   /etc/systemd/system/container-getty@1.service.d/override.conf   (optional)
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/35-cloudflared        (if INSTALL_CLOUDFLARED=1)
#   /etc/update-motd.d/99-footer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/sysctl.d/99-hardening.conf

# ── Config validation ─────────────────────────────────────────────────────────
[[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }
[[ "$NPM_ADMIN_PORT" =~ ^[0-9]+$ ]] || { echo "  ERROR: NPM_ADMIN_PORT must be numeric." >&2; exit 1; }
(( NPM_ADMIN_PORT >= 1 && NPM_ADMIN_PORT <= 65535 )) || { echo "  ERROR: NPM_ADMIN_PORT must be between 1 and 65535." >&2; exit 1; }
[[ "$KEEP_BACKUPS" =~ ^[0-9]+$ ]] || { echo "  ERROR: KEEP_BACKUPS must be numeric." >&2; exit 1; }
[[ "$AUTO_UPDATE" =~ ^[01]$ ]] || { echo "  ERROR: AUTO_UPDATE must be 0 or 1." >&2; exit 1; }
[[ "$TRACK_LATEST" =~ ^[01]$ ]] || { echo "  ERROR: TRACK_LATEST must be 0 or 1." >&2; exit 1; }
[[ "$ALLOW_CONSOLE_AUTOLOGIN_IF_BLANK" =~ ^[01]$ ]] || { echo "  ERROR: ALLOW_CONSOLE_AUTOLOGIN_IF_BLANK must be 0 or 1." >&2; exit 1; }
[[ "$INSTALL_CLOUDFLARED" =~ ^[01]$ ]] || { echo "  ERROR: INSTALL_CLOUDFLARED must be 0 or 1." >&2; exit 1; }
[[ "$NPM_DISABLE_IPV6" =~ ^[01]$ ]] || { echo "  ERROR: NPM_DISABLE_IPV6 must be 0 or 1." >&2; exit 1; }
[[ "$NPM_TAG" == "latest" || "$NPM_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: NPM_TAG must look like 2.14.0 or latest." >&2
  exit 1
}
[[ "$DB_TAG" == "latest" || "$DB_TAG" == "latest-innodb" || "$DB_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: DB_TAG must look like 10.11.5, 10.11.5-innodb, latest, or latest-innodb." >&2
  exit 1
}
[[ -e "/usr/share/zoneinfo/${APP_TZ}" ]] || { echo "  ERROR: APP_TZ not found in /usr/share/zoneinfo: $APP_TZ" >&2; exit 1; }

# ── Trap cleanup ──────────────────────────────────────────────────────────────
trap 'trap - ERR; rc=$?;
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
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content','') or 'images' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^vmbr' | sort -u | paste -sd', ' - || echo "n/a")"

# ── Show defaults & confirm ───────────────────────────────────────────────────
cat <<EOF2

  NPM-Podman LXC Creator — Configuration
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
  NPM tag:           $NPM_TAG
  DB tag:            $DB_TAG
  NPM admin port:    $NPM_ADMIN_PORT
  Timezone:          $APP_TZ
  Tags:              $TAGS
  Disable IPv6 app:  $([ "$NPM_DISABLE_IPV6" -eq 1 ] && echo "yes" || echo "no")
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled" || echo "disabled")
  Track latest:      $([ "$TRACK_LATEST" -eq 1 ] && echo "enabled" || echo "disabled")
  Console autologin: $([ "$ALLOW_CONSOLE_AUTOLOGIN_IF_BLANK" -eq 1 ] && echo "allowed if password blank" || echo "disabled")
  Keep backups:      $KEEP_BACKUPS
  Cloudflare Tunnel: $([ "$INSTALL_CLOUDFLARED" -eq 1 ] && echo "yes" || echo "no")
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/npm-podman.sh"
SCRIPT_LOCAL="/root/npm-podman.sh"
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
  read -r -s -p "  Set root password (blank allowed): " PW1; echo
  [[ -z "$PW1" ]] && break
  if [[ "$PW1" == *" "* ]]; then echo "  Password cannot contain spaces."; continue; fi
  if [[ ${#PW1} -lt 8 ]]; then echo "  Password must be at least 8 characters."; continue; fi
  read -r -s -p "  Verify root password: " PW2; echo
  if [[ "$PW1" == "$PW2" ]]; then PASSWORD="$PW1"; break; fi
  echo "  Passwords do not match. Try again."
done

echo ""
if [[ -z "$PASSWORD" ]]; then
  echo "  WARNING: No root password was set."
  if [[ "$ALLOW_CONSOLE_AUTOLOGIN_IF_BLANK" -eq 1 ]]; then
    echo "  WARNING: Console auto-login is enabled by configuration."
  fi
  echo ""
fi

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
)
[[ -n "$PASSWORD" ]] && PCT_OPTIONS+=(-password "$PASSWORD")

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

# ── Auto-login (optional, blank password only) ────────────────────────────────
if [[ -z "$PASSWORD" && "$ALLOW_CONSOLE_AUTOLOGIN_IF_BLANK" -eq 1 ]]; then
  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    mkdir -p /etc/systemd/system/container-getty@1.service.d
    cat > /etc/systemd/system/container-getty@1.service.d/override.conf <<EOF2
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 \$TERM
EOF2
    systemctl daemon-reload
    systemctl restart container-getty@1.service
  '
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

# ── Pull images ───────────────────────────────────────────────────────────────
echo "  Pulling NPM images ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman pull '${NPM_IMAGE}'
  podman pull '${DB_IMAGE}'
"

# ── Detect container UIDs/GIDs for bind mounts ────────────────────────────────
DB_UID="$(pct exec "$CT_ID" -- bash -lc "podman run --rm --entrypoint sh '${DB_IMAGE}' -lc 'id -u mysql 2>/dev/null || id -u mariadb 2>/dev/null || id -u'" 2>/dev/null | tr -d '\r')"
DB_GID="$(pct exec "$CT_ID" -- bash -lc "podman run --rm --entrypoint sh '${DB_IMAGE}' -lc 'id -g mysql 2>/dev/null || id -g mariadb 2>/dev/null || id -g'" 2>/dev/null | tr -d '\r')"
for v in DB_UID DB_GID; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "  ERROR: Failed to detect numeric $v from DB image." >&2; exit 1; }
done
echo "  Detected DB bind-mount ownership: ${DB_UID}:${DB_GID}"

# ── Secrets ───────────────────────────────────────────────────────────────────
set +o pipefail
DB_ROOT_PWD="$(head -c 4096 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 35)"
MYSQL_PWD="$(head -c 4096 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 35)"
set -o pipefail
[[ ${#DB_ROOT_PWD} -eq 35 && ${#MYSQL_PWD} -eq 35 ]] || { echo "  ERROR: Failed to generate secrets." >&2; exit 1; }

# ── Prepare persistent paths ──────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  umask 077
  install -d -m 0755 '${APP_DIR}' '${BACKUP_DIR}'
  install -d -m 0700 '${APP_DIR}/.secrets' '${APP_DIR}/letsencrypt'
  install -d -m 0755 '${APP_DIR}/data' '${APP_DIR}/mysql'
  chown -R ${DB_UID}:${DB_GID} '${APP_DIR}/mysql'
  printf '%s' '${DB_ROOT_PWD}' > '${APP_DIR}/.secrets/db_root_pwd.secret'
  printf '%s' '${MYSQL_PWD}' > '${APP_DIR}/.secrets/mysql_pwd.secret'
  chmod 0600 '${APP_DIR}/.secrets/'*.secret
"

# ── Compose file ──────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "cat > '${APP_DIR}/docker-compose.yml' <<'EOF2'
services:
  app:
    image: \${NPM_IMAGE}
    container_name: npm_app
    restart: unless-stopped
    ports:
      - \"80:80\"
      - \"443:443\"
      - \"\${NPM_ADMIN_PORT}:81\"
    environment:
      TZ: \${APP_TZ}
      DB_MYSQL_HOST: db
      DB_MYSQL_PORT: 3306
      DB_MYSQL_USER: npm_user
      DB_MYSQL_PASSWORD__FILE: /run/secrets/mysql_pwd
      DB_MYSQL_NAME: npm_db
      DISABLE_IPV6: \${DISABLE_IPV6_ENV}
    volumes:
      - /opt/npm/data:/data:Z
      - /opt/npm/letsencrypt:/etc/letsencrypt:Z
      - /opt/npm/.secrets/mysql_pwd.secret:/run/secrets/mysql_pwd:ro,Z
    depends_on:
      db:
        condition: service_healthy

  db:
    image: \${DB_IMAGE}
    container_name: npm_db
    restart: unless-stopped
    environment:
      TZ: \${APP_TZ}
      MYSQL_ROOT_PASSWORD__FILE: /run/secrets/db_root_pwd
      MYSQL_DATABASE: npm_db
      MYSQL_USER: npm_user
      MYSQL_PASSWORD__FILE: /run/secrets/mysql_pwd
      MARIADB_AUTO_UPGRADE: '1'
    healthcheck:
      test: [\"CMD-SHELL\", \"mariadb-admin ping -h localhost --silent || mysqladmin ping -h localhost --silent\"]
      interval: 15s
      timeout: 5s
      retries: 15
      start_period: 40s
    volumes:
      - /opt/npm/mysql:/var/lib/mysql:Z
      - /opt/npm/.secrets/db_root_pwd.secret:/run/secrets/db_root_pwd:ro,Z
      - /opt/npm/.secrets/mysql_pwd.secret:/run/secrets/mysql_pwd:ro,Z
EOF2"

DISABLE_IPV6_ENV=""
[[ "$NPM_DISABLE_IPV6" -eq 1 ]] && DISABLE_IPV6_ENV="true"

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > '${APP_DIR}/.env' <<EOF2
COMPOSE_PROJECT_NAME=npm
NPM_TAG=${NPM_TAG}
NPM_IMAGE=${NPM_IMAGE}
DB_TAG=${DB_TAG}
DB_IMAGE=${DB_IMAGE}
NPM_ADMIN_PORT=${NPM_ADMIN_PORT}
APP_TZ=${APP_TZ}
DISABLE_IPV6_ENV=${DISABLE_IPV6_ENV}
KEEP_BACKUPS=${KEEP_BACKUPS}
AUTO_UPDATE=${AUTO_UPDATE}
TRACK_LATEST=${TRACK_LATEST}
EOF2
  chmod 0600 '${APP_DIR}/.env' '${APP_DIR}/docker-compose.yml'
"

# ── Maintenance script ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/npm-maint.sh && chmod 0755 /usr/local/bin/npm-maint.sh' <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR="${APP_DIR:-/opt/npm}"
BACKUP_DIR="${BACKUP_DIR:-/opt/npm-backups}"
SERVICE="npm-stack.service"
ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
KEEP_BACKUPS="${KEEP_BACKUPS:-7}"

need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF2
  NPM Maintenance
  ───────────────
  Usage:
    $0 backup
    $0 list
    $0 restore <backup.tar.gz>
    $0 rollback <backup.tar.gz>    # alias for restore
    $0 update <npm-tag|latest>
    $0 auto-update
    $0 version

  Notes:
    - backup stops the stack for a consistent operational app-state backup, then starts it again
    - update backs up first, then changes only the NPM app image tag
    - auto-update obeys AUTO_UPDATE and TRACK_LATEST from ${ENV_FILE}
    - DB image changes are intentionally manual
    - this helper is not a replacement for PBS / full CT backups
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
  awk -F= '/^NPM_IMAGE=/{print $2}' "$ENV_FILE" | tail -n1
}

current_tag() {
  local img
  img="$(current_image)"
  echo "${img##*:}"
}

admin_port() {
  local port
  port="$(awk -F= '/^NPM_ADMIN_PORT=/{print $2}' "$ENV_FILE" | tail -n1 | tr -d '[:space:]')"
  [[ "$port" =~ ^[0-9]+$ ]] && printf '%s' "$port" || printf '81'
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

wait_for_admin() {
  local port code
  port="$(admin_port)"
  for i in $(seq 1 45); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${port}/" 2>/dev/null || echo 000)"
    case "$code" in
      200|301|302|401|403) return 0 ;;
    esac
    sleep 2
  done
  return 1
}

backup_stack() {
  local ts out started=0
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$BACKUP_DIR/npm-backup-$ts.tar.gz"

  mkdir -p "$BACKUP_DIR"

  if systemctl is-active --quiet "$SERVICE"; then
    started=1
    echo "  Stopping NPM stack for consistent backup ..."
    systemctl stop "$SERVICE"
  fi

  trap 'if [[ $started -eq 1 ]]; then systemctl start "$SERVICE" || true; fi' RETURN

  echo "  Creating backup: $out"
  tar -C / -czf "$out" \
    opt/npm/.env \
    opt/npm/docker-compose.yml \
    opt/npm/.secrets \
    opt/npm/data \
    opt/npm/letsencrypt \
    opt/npm/mysql

  if [[ "$KEEP_BACKUPS" =~ ^[0-9]+$ ]] && (( KEEP_BACKUPS > 0 )); then
    ls -1t "$BACKUP_DIR"/npm-backup-*.tar.gz 2>/dev/null | awk -v keep="$KEEP_BACKUPS" 'NR>keep' | xargs -r rm -f --
  fi

  echo "  OK: $out"
}

restore_stack() {
  local backup="$1"
  [[ -n "$backup" ]] || die "Usage: npm-maint.sh restore <backup.tar.gz>"
  [[ -f "$backup" ]] || die "Backup not found: $backup"

  echo "  Stopping NPM stack ..."
  systemctl stop "$SERVICE" 2>/dev/null || true

  echo "  Removing current app state ..."
  rm -rf \
    "$APP_DIR/.secrets" \
    "$APP_DIR/data" \
    "$APP_DIR/letsencrypt" \
    "$APP_DIR/mysql" \
    "$APP_DIR/.env" \
    "$APP_DIR/docker-compose.yml"

  echo "  Restoring backup ..."
  tar -C / -xzf "$backup"

  echo "  Starting NPM stack ..."
  systemctl start "$SERVICE"

  if wait_for_admin; then
    echo "  OK: restore completed."
  else
    die "Restore completed, but NPM admin did not become reachable."
  fi
}

update_npm() {
  local new_tag="$1"
  local old_image new_image tmp_env old_tag
  [[ -n "$new_tag" ]] || die "Usage: npm-maint.sh update <npm-tag|latest>"
  [[ "$new_tag" == "latest" || "$new_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || die "Invalid NPM tag: $new_tag"

  old_image="$(current_image)"
  old_tag="$(current_tag)"
  [[ -n "$old_image" ]] || die "Could not read current NPM_IMAGE from .env"
  new_image="docker.io/jc21/nginx-proxy-manager:$new_tag"
  tmp_env="$(mktemp)"

  echo "  Current NPM tag: $old_tag"
  echo "  Target  NPM tag: $new_tag"

  backup_stack
  cp -a "$ENV_FILE" "$tmp_env"

  cleanup() { rm -f "$tmp_env"; }
  rollback() {
    echo "  !! Update failed — rolling back .env and app container ..." >&2
    cp -a "$tmp_env" "$ENV_FILE"
    cd "$APP_DIR"
    /usr/bin/podman-compose up -d --force-recreate app || true
  }
  trap rollback ERR

  echo "  Pulling target image ..."
  podman pull "$new_image"

  sed -i \
    -e "s|^NPM_TAG=.*|NPM_TAG=$new_tag|" \
    -e "s|^NPM_IMAGE=.*|NPM_IMAGE=$new_image|" \
    "$ENV_FILE"

  echo "  Recreating NPM app container ..."
  cd "$APP_DIR"
  /usr/bin/podman-compose up -d --force-recreate app

  echo "  Waiting for admin UI ..."
  wait_for_admin || die "NPM admin UI did not become reachable after update."

  trap - ERR
  cleanup
  echo "  OK: NPM updated to $new_tag"
}

auto_update_npm() {
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

  update_npm "$target_tag"
}

need_root
cmd="${1:-}"
case "$cmd" in
  backup) backup_stack ;;
  list) ls -1t "$BACKUP_DIR"/npm-backup-*.tar.gz 2>/dev/null || true ;;
  restore) shift; restore_stack "${1:-}" ;;
  rollback) shift; restore_stack "${1:-}" ;;
  update) shift; update_npm "${1:-}" ;;
  auto-update) auto_update_npm ;;
  version)
    echo "Configured NPM image: $(current_image)"
    echo "Configured DB image: $(awk -F= '/^DB_IMAGE=/{print $2}' "$ENV_FILE" | tail -n1)"
    echo "AUTO_UPDATE=$(env_flag AUTO_UPDATE)"
    echo "TRACK_LATEST=$(env_flag TRACK_LATEST)"
    ;;
  ""|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
MAINT
echo "  Maintenance script deployed: /usr/local/bin/npm-maint.sh"

# ── Systemd stack unit ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/npm-stack.service <<EOF2
[Unit]
Description=Nginx Proxy Manager (Podman) stack
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/npm
ExecStart=/usr/bin/podman-compose up -d
ExecStop=/usr/bin/podman-compose down
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF2

  systemctl daemon-reload
  systemctl enable --now npm-stack.service
'

# ── Verification ──────────────────────────────────────────────────────────────
sleep 3
if pct exec "$CT_ID" -- systemctl is-active --quiet npm-stack.service 2>/dev/null; then
  echo "  NPM stack service is active"
else
  echo "  WARNING: npm-stack.service may not be active — check: pct exec $CT_ID -- journalctl -u npm-stack --no-pager -n 50" >&2
fi

RUNNING=0
for i in $(seq 1 90); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc 'podman ps --format "{{.Names}}" 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge 2 ]] && break
  sleep 2
done
pct exec "$CT_ID" -- bash -lc 'cd /opt/npm && podman-compose ps' || true

NPM_HEALTHY=0
for i in $(seq 1 45); do
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc "curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:${NPM_ADMIN_PORT}/ 2>/dev/null" 2>/dev/null || echo 000)"
  case "$HTTP_CODE" in
    200|301|302|401|403)
      NPM_HEALTHY=1
      break
      ;;
  esac
  sleep 2
done

if [[ "$NPM_HEALTHY" -eq 1 ]]; then
  echo "  NPM admin check passed"
else
  echo "  WARNING: NPM admin UI did not become reachable yet" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u npm-stack.service --no-pager -n 80" >&2
  echo "  Check: pct exec $CT_ID -- bash -lc 'cd /opt/npm && podman-compose logs --tail=80'" >&2
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
Unattended-Upgrade::Package-Blacklist {
};
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
printf '\n  Nginx Proxy Manager (Podman)\n'
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
printf '  Stack:     /opt/npm (%s containers running)\n' \"\$running\"
printf '  Compose:   cd /opt/npm && podman-compose [up -d|down|logs|ps]\n'
printf '  Maintain:  /usr/local/bin/npm-maint.sh [backup|list|restore|rollback|update|auto-update|version]\n'
printf '  Rollback:  /usr/local/bin/npm-maint.sh rollback /opt/npm-backups/<backup.tar.gz>\n'
printf '  Updates:   systemctl status npm-update.timer\n'
printf '  Admin UI:  http://%s:${NPM_ADMIN_PORT}\n' \"\${ip:-n/a}\"
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
NPM_DESC="<a href='http://${CT_IP}:${NPM_ADMIN_PORT}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>NPM Admin</a>
<details><summary>Details</summary>Nginx Proxy Manager (Podman)${CF_NOTE} on Debian ${DEBIAN_VERSION} LXC
Created by npm-podman.sh</details>"
pct set "$CT_ID" --description "$NPM_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "CT: $CT_ID | IP: ${CT_IP} | Admin: http://${CT_IP}:${NPM_ADMIN_PORT}"
echo "    Policy: AUTO_UPDATE=${AUTO_UPDATE} TRACK_LATEST=${TRACK_LATEST}"
echo "    pct exec $CT_ID -- /usr/local/bin/npm-maint.sh backup"
echo "    pct exec $CT_ID -- /usr/local/bin/npm-maint.sh list"
echo "    pct exec $CT_ID -- /usr/local/bin/npm-maint.sh update <npm-tag|latest>"
echo "    pct exec $CT_ID -- /usr/local/bin/npm-maint.sh restore /opt/npm-backups/<backup.tar.gz>"
echo "    pct exec $CT_ID -- /usr/local/bin/npm-maint.sh rollback /opt/npm-backups/<backup.tar.gz>"
echo "    pct exec $CT_ID -- /usr/local/bin/npm-maint.sh auto-update"
echo ""
