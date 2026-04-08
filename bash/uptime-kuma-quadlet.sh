#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID=""                             # assigned after preflight validates pvesh
HN="uptime-kuma"
CPU=2
RAM=2048
DISK=8
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Uptime Kuma / Podman + Quadlet
APP_PORT=3001
APP_TZ="Europe/Berlin"
APP_FQDN=""                          # e.g. status.example.com ; blank = local IP mode
TAGS="uptime-kuma;podman;quadlet;lxc"

# Images / versions
APP_IMAGE_REPO="docker.io/louislam/uptime-kuma"
APP_TAG="2.2.1"                      # pinned default; do not default to :latest
DEBIAN_VERSION=13

# Behavior
CLEANUP_ON_FAIL=1

# Derived
APP_DIR="/opt/uptime-kuma"
APP_IMAGE="${APP_IMAGE_REPO}:${APP_TAG}"
QUADLET_FILE="/etc/containers/systemd/uptime-kuma.container"
QUADLET_SERVICE="uptime-kuma.service"

# ── Custom configs created by this script ─────────────────────────────────────
#   /etc/containers/systemd/uptime-kuma.container  (Quadlet unit — source of truth)
#   /opt/uptime-kuma/.env                          (runtime state — read by maint script)
#   /opt/uptime-kuma/data/                         (persistent data — DB backend + uploads; backend selected at first-run setup)
#   /usr/local/bin/uptime-kuma-maint.sh            (maintenance helper)
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
[[ "$CLEANUP_ON_FAIL" =~ ^[01]$ ]] || { echo "  ERROR: CLEANUP_ON_FAIL must be 0 or 1." >&2; exit 1; }
[[ -n "$APP_IMAGE_REPO" && ! "$APP_IMAGE_REPO" =~ [[:space:]] ]] || {
  echo "  ERROR: APP_IMAGE_REPO must be non-empty and contain no spaces." >&2
  exit 1
}
[[ "$APP_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: APP_TAG must be a pinned version like 2.2.1 — ':latest' is not permitted." >&2
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

  Uptime Kuma Quadlet LXC Creator — Configuration
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
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/uptime-kuma-quadlet.sh"
SCRIPT_LOCAL="/root/uptime-kuma-quadlet.sh"
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
echo "  Pulling Uptime Kuma image ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman pull '${APP_IMAGE}'
"

# ── Prepare persistent paths ──────────────────────────────────────────────────
# Uptime Kuma's embedded MariaDB runs as UID 1000 inside the container.
# The mariadb/ and run/ subdirectories must be owned by 1000:1000 or MariaDB
# cannot write its data files or PID socket — even when the container runs as root.
# Upstream guidance is to own the entire data/ tree as 1000:1000. If ownership
# is stomped (e.g. by a :latest image with a different internal UID), fix with:
# chown -R 1000:1000 /opt/uptime-kuma/data
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  install -d -m 0755 '${APP_DIR}'
  install -d -m 0755 -o 1000 -g 1000 '${APP_DIR}/data'
"
# Do NOT pre-create data/mariadb or data/run — embedded MariaDB runs mysql_install_db
# only when it finds those directories absent. Pre-creating them causes MariaDB to skip
# initialization entirely, resulting in "Table mysql.db doesn't exist" on first start.

# ── Quadlet unit file ─────────────────────────────────────────────────────────
# Rootful Quadlet: /etc/containers/systemd/ — no linger, no --user flags needed.
# systemd daemon-reload triggers the Quadlet generator; uptime-kuma.service is
# created as a transient unit and WantedBy=multi-user.target handles boot start.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  mkdir -p /etc/containers/systemd

  cat > '${QUADLET_FILE}' <<EOF2
[Unit]
Description=Uptime Kuma
After=network-online.target
Wants=network-online.target

[Container]
Image=${APP_IMAGE}
ContainerName=uptime-kuma
Network=host
Environment=TZ=${APP_TZ}
Environment=UPTIME_KUMA_PORT=${APP_PORT}
Volume=${APP_DIR}/data:/app/data
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
# truth for current image tag and policy flags. Keep it in sync with the
# Quadlet unit whenever the image is updated.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > '${APP_DIR}/.env' <<EOF2
APP_IMAGE_REPO=${APP_IMAGE_REPO}
APP_TAG=${APP_TAG}
APP_IMAGE=${APP_IMAGE}
APP_PORT=${APP_PORT}
APP_TZ=${APP_TZ}
APP_FQDN=${APP_FQDN}
EOF2
  chmod 0600 '${APP_DIR}/.env'
"

# ── Maintenance script ────────────────────────────────────────────────────────
# Update flow: pull new image → sed Image= in Quadlet file → sed .env →
# daemon-reload → restart service. Rollback restores both files and restarts.
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/uptime-kuma-maint.sh && chmod 0755 /usr/local/bin/uptime-kuma-maint.sh' <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR="${APP_DIR:-/opt/uptime-kuma}"
QUADLET_FILE="/etc/containers/systemd/uptime-kuma.container"
SERVICE="uptime-kuma.service"
ENV_FILE="${APP_DIR}/.env"

need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF2
  Uptime Kuma Maintenance
  ───────────────────────
  Usage:
    $0 update <tag>       # e.g. 2.3.0 — pinned version required, no :latest
    $0 version

  Notes:
    - update pulls the pinned tag, updates the Quadlet unit, and restarts the service
    - :latest is not permitted — always specify an explicit version tag
    - backup and restore are handled by PBS and PVE snapshots
    - take a PVE snapshot before manual updates: pct snapshot <CT_ID> pre-update-\$(date +%Y%m%d)
EOF2
}

[[ -d "$APP_DIR" ]]      || die "APP_DIR not found: $APP_DIR"
[[ -f "$ENV_FILE" ]]     || die "Missing env file: $ENV_FILE"
[[ -f "$QUADLET_FILE" ]] || die "Missing Quadlet unit: $QUADLET_FILE"

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

  local old_tag repo new_image tmp_env tmp_quadlet
  [[ -n "$new_tag" ]] || die "Usage: uptime-kuma-maint.sh update <tag>"
  [[ "$new_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] \
    || die "Invalid tag: $new_tag — pinned version required (e.g. 2.3.0), ':latest' is not permitted."

  old_tag="$(current_tag)"
  repo="$(current_repo)"
  [[ -n "$repo" ]] || die "Could not read APP_IMAGE_REPO from .env"
  new_image="${repo}:${new_tag}"
  tmp_env="$(mktemp)"
  tmp_quadlet="$(mktemp)"

  echo "  Current tag: $old_tag"
  echo "  Target  tag: $new_tag"

  # Guard: verify MariaDB data directory ownership before pulling anything.
  # Uptime Kuma's embedded MariaDB runs as UID 1000. If a previous image update
  # stomped ownership to root, MariaDB cannot start after this update either.
  # Catch it here before making things worse.
  local mariadb_dir="${APP_DIR}/data/mariadb"
  if [[ -d "$mariadb_dir" ]]; then
    local dir_uid
    dir_uid="$(stat -c '%u' "$mariadb_dir" 2>/dev/null || echo "unknown")"
    if [[ "$dir_uid" != "1000" ]]; then
      echo ""
      echo "  WARNING: MariaDB data directory is owned by UID ${dir_uid}, expected 1000."
      echo "  This means a previous image update stomped the ownership."
      echo "  MariaDB will fail to start after this update unless ownership is fixed first."
      echo ""
      echo "  Fix with:"
      echo "    chown -R 1000:1000 ${APP_DIR}/data"
      echo ""
      if [[ "$skip_confirm" -eq 0 ]]; then
        read -r -p "  Fix ownership now and continue? [y/N]: " own_confirm
        case "$own_confirm" in
          [yY][eE][sS]|[yY])
            chown -R 1000:1000 "${APP_DIR}/data" 2>/dev/null || true
            echo "  Ownership fixed."
            ;;
          *) echo "  Aborted."; rm -f "$tmp_env" "$tmp_quadlet"; exit 0 ;;
        esac
      else
        echo "  --yes flag set — fixing ownership automatically."
        chown -R 1000:1000 "${APP_DIR}/data" 2>/dev/null || true
      fi
    fi
  fi

  # Guard: embedded-mariadb installs are sensitive to image changes between tags.
  # A newer image may fail to start MariaDB silently and fall back to a fresh
  # SQLite database, making the app appear to lose all data. Warn before pull.
  local db_config="${APP_DIR}/data/db-config.json"
  if [[ -f "$db_config" ]]; then
    local db_type
    db_type="$(grep -o '"type"[[:space:]]*:[[:space:]]*"[^"]*"' "$db_config" \
      | grep -o '"[^"]*"$' | tr -d '"' || echo "unknown")"
    if [[ "$db_type" == "embedded-mariadb" ]]; then
      echo ""
      echo "  WARNING: This install uses embedded-mariadb as its database backend."
      echo "  Some image updates silently fail to start MariaDB and fall back to"
      echo "  a fresh SQLite database, making the app appear to lose all data."
      echo "  Your data would NOT be gone — but the new image may not be compatible."
      echo ""
      echo "  Take a PBS snapshot or pct snapshot before continuing."
      echo ""
      if [[ "$skip_confirm" -eq 0 ]]; then
        read -r -p "  Proceed with embedded-mariadb install? [y/N]: " db_confirm
        case "$db_confirm" in
          [yY][eE][sS]|[yY]) ;;
          *) echo "  Aborted."; rm -f "$tmp_env" "$tmp_quadlet"; exit 0 ;;
        esac
      else
        echo "  --yes flag set — proceeding with embedded-mariadb install."
      fi
    fi
  fi

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
    -e "s|^APP_TAG=.*|APP_TAG=$new_tag|" \
    -e "s|^APP_IMAGE=.*|APP_IMAGE=$new_image|" \
    "$ENV_FILE"

  echo "  Reloading Quadlet and restarting service ..."
  systemctl daemon-reload
  systemctl restart "$SERVICE"

  echo "  Waiting for UI ..."
  if ! wait_for_app; then
    trap - ERR
    rollback
    die "Uptime Kuma did not become reachable after update."
  fi

  trap - ERR
  cleanup
  echo "  OK: Uptime Kuma updated to $new_tag"
}

