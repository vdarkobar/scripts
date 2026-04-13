#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
CT_ID="$(pvesh get /cluster/nextid)"
HN="flatnotes"
CPU=2
RAM=1024
DISK=8
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Flatnotes / Podman
APP_PORT=8080
APP_TZ="Europe/Berlin"
APP_FQDN=""                             # e.g. notes.example.com — used in Proxmox UI description; leave blank if not yet known
FLATNOTES_AUTH_TYPE="password"          # password | none | read_only | totp
FLATNOTES_SESSION_EXPIRY_DAYS=1         # days before login token expires and re-auth is required
FLATNOTES_PATH_PREFIX=""                # sub-path if hosting at a prefix e.g. /flatnotes; leave blank for root
TAGS="flatnotes;podman;lxc"

# Images / versions
APP_IMAGE_REPO="docker.io/dullage/flatnotes"
APP_TAG="v5.5.4"                        # verify latest: https://github.com/dullage/flatnotes/releases
DEBIAN_VERSION=13

# Policy
AUTO_UPDATE=0                           # 1 = enable timer-driven maintenance/update runs
TRACK_LATEST=0                          # 1 = auto-update follows :latest
KEEP_BACKUPS=7

# Extra packages to install (space-separated or array)
EXTRA_PACKAGES=(
  qemu-guest-agent
)

# Behavior
CLEANUP_ON_FAIL=1

# Derived
APP_DIR="/opt/flatnotes"
BACKUP_DIR="/opt/flatnotes-backups"
APP_IMAGE="${APP_IMAGE_REPO}:${APP_TAG}"

# ── Custom configs created by this script ─────────────────────────────────────
#   /opt/flatnotes/docker-compose.yml         (Podman compose stack)
#   /opt/flatnotes/.env                       (runtime config, credentials, policy)
#   /opt/flatnotes/data/                      (notes, attachments, .flatnotes search index)
#   /opt/flatnotes-backups/                   (compressed operational backups)
#   /usr/local/bin/flatnotes-maint.sh         (maintenance helper)
#   /etc/systemd/system/flatnotes-stack.service
#   /etc/systemd/system/flatnotes-update.service
#   /etc/systemd/system/flatnotes-update.timer
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/sysctl.d/99-hardening.conf

# ── Config validation ──────────────────────────────────────────────────────────
[[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }
[[ "$APP_PORT" =~ ^[0-9]+$ ]] || { echo "  ERROR: APP_PORT must be numeric." >&2; exit 1; }
(( APP_PORT >= 1 && APP_PORT <= 65535 )) || { echo "  ERROR: APP_PORT must be between 1 and 65535." >&2; exit 1; }
[[ "$KEEP_BACKUPS" =~ ^[0-9]+$ ]] || { echo "  ERROR: KEEP_BACKUPS must be numeric." >&2; exit 1; }
[[ "$AUTO_UPDATE" =~ ^[01]$ ]] || { echo "  ERROR: AUTO_UPDATE must be 0 or 1." >&2; exit 1; }
[[ "$TRACK_LATEST" =~ ^[01]$ ]] || { echo "  ERROR: TRACK_LATEST must be 0 or 1." >&2; exit 1; }
[[ "$FLATNOTES_AUTH_TYPE" =~ ^(password|none|read_only|totp)$ ]] || {
  echo "  ERROR: FLATNOTES_AUTH_TYPE must be password, none, read_only, or totp." >&2; exit 1;
}
[[ "$FLATNOTES_SESSION_EXPIRY_DAYS" =~ ^[0-9]+$ ]] || { echo "  ERROR: FLATNOTES_SESSION_EXPIRY_DAYS must be numeric." >&2; exit 1; }
[[ -z "$FLATNOTES_PATH_PREFIX" || "$FLATNOTES_PATH_PREFIX" =~ ^/[A-Za-z0-9._~-]+$ ]] || {
  echo "  ERROR: FLATNOTES_PATH_PREFIX must be empty or start with / and contain no trailing slash (e.g. /flatnotes)." >&2; exit 1;
}
[[ "$APP_TAG" == "latest" || "$APP_TAG" =~ ^v[0-9]+(\.[0-9]+){0,2}([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: APP_TAG must look like v5, v5.5, v5.5.4, or latest." >&2; exit 1;
}
[[ -e "/usr/share/zoneinfo/${APP_TZ}" ]] || {
  echo "  ERROR: APP_TZ not found in /usr/share/zoneinfo: $APP_TZ" >&2; exit 1;
}

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

  Flatnotes-Podman LXC Creator — Configuration
  ─────────────────────────────────────────────
  CT ID:             $CT_ID
  Hostname:          $HN
  CPU cores:         $CPU
  RAM (MB):          $RAM
  Disk (GB):         $DISK
  Bridge:            $BRIDGE ($AVAIL_BRIDGES)
  Template storage:  $TEMPLATE_STORAGE ($AVAIL_TMPL_STORES)
  Container storage: $CONTAINER_STORAGE ($AVAIL_CT_STORES)
  Debian:            $DEBIAN_VERSION
  Image tag:         $APP_TAG
  App port:          $APP_PORT
  Public FQDN:       ${APP_FQDN:-"(not set)"}
  Auth type:         $FLATNOTES_AUTH_TYPE
  Session expiry:    ${FLATNOTES_SESSION_EXPIRY_DAYS} days
  Path prefix:       ${FLATNOTES_PATH_PREFIX:-"(none)"}
  Timezone:          $APP_TZ
  Tags:              $TAGS
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled" || echo "disabled")
  Track latest:      $([ "$TRACK_LATEST" -eq 1 ] && echo "enabled" || echo "disabled")
  Keep backups:      $KEEP_BACKUPS
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ─────────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/flatnotes-podman.sh"
SCRIPT_LOCAL="/root/flatnotes-podman.sh"
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

# ── Flatnotes credentials ─────────────────────────────────────────────────────
# Credentials are embedded in .env via shell expansion. Restrict chars that
# would break double-quoted shell string context: " $ ` \
FLATNOTES_USERNAME=""
FLATNOTES_PASSWORD=""
FLATNOTES_TOTP_KEY=""
if [[ "$FLATNOTES_AUTH_TYPE" == "password" || "$FLATNOTES_AUTH_TYPE" == "totp" ]]; then
  while true; do
    read -r -p "  Flatnotes username: " FLATNOTES_USERNAME
    [[ -z "$FLATNOTES_USERNAME" ]] && { echo "  Username cannot be empty."; continue; }
    [[ "$FLATNOTES_USERNAME" =~ [[:space:]] ]] && { echo "  Username cannot contain spaces."; continue; }
    [[ "$FLATNOTES_USERNAME" =~ [\"$\`\\] ]] && { echo '  Username cannot contain " $ ` or \'; continue; }
    break
  done
  echo ""
  while true; do
    read -r -s -p "  Flatnotes password: " FN_PW1; echo
    if [[ -z "$FN_PW1" ]]; then echo "  Password cannot be blank."; continue; fi
    if [[ ${#FN_PW1} -lt 8 ]]; then echo "  Password must be at least 8 characters."; continue; fi
    if [[ "$FN_PW1" =~ [\"$\`\\] ]]; then echo '  Password cannot contain " $ ` or \'; continue; fi
    read -r -s -p "  Verify Flatnotes password: " FN_PW2; echo
    if [[ "$FN_PW1" == "$FN_PW2" ]]; then FLATNOTES_PASSWORD="$FN_PW1"; break; fi
    echo "  Passwords do not match. Try again."
  done
  echo ""
fi

if [[ "$FLATNOTES_AUTH_TYPE" == "totp" ]]; then
  set +o pipefail
  FLATNOTES_TOTP_KEY="$(head -c 4096 /dev/urandom | tr -dc 'A-Z2-7' | head -c 32)"
  set -o pipefail
  [[ ${#FLATNOTES_TOTP_KEY} -eq 32 ]] || { echo "  ERROR: Failed to generate TOTP key." >&2; exit 1; }
  echo "  Generated TOTP secret key (shown in summary — add to your authenticator app)."
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

# ── Pull image ────────────────────────────────────────────────────────────────
echo "  Pulling Flatnotes image ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman pull '${APP_IMAGE}'
"

# ── Generate secret key ───────────────────────────────────────────────────────
# FLATNOTES_SECRET_KEY is used for JWT signing — only required for password and totp auth.
SECRET_KEY=""
if [[ "$FLATNOTES_AUTH_TYPE" == "password" || "$FLATNOTES_AUTH_TYPE" == "totp" ]]; then
  set +o pipefail
  SECRET_KEY="$(head -c 4096 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 48)"
  set -o pipefail
  [[ ${#SECRET_KEY} -eq 48 ]] || { echo "  ERROR: Failed to generate secret key." >&2; exit 1; }
fi

# ── Prepare persistent paths ──────────────────────────────────────────────────
# Flatnotes runs as PUID/PGID 1000 inside the container (set explicitly in compose).
# The data directory must be owned by 1000:1000 as seen from within the LXC
# so the service can read and write notes and the search index.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  install -d -m 0755 '${APP_DIR}' '${BACKUP_DIR}'
  install -d -m 0755 '${APP_DIR}/data'
  chown 1000:1000 '${APP_DIR}/data'
"

# ── Compose file ──────────────────────────────────────────────────────────────
# Variables with \${ } are kept as literals for podman-compose to expand from .env.
# Variables without backslash (e.g. ${APP_DIR}) are expanded by the outer shell now.
# Written in one pass per auth type — no post-hoc sed patching.
if [[ "$FLATNOTES_AUTH_TYPE" == "totp" ]]; then
  pct exec "$CT_ID" -- bash -lc "cat > '${APP_DIR}/docker-compose.yml' <<'EOF2'
services:
  flatnotes:
    image: \${APP_IMAGE}
    container_name: flatnotes
    restart: unless-stopped
    ports:
      - \"\${APP_PORT}:8080\"
    environment:
      PUID: \"1000\"
      PGID: \"1000\"
      FLATNOTES_AUTH_TYPE: \${FLATNOTES_AUTH_TYPE}
      FLATNOTES_USERNAME: \${FLATNOTES_USERNAME}
      FLATNOTES_PASSWORD: \${FLATNOTES_PASSWORD}
      FLATNOTES_SECRET_KEY: \${FLATNOTES_SECRET_KEY}
      FLATNOTES_TOTP_KEY: \${FLATNOTES_TOTP_KEY}
      FLATNOTES_SESSION_EXPIRY_DAYS: \${FLATNOTES_SESSION_EXPIRY_DAYS}
      FLATNOTES_PATH_PREFIX: \${FLATNOTES_PATH_PREFIX}
    volumes:
      - ${APP_DIR}/data:/data:Z
EOF2"
elif [[ "$FLATNOTES_AUTH_TYPE" == "password" ]]; then
  pct exec "$CT_ID" -- bash -lc "cat > '${APP_DIR}/docker-compose.yml' <<'EOF2'
services:
  flatnotes:
    image: \${APP_IMAGE}
    container_name: flatnotes
    restart: unless-stopped
    ports:
      - \"\${APP_PORT}:8080\"
    environment:
      PUID: \"1000\"
      PGID: \"1000\"
      FLATNOTES_AUTH_TYPE: \${FLATNOTES_AUTH_TYPE}
      FLATNOTES_USERNAME: \${FLATNOTES_USERNAME}
      FLATNOTES_PASSWORD: \${FLATNOTES_PASSWORD}
      FLATNOTES_SECRET_KEY: \${FLATNOTES_SECRET_KEY}
      FLATNOTES_SESSION_EXPIRY_DAYS: \${FLATNOTES_SESSION_EXPIRY_DAYS}
      FLATNOTES_PATH_PREFIX: \${FLATNOTES_PATH_PREFIX}
    volumes:
      - ${APP_DIR}/data:/data:Z
EOF2"
else
  # none / read_only — no credentials or secret key needed
  pct exec "$CT_ID" -- bash -lc "cat > '${APP_DIR}/docker-compose.yml' <<'EOF2'
services:
  flatnotes:
    image: \${APP_IMAGE}
    container_name: flatnotes
    restart: unless-stopped
    ports:
      - \"\${APP_PORT}:8080\"
    environment:
      PUID: \"1000\"
      PGID: \"1000\"
      FLATNOTES_AUTH_TYPE: \${FLATNOTES_AUTH_TYPE}
      FLATNOTES_SESSION_EXPIRY_DAYS: \${FLATNOTES_SESSION_EXPIRY_DAYS}
      FLATNOTES_PATH_PREFIX: \${FLATNOTES_PATH_PREFIX}
    volumes:
      - ${APP_DIR}/data:/data:Z
EOF2"
fi

# ── Runtime .env ──────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  umask 077
  cat > '${APP_DIR}/.env' <<EOF2
COMPOSE_PROJECT_NAME=flatnotes
APP_IMAGE_REPO=${APP_IMAGE_REPO}
APP_TAG=${APP_TAG}
APP_IMAGE=${APP_IMAGE}
APP_PORT=${APP_PORT}
FLATNOTES_AUTH_TYPE=${FLATNOTES_AUTH_TYPE}
FLATNOTES_SESSION_EXPIRY_DAYS=${FLATNOTES_SESSION_EXPIRY_DAYS}
FLATNOTES_PATH_PREFIX=${FLATNOTES_PATH_PREFIX}
AUTO_UPDATE=${AUTO_UPDATE}
TRACK_LATEST=${TRACK_LATEST}
EOF2
  chmod 0600 '${APP_DIR}/.env'
"
if [[ "$FLATNOTES_AUTH_TYPE" == "password" || "$FLATNOTES_AUTH_TYPE" == "totp" ]]; then
  pct exec "$CT_ID" -- bash -lc "
    cat >> '${APP_DIR}/.env' <<EOF2
FLATNOTES_USERNAME=${FLATNOTES_USERNAME}
FLATNOTES_PASSWORD=${FLATNOTES_PASSWORD}
FLATNOTES_SECRET_KEY=${SECRET_KEY}
EOF2
  "
fi
if [[ "$FLATNOTES_AUTH_TYPE" == "totp" ]]; then
  pct exec "$CT_ID" -- bash -lc "echo 'FLATNOTES_TOTP_KEY=${FLATNOTES_TOTP_KEY}' >> '${APP_DIR}/.env'"
fi

# ── Maintenance helper ────────────────────────────────────────────────────────
# Persistent state for Flatnotes:
#   /opt/flatnotes/data/        all notes, attachments, and .flatnotes search index
#   /opt/flatnotes/.env         runtime config, credentials, and secret key
#   /opt/flatnotes/docker-compose.yml
#
# Backup scope of this helper (script-level):
#   .env, docker-compose.yml, and data/
#   Notes are small markdown text files — data/ is safe to archive on every update.
#   PBS covers the full CT backup independently.
#
pct exec "$CT_ID" -- bash -lc "cat > /usr/local/bin/flatnotes-maint.sh <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR=\"\${APP_DIR:-/opt/flatnotes}\"
BACKUP_DIR=\"\${BACKUP_DIR:-/opt/flatnotes-backups}\"
SERVICE=\"flatnotes-stack\"
ENV_FILE=\"\${APP_DIR}/.env\"
KEEP_BACKUPS=\"\${KEEP_BACKUPS:-7}\"
APP_PORT_DEFAULT=\"8080\"

die()       { echo \"  ERROR: \$*\" >&2; exit 1; }
need_root() { [[ \"\$(id -u)\" -eq 0 ]] || die \"Run as root.\"; }

env_flag() { grep \"^\${1}=\" \"\$ENV_FILE\" 2>/dev/null | cut -d= -f2- | tail -n1; }
current_image() { env_flag APP_IMAGE; }
current_tag()   { env_flag APP_TAG; }
current_repo()  { env_flag APP_IMAGE_REPO; }
current_port()  { local p; p=\"\$(env_flag APP_PORT)\"; echo \"\${p:-\$APP_PORT_DEFAULT}\"; }

auto_update_enabled()  { [[ \"\$(env_flag AUTO_UPDATE)\"  == \"1\" ]]; }
track_latest_enabled() { [[ \"\$(env_flag TRACK_LATEST)\" == \"1\" ]]; }

resolve_auto_tag() {
  if track_latest_enabled; then
    echo \"latest\"
  else
    current_tag
  fi
}

wait_for_app() {
  local port
  port=\"\$(current_port)\"
  for i in \$(seq 1 30); do
    code=\"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \"http://127.0.0.1:\${port}/\" 2>/dev/null || echo 000)\"
    case \"\$code\" in 200|301|302|401|403) return 0 ;; esac
    sleep 2
  done
  return 1
}

usage() {
  echo \"Usage: \$0 backup|list|restore <backup.tar.gz>|update <tag>|auto-update|version\"
}

backup_stack() {
  local ts out started=0
  ts=\"\$(date +%Y%m%d-%H%M%S)\"
  out=\"\$BACKUP_DIR/flatnotes-backup-\$ts.tar.gz\"

  mkdir -p \"\$BACKUP_DIR\"

  if systemctl is-active --quiet \"\$SERVICE\"; then
    started=1
    echo \"  Stopping Flatnotes stack for consistent backup ...\"
    systemctl stop \"\$SERVICE\"
  fi

  trap 'if [[ \$started -eq 1 ]]; then systemctl start \"\$SERVICE\" || true; fi' RETURN

  echo \"  Creating backup: \$out\"
  app_rel=\"\${APP_DIR#/}\"
  tar -C / -czf \"\$out\" \
    \"\${app_rel}/.env\" \
    \"\${app_rel}/docker-compose.yml\" \
    \"\${app_rel}/data\"

  if [[ \"\$KEEP_BACKUPS\" =~ ^[0-9]+\$ ]] && (( KEEP_BACKUPS > 0 )); then
    ls -1t \"\$BACKUP_DIR\"/flatnotes-backup-*.tar.gz 2>/dev/null \
      | awk -v keep=\"\$KEEP_BACKUPS\" 'NR>keep' \
      | xargs -r rm -f --
  fi

  echo \"  OK: \$out\"
}

restore_stack() {
  local backup=\"\$1\"
  [[ -n \"\$backup\" ]] || die \"Usage: flatnotes-maint.sh restore <backup.tar.gz>\"
  [[ -f \"\$backup\" ]] || die \"Backup not found: \$backup\"

  echo \"  Stopping Flatnotes stack ...\"
  systemctl stop \"\$SERVICE\" 2>/dev/null || true

  echo \"  Removing current app state ...\"
  rm -rf \"\${APP_DIR}/data\" \"\${APP_DIR}/.env\" \"\${APP_DIR}/docker-compose.yml\"

  echo \"  Restoring from backup ...\"
  tar -C / -xzf \"\$backup\"

  echo \"  Starting Flatnotes stack ...\"
  systemctl start \"\$SERVICE\"

  if wait_for_app; then
    echo \"  OK: restore completed.\"
  else
    die \"Restore completed, but Flatnotes did not become reachable.\"
  fi
}

update_flatnotes() {
  local new_tag=\"\$1\"
  local repo new_image old_tag tmp_env
  [[ -n \"\$new_tag\" ]] || die \"Usage: flatnotes-maint.sh update <tag|latest>\"
  [[ \"\$new_tag\" == \"latest\" || \"\$new_tag\" =~ ^v[0-9]+(\\.[0-9]+){0,2}([.-][A-Za-z0-9._-]+)?\$ ]] \
    || die \"Invalid tag: \$new_tag (expected v5, v5.5, v5.5.4, or latest)\"

  old_tag=\"\$(current_tag)\"
  repo=\"\$(current_repo)\"
  [[ -n \"\$repo\" ]] || die \"Could not read APP_IMAGE_REPO from .env\"
  new_image=\"\${repo}:\${new_tag}\"
  tmp_env=\"\$(mktemp)\"

  echo \"  Current tag: \$old_tag\"
  echo \"  Target  tag: \$new_tag\"

  backup_stack
  cp -a \"\$ENV_FILE\" \"\$tmp_env\"

  rollback() {
    echo \"  !! Update failed — rolling back .env and container ...\" >&2
    cp -a \"\$tmp_env\" \"\$ENV_FILE\"
    cd \"\$APP_DIR\"
    /usr/bin/podman-compose up -d --force-recreate flatnotes || true
  }
  trap rollback ERR

  echo \"  Pulling target image ...\"
  podman pull \"\$new_image\"

  sed -i \
    -e \"s|^APP_TAG=.*|APP_TAG=\$new_tag|\" \
    -e \"s|^APP_IMAGE=.*|APP_IMAGE=\$new_image|\" \
    \"\$ENV_FILE\"

  echo \"  Recreating Flatnotes container ...\"
  cd \"\$APP_DIR\"
  /usr/bin/podman-compose up -d --force-recreate flatnotes

  echo \"  Waiting for Flatnotes ...\"
  wait_for_app || die \"Flatnotes did not become reachable after update.\"

  trap - ERR
  rm -f \"\$tmp_env\"
  echo \"  OK: Flatnotes updated to \$new_tag\"
}

auto_update_flatnotes() {
  # Note: rollback after TRACK_LATEST=1 updates is tag-level only, not image-level.
  # Restoring .env to APP_TAG=latest re-pulls current latest, not the previous digest.
  # For reliable rollback, use PBS to restore the full CT instead.
  if ! auto_update_enabled; then
    echo \"  Auto-update disabled in \${ENV_FILE}; nothing to do.\"
    return 0
  fi

  local target_tag
  target_tag=\"\$(resolve_auto_tag)\"
  if track_latest_enabled; then
    echo \"  Auto-update policy: TRACK_LATEST=1 -> following latest\"
  else
    echo \"  Auto-update policy: TRACK_LATEST=0 -> reapplying configured tag \$(current_tag)\"
  fi

  update_flatnotes \"\$target_tag\"
}

need_root
cmd=\"\${1:-}\"
case \"\$cmd\" in
  backup)       backup_stack ;;
  list)         ls -1t \"\$BACKUP_DIR\"/flatnotes-backup-*.tar.gz 2>/dev/null || true ;;
  restore)      shift; restore_stack \"\${1:-}\" ;;
  update)       shift; update_flatnotes \"\${1:-}\" ;;
  auto-update)  auto_update_flatnotes ;;
  version)
    echo \"Configured image: \$(current_image)\"
    echo \"AUTO_UPDATE=\$(env_flag AUTO_UPDATE)\"
    echo \"TRACK_LATEST=\$(env_flag TRACK_LATEST)\"
    ;;
  ''|-h|--help) usage ;;
  *)            usage; die \"Unknown command: \$cmd\" ;;
esac
MAINT
chmod 0755 /usr/local/bin/flatnotes-maint.sh"
echo "  Maintenance script deployed: /usr/local/bin/flatnotes-maint.sh"

# ── Systemd stack unit ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/flatnotes-stack.service <<EOF2
[Unit]
Description=Flatnotes (Podman) stack
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/flatnotes
ExecStart=/usr/bin/podman-compose up -d
ExecStop=/usr/bin/podman-compose down
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF2

  systemctl daemon-reload
  systemctl enable --now flatnotes-stack.service
'

# ── Verification ──────────────────────────────────────────────────────────────
sleep 3
if pct exec "$CT_ID" -- systemctl is-active --quiet flatnotes-stack.service 2>/dev/null; then
  echo "  Flatnotes stack service is active"
else
  echo "  WARNING: flatnotes-stack.service may not be active" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u flatnotes-stack --no-pager -n 50" >&2
fi

RUNNING=0
for i in $(seq 1 30); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc 'podman ps --format "{{.Names}}" 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge 1 ]] && break
  sleep 2
done
pct exec "$CT_ID" -- bash -lc 'cd /opt/flatnotes && podman-compose ps' || true

FN_HEALTHY=0
for i in $(seq 1 30); do
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc "curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:${APP_PORT}/ 2>/dev/null" 2>/dev/null || echo "000")"
  case "$HTTP_CODE" in
    200|301|302|401|403)
      FN_HEALTHY=1
      break
      ;;
  esac
  sleep 2
done

if [[ "$FN_HEALTHY" -eq 1 ]]; then
  echo "  Flatnotes health check passed (HTTP $HTTP_CODE)"
else
  echo "  WARNING: Flatnotes did not become reachable yet" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u flatnotes-stack --no-pager -n 80" >&2
  echo "  Check: pct exec $CT_ID -- bash -lc 'cd /opt/flatnotes && podman-compose logs --tail=80'" >&2
fi

# ── Auto-update timer (policy-driven) ─────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/flatnotes-update.service <<EOF2
[Unit]
Description=Flatnotes auto-update maintenance run
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/flatnotes-maint.sh auto-update
EOF2

  cat > /etc/systemd/system/flatnotes-update.timer <<EOF2
[Unit]
Description=Flatnotes auto-update timer

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
  pct exec "$CT_ID" -- bash -lc 'systemctl enable --now flatnotes-update.timer'
  echo "  Auto-update timer enabled"
else
  pct exec "$CT_ID" -- bash -lc 'systemctl disable --now flatnotes-update.timer >/dev/null 2>&1 || true'
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
printf '\n  Flatnotes (Podman)\n'
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
printf '\n'
printf '  Flatnotes:\n'
printf '    Stack:    /opt/flatnotes (%s containers running)\n' \"\$running\"
printf '    Compose:  cd /opt/flatnotes && podman-compose [up -d|down|logs|ps]\n'
printf '    Maintain: /usr/local/bin/flatnotes-maint.sh [backup|list|restore|update|auto-update|version]\n'
printf '    Updates:  systemctl status flatnotes-update.timer\n'
printf '    Web UI:   http://%s:${APP_PORT}/\n' \"\${ip:-n/a}\"
printf '\n'
MOTD

  cat > /etc/update-motd.d/99-footer <<'MOTD'
#!/bin/sh
printf '  ────────────────────────────────────\n\n'
MOTD

  chmod +x /etc/update-motd.d/*
"

# ── Proxmox UI description ────────────────────────────────────────────────────
FN_LOCAL_LINK="<a href='http://${CT_IP}:${APP_PORT}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Flatnotes (local)</a>"
if [[ -n "$APP_FQDN" ]]; then
  FN_DESC="<a href='https://${APP_FQDN}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Flatnotes (public)</a> | ${FN_LOCAL_LINK}"
else
  FN_DESC="${FN_LOCAL_LINK}"
fi
FN_DESC+="
<details><summary>Details</summary>Flatnotes (Podman) on Debian ${DEBIAN_VERSION} LXC
Auth: ${FLATNOTES_AUTH_TYPE} | Tag: ${APP_TAG}
Created by flatnotes-podman.sh</details>"
pct set "$CT_ID" --description "$FN_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  CT: $CT_ID | IP: ${CT_IP} | http://${CT_IP}:${APP_PORT}/"
[[ -n "$APP_FQDN" ]] && echo "  Public:  https://${APP_FQDN}/"
echo "  Auth: ${FLATNOTES_AUTH_TYPE} | Policy: AUTO_UPDATE=${AUTO_UPDATE} TRACK_LATEST=${TRACK_LATEST}"
if [[ "$FLATNOTES_AUTH_TYPE" == "totp" ]]; then
  echo ""
  echo "  !! TOTP setup required — add this secret to your authenticator app:"
  echo "     TOTP key: ${FLATNOTES_TOTP_KEY}"
  echo "     (also stored in /opt/flatnotes/.env as FLATNOTES_TOTP_KEY)"
  echo "     QR code:  pct exec $CT_ID -- bash -lc 'cd /opt/flatnotes && podman-compose logs flatnotes'"
fi
echo ""
echo "  Config:  /opt/flatnotes/.env"
echo "  Data:    /opt/flatnotes/data/"
echo ""
echo "  Maintenance:"
echo "    pct exec $CT_ID -- /usr/local/bin/flatnotes-maint.sh backup"
echo "    pct exec $CT_ID -- /usr/local/bin/flatnotes-maint.sh list"
echo "    pct exec $CT_ID -- /usr/local/bin/flatnotes-maint.sh update <tag>"
echo "    pct exec $CT_ID -- /usr/local/bin/flatnotes-maint.sh restore /opt/flatnotes-backups/<backup.tar.gz>"
echo "    pct exec $CT_ID -- /usr/local/bin/flatnotes-maint.sh auto-update"
echo ""
echo "  Done."