need_root
cmd="${1:-}"
case "$cmd" in
  update)      shift; update_app "$@" ;;
  version)
    echo "Configured image: $(current_image)"
    ;;
  ""|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
MAINT
echo "  Maintenance script deployed: /usr/local/bin/uptime-kuma-maint.sh"

# ── Start via Quadlet ─────────────────────────────────────────────────────────
# daemon-reload triggers the Quadlet generator which produces uptime-kuma.service
# as a transient systemd unit. WantedBy=multi-user.target handles boot restarts.
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
  echo "  Check: pct exec $CT_ID -- systemctl status uptime-kuma.service" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u uptime-kuma.service --no-pager -n 50" >&2
  VERIFY_FAIL=1
fi

RUNNING=0
for i in $(seq 1 60); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc \
    'podman ps --filter name=^uptime-kuma$ --format "{{.Names}}" 2>/dev/null | wc -l' \
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

UK_HEALTHY=0
for i in $(seq 1 90); do
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
  echo "  ERROR: Uptime Kuma did not become reachable on port ${APP_PORT}" >&2
  echo "  Check: pct exec $CT_ID -- systemctl status uptime-kuma.service" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u uptime-kuma.service --no-pager -n 80" >&2
  VERIFY_FAIL=1
fi

if (( VERIFY_FAIL == 1 )); then
  echo "" >&2
  echo "  FATAL: Core verification failed — CT $CT_ID is preserved but the install is incomplete." >&2
  echo "  Inspect the container and fix manually, or destroy and re-run." >&2
  exit 1
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
printf '\n  Uptime Kuma (Podman/Quadlet)\n'
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
running=\$(podman ps --filter name=^uptime-kuma$ --format '{{.Names}}' 2>/dev/null | wc -l)
svc_status=\$(systemctl is-active uptime-kuma.service 2>/dev/null || echo "unknown")
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
fqdn=\"\$(awk -F= '/^APP_FQDN=/{print \$2}' /opt/uptime-kuma/.env 2>/dev/null | tail -n1)\"
port=\"\$(awk -F= '/^APP_PORT=/{print \$2}' /opt/uptime-kuma/.env 2>/dev/null | tail -n1)\"
port=\"\${port:-3001}\"
printf '  Container: uptime-kuma (%s running)\n' \"\$running\"
printf '  Service:   uptime-kuma.service (%s)\n' \"\$svc_status\"
printf '  Logs:      journalctl -u uptime-kuma.service -f\n'
printf '  Maintain:  /usr/local/bin/uptime-kuma-maint.sh [update|version]\n'
if [ -n \"\$fqdn\" ]; then
  printf '  Web UI:    https://%s\n' \"\$fqdn\"
fi
printf '  Web UI:    http://%s:%s\n' \"\${ip:-n/a}\" \"\$port\"
printf '  Password:  podman exec uptime-kuma node /app/extra/reset-password.js\n'
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
<details><summary>Details</summary>Uptime Kuma (Podman/Quadlet) on Debian ${DEBIAN_VERSION} LXC
Created by uptime-kuma-quadlet.sh</details>"
pct set "$CT_ID" --description "$UK_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "    CT: $CT_ID | IP: ${CT_IP} | Web UI: http://${CT_IP}:${APP_PORT}"
if [[ -n "$APP_FQDN" ]]; then
  echo "    Public: https://${APP_FQDN}"
fi
echo "    Image:   ${APP_IMAGE}"
echo "    Quadlet: ${QUADLET_FILE}"
echo ""
echo "    pct exec $CT_ID -- systemctl status uptime-kuma.service"
echo "    pct exec $CT_ID -- journalctl -u uptime-kuma.service --no-pager -n 50"
echo "    pct exec $CT_ID -- /usr/local/bin/uptime-kuma-maint.sh update <tag>  # e.g. 2.3.0 — no :latest"
echo "    pct exec $CT_ID -- /usr/local/bin/uptime-kuma-maint.sh version"
echo "    Backup/restore: use PBS or PVE snapshots"
echo ""
echo "    NPM reverse proxy: http | ${CT_IP}:${APP_PORT} | enable Websockets Support"
echo "    First visit creates the admin account."
echo "    Session lost after update/restart — log in again or reset password:"
echo "    pct exec $CT_ID -- podman exec uptime-kuma node /app/extra/reset-password.js"
echo ""
