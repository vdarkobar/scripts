#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID="$(pvesh get /cluster/nextid)"
HN="searxng"
CPU=2
RAM=2048
DISK=7
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# SearXNG
APP_PORT=8888
APP_TZ="Europe/Berlin"
TAGS="searxng;search;lxc"
SEARXNG_DIR="/usr/local/searxng"
SEARXNG_REPO="https://github.com/searxng/searxng"
SEARXNG_SETTINGS_PATH="/etc/searxng/settings.yml"

# Optional features
ENABLE_AUTO_UPDATE=0
ALLOW_CONSOLE_AUTOLOGIN_IF_BLANK=0

DEBIAN_VERSION=13

# Behavior
CLEANUP_ON_FAIL=1

# ── Custom configs created by this script ─────────────────────────────────────
#   /etc/apt/sources.list.d/backports.sources
#   /etc/searxng/settings.yml
#   /etc/systemd/system/searxng.service
#   /etc/systemd/system/container-getty@1.service.d/override.conf  (optional)
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
[[ "$ENABLE_AUTO_UPDATE" =~ ^[01]$ ]] || { echo "  ERROR: ENABLE_AUTO_UPDATE must be 0 or 1." >&2; exit 1; }
[[ "$ALLOW_CONSOLE_AUTOLOGIN_IF_BLANK" =~ ^[01]$ ]] || { echo "  ERROR: ALLOW_CONSOLE_AUTOLOGIN_IF_BLANK must be 0 or 1." >&2; exit 1; }

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

for cmd in pvesh pveam pct pvesm curl python3 ip awk sort paste; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

# ── Discover available resources ──────────────────────────────────────────────
AVAIL_TMPL_STORES="$(pvesh get /storage --output-format json 2>/dev/null | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'vztmpl' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_CT_STORES="$(pvesh get /storage --output-format json 2>/dev/null | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content','') or 'images' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_BRIDGES="$(ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^vmbr[[:alnum:]_.-]*$/ {print $2}' | sort -u | awk 'BEGIN{first=1} {if (!first) printf ", "; printf "%s",$0; first=0} END{if (first) printf "n/a"; printf "\n"}')"
AVAIL_BRIDGES="${AVAIL_BRIDGES//$'\n'/}"

# ── Show defaults & confirm ───────────────────────────────────────────────────
cat <<EOF2

  SearXNG LXC Creator — Configuration
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
  Install source:    git clone (helper-style upstream method)
  App port:          $APP_PORT
  Timezone:          $APP_TZ
  Tags:              $TAGS
  Auto-update:       $([ "$ENABLE_AUTO_UPDATE" -eq 1 ] && echo "enabled" || echo "installed but disabled")
  Console autologin: $([ "$ALLOW_CONSOLE_AUTOLOGIN_IF_BLANK" -eq 1 ] && echo "allowed if password blank" || echo "disabled")
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/searxng.sh"
SCRIPT_LOCAL="/root/searxng.sh"
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
  -features "nesting=1"
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
  apt-get install -y locales curl ca-certificates git sudo python3-dev python3-babel python3-venv python-is-python3 uwsgi uwsgi-plugin-python3 build-essential libxslt-dev zlib1g-dev libffi-dev libssl-dev valkey jq
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

# ── SearXNG install method (helper-style) ─────────────────────────────────────
SECRET_KEY="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail

  cat > /etc/apt/sources.list.d/backports.sources <<'EOF2'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-backports
Components: main
EOF2

  apt-get update -qq

  useradd --system --shell /bin/bash --home-dir '${SEARXNG_DIR}' --comment 'Privacy-respecting metasearch engine' searxng 2>/dev/null || true
  mkdir -p '${SEARXNG_DIR}'
  chown -R searxng:searxng '${SEARXNG_DIR}'

  if [[ ! -d '${SEARXNG_DIR}/searxng-src/.git' ]]; then
    sudo -H -u searxng git clone '${SEARXNG_REPO}' '${SEARXNG_DIR}/searxng-src'
  fi

  sudo -H -u searxng bash -lc '
    set -euo pipefail
    python3 -m venv ${SEARXNG_DIR}/searx-pyenv
    . ${SEARXNG_DIR}/searx-pyenv/bin/activate
    pip install -U pip setuptools wheel pyyaml lxml msgspec typing_extensions
    pip install --use-pep517 --no-build-isolation -e ${SEARXNG_DIR}/searxng-src
  '

  mkdir -p /etc/searxng
  cat > '${SEARXNG_SETTINGS_PATH}' <<EOF2
use_default_settings: true
general:
  debug: false
  instance_name: "SearXNG"
  privacypolicy_url: false
  contact_url: false
server:
  bind_address: "0.0.0.0"
  port: ${APP_PORT}
  secret_key: "${SECRET_KEY}"
  limiter: false
  image_proxy: true
valkey:
  url: "valkey://localhost:6379/0"
ui:
  static_use_hash: true
enabled_plugins:
  - 'Hash plugin'
  - 'Self Information'
  - 'Tracker URL remover'
  - 'Ahmia blacklist'
search:
  safe_search: 2
  autocomplete: 'google'
engines:
  - name: google
    engine: google
    shortcut: gg
    use_mobile_ui: false
  - name: duckduckgo
    engine: duckduckgo
    shortcut: ddg
    display_error_messages: true
EOF2

  chown searxng:searxng '${SEARXNG_SETTINGS_PATH}'
  chmod 0640 '${SEARXNG_SETTINGS_PATH}'

  cat > /etc/systemd/system/searxng.service <<EOF2
[Unit]
Description=SearXNG service
After=network.target valkey-server.service
Wants=valkey-server.service

[Service]
Type=simple
User=searxng
Group=searxng
Environment=\"SEARXNG_SETTINGS_PATH=${SEARXNG_SETTINGS_PATH}\"
ExecStart=${SEARXNG_DIR}/searx-pyenv/bin/python -m searx.webapp
WorkingDirectory=${SEARXNG_DIR}/searxng-src
Restart=always

[Install]
WantedBy=multi-user.target
EOF2

  systemctl daemon-reload
  systemctl enable --now valkey-server
  systemctl enable --now searxng
"

echo "  SearXNG installed to ${SEARXNG_DIR}"

# ── Verification ──────────────────────────────────────────────────────────────
sleep 3
if pct exec "$CT_ID" -- systemctl is-active --quiet searxng 2>/dev/null; then
  echo "  SearXNG service is running"
else
  echo "  WARNING: SearXNG may not be running — check: pct exec $CT_ID -- journalctl -u searxng --no-pager -n 50" >&2
fi

if pct exec "$CT_ID" -- systemctl is-active --quiet valkey-server 2>/dev/null; then
  echo "  Valkey service is running"
else
  echo "  WARNING: Valkey may not be running — check: pct exec $CT_ID -- journalctl -u valkey-server --no-pager -n 50" >&2
fi

HEALTHY=0
for i in $(seq 1 30); do
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${APP_PORT}/ 2>/dev/null" 2>/dev/null || echo "000")"
  if [[ "$HTTP_CODE" =~ ^(200|302)$ ]]; then
    HEALTHY=1
    break
  fi
  sleep 2
done
if [[ "$HEALTHY" -eq 1 ]]; then
  echo "  SearXNG HTTP health check passed (port ${APP_PORT} — HTTP $HTTP_CODE)"
else
  echo "  WARNING: SearXNG not responding on port ${APP_PORT} yet" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u searxng --no-pager -n 80" >&2
fi


# ── Maintenance script ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/searxng-maint.sh && chmod 0755 /usr/local/bin/searxng-maint.sh' <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR="${APP_DIR:-/usr/local/searxng}"
REPO_DIR="${REPO_DIR:-/usr/local/searxng/searxng-src}"
VENV_DIR="${VENV_DIR:-/usr/local/searxng/searx-pyenv}"
SETTINGS_PATH="${SETTINGS_PATH:-/etc/searxng/settings.yml}"
SERVICE="${SERVICE:-searxng}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/searxng}"
APP_PORT="${APP_PORT:-8888}"

need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF2
  SearXNG Maintenance
  ───────────────────
  Usage:
    $0 backup
    $0 list
    $0 restore <backup.tar.gz>
    $0 update
    $0 version

  Notes:
    - backup is a scoped operational backup of settings.yml + searxng.service
    - backup does not replace PBS CT backup
    - update backs up first, then fast-forwards the existing git checkout
    - update refreshes the Python venv and rolls back on failed health check
EOF2
}

[[ -d "$APP_DIR" ]] || die "APP_DIR not found: $APP_DIR"
[[ -d "$REPO_DIR/.git" ]] || die "Missing git checkout: $REPO_DIR"
[[ -x "$VENV_DIR/bin/python" ]] || die "Missing Python venv: $VENV_DIR"
[[ -f "$SETTINGS_PATH" ]] || die "Missing settings file: $SETTINGS_PATH"
[[ -f "/etc/systemd/system/${SERVICE}.service" ]] || die "Missing service unit: /etc/systemd/system/${SERVICE}.service"

create_backup() {
  local ts out
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$BACKUP_DIR/searxng-backup-$ts.tar.gz"

  mkdir -p "$BACKUP_DIR"

  echo "  Creating scoped backup: $out" >&2
  tar -C / -czf "$out" \
    "etc/systemd/system/${SERVICE}.service" \
    "etc/searxng/settings.yml"
  printf '%s\n' "$out"
}

backup_cmd() {
  local out
  out="$(create_backup)"
  echo "  OK: $out"
}

list_cmd() {
  ls -1t "$BACKUP_DIR"/searxng-backup-*.tar.gz 2>/dev/null || true
}

restore_cmd() {
  local backup="$1" tmp
  [[ -n "$backup" ]] || die "Usage: /usr/local/bin/searxng-maint.sh restore <backup.tar.gz>"
  [[ -f "$backup" ]] || die "Backup not found: $backup"

  tmp="$(mktemp -d /tmp/searxng-restore.XXXXXX)"
  trap 'rm -rf "$tmp"' RETURN

  echo "  Restoring scoped backup: $backup"
  tar -C "$tmp" -xzf "$backup"
  [[ -f "$tmp/etc/systemd/system/${SERVICE}.service" ]] || die "Backup missing service unit."
  [[ -f "$tmp/etc/searxng/settings.yml" ]] || die "Backup missing settings.yml."

  systemctl stop "$SERVICE" 2>/dev/null || true
  install -d /etc/systemd/system /etc/searxng
  install -m 0644 "$tmp/etc/systemd/system/${SERVICE}.service" "/etc/systemd/system/${SERVICE}.service"
  install -o searxng -g searxng -m 0640 "$tmp/etc/searxng/settings.yml" "$SETTINGS_PATH"
  systemctl daemon-reload
  systemctl restart "$SERVICE"
  echo "  OK: restore completed."
}

update_cmd() {
  local current_rev target_rev backup_file health http_code

  backup_file="$(create_backup)"
  [[ -n "$backup_file" ]] || die "Backup step failed."
  current_rev="$(su -s /bin/bash -c "git -C '$REPO_DIR' rev-parse HEAD" searxng)"

  echo "  Current revision: ${current_rev:0:12}"
  echo "  Fetching upstream ..."
  su -s /bin/bash -c "git -C '$REPO_DIR' fetch --quiet --all --tags" searxng
  target_rev="$(su -s /bin/bash -c "git -C '$REPO_DIR' rev-parse '@{u}'" searxng 2>/dev/null || true)"

  if [[ -n "$target_rev" && "$target_rev" == "$current_rev" ]]; then
    echo "  Already up to date."
    return 0
  fi

  rollback() {
    echo "  !! Update failed — rolling back to previous revision ..." >&2
    systemctl stop "$SERVICE" 2>/dev/null || true
    su -s /bin/bash -c "git -C '$REPO_DIR' reset --hard '$current_rev'" searxng || true
    su -s /bin/bash -c ". '$VENV_DIR/bin/activate' && pip install -U pip setuptools wheel pyyaml lxml msgspec typing_extensions && pip install --use-pep517 --no-build-isolation -e '$REPO_DIR'" searxng || true
    restore_cmd "$backup_file" || true
  }
  trap rollback ERR

  echo "  Stopping service"
  systemctl stop "$SERVICE"

  echo "  Fast-forwarding checkout"
  su -s /bin/bash -c "git -C '$REPO_DIR' pull --ff-only" searxng

  echo "  Refreshing Python venv"
  su -s /bin/bash -c ". '$VENV_DIR/bin/activate' && pip install -U pip setuptools wheel pyyaml lxml msgspec typing_extensions && pip install --use-pep517 --no-build-isolation -e '$REPO_DIR'" searxng

  echo "  Starting service"
  systemctl start "$SERVICE"

  echo "  Waiting for local HTTP health check"
  health=0
  for i in $(seq 1 45); do
    http_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${APP_PORT}/" 2>/dev/null || echo 000)"
    if [[ "$http_code" =~ ^(200|302)$ ]]; then
      health=1
      break
    fi
    sleep 2
  done
  [[ "$health" -eq 1 ]] || die "SearXNG did not return HTTP 200/302 on 127.0.0.1:${APP_PORT} after update."

  trap - ERR
  echo "  OK: updated to $(su -s /bin/bash -c "git -C '$REPO_DIR' rev-parse --short HEAD" searxng)"
}

version_cmd() {
  echo "Service: $(systemctl is-active "$SERVICE" 2>/dev/null || echo unknown)"
  echo "Revision: $(su -s /bin/bash -c "git -C '$REPO_DIR' rev-parse --short HEAD" searxng 2>/dev/null || echo n/a)"
  echo "Branch: $(su -s /bin/bash -c "git -C '$REPO_DIR' rev-parse --abbrev-ref HEAD" searxng 2>/dev/null || echo n/a)"
  echo "Settings: $SETTINGS_PATH"
  echo "Backup dir: $BACKUP_DIR"
  echo "Local UI: http://127.0.0.1:${APP_PORT}/"
}

need_root
cmd="${1:-}"
case "$cmd" in
  backup) backup_cmd ;;
  list) list_cmd ;;
  restore) shift; restore_cmd "${1:-}" ;;
  update) update_cmd ;;
  version) version_cmd ;;
  ""|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
MAINT
echo "  Maintenance script deployed: /usr/local/bin/searxng-maint.sh"

# ── Auto-update timer (optional) ──────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail

  cat > /etc/systemd/system/searxng-update.service <<EOF2
[Unit]
Description=SearXNG auto-update maintenance run
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/searxng-maint.sh update
StandardOutput=journal
StandardError=journal
EOF2

  cat > /etc/systemd/system/searxng-update.timer <<EOF2
[Unit]
Description=SearXNG weekly auto-update timer

[Timer]
OnCalendar=Sun *-*-* 04:30:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF2

  systemctl daemon-reload
'
if [[ "$ENABLE_AUTO_UPDATE" -eq 1 ]]; then
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
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  > /etc/motd
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
  rm -f /etc/update-motd.d/*
'

pct exec "$CT_ID" -- bash -lc 'cat > /etc/update-motd.d/00-header && chmod 0755 /etc/update-motd.d/00-header' <<'MOTD'
#!/bin/sh
printf '\n  SearXNG\n'
printf '  ────────────────────────────────────\n'
MOTD

pct exec "$CT_ID" -- bash -lc 'cat > /etc/update-motd.d/10-sysinfo && chmod 0755 /etc/update-motd.d/10-sysinfo' <<'MOTD'
#!/bin/sh
ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
printf '  Hostname:  %s\n' "$(hostname)"
printf '  IP:        %s\n' "${ip:-n/a}"
printf '  Uptime:    %s\n' "$(uptime -p 2>/dev/null || uptime)"
printf '  Disk:      %s\n' "$(df -h / | awk 'NR==2{printf "%s/%s (%s used)", $3, $2, $5}')"
MOTD

pct exec "$CT_ID" -- bash -lc 'cat > /etc/update-motd.d/30-app && chmod 0755 /etc/update-motd.d/30-app' <<'MOTD'
#!/bin/sh
service_active=$(systemctl is-active searxng 2>/dev/null || echo 'unknown')
valkey_active=$(systemctl is-active valkey-server 2>/dev/null || echo 'unknown')
ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
timer_next=$(systemctl list-timers searxng-update.timer --no-pager 2>/dev/null | awk 'NR==2{for(i=1;i<=NF;i++) if($i ~ /^[0-9]{4}-/) {printf "%s %s", $i, $(i+1); break}}')
[ -n "$timer_next" ] || timer_next='disabled'
printf '\n'
printf '  SearXNG:\n'
printf '    App dir:         /usr/local/searxng\n'
printf '    Source:          /usr/local/searxng/searxng-src\n'
printf '    Venv:            /usr/local/searxng/searx-pyenv\n'
printf '    Settings:        /etc/searxng/settings.yml\n'
printf '    Service:         %s\n' "$service_active"
printf '    Valkey:          %s\n' "$valkey_active"
printf '    Auto-update:     %s\n' "${timer_next}"
printf '    Web UI (local):  http://%s:8888/\n' "${ip:-n/a}"
printf '\n'
printf '  Maintenance:\n'
printf '    /usr/local/bin/searxng-maint.sh [backup|list|restore|update|version]\n'
printf '    Backup scope: settings.yml + searxng.service\n'
MOTD

pct exec "$CT_ID" -- bash -lc 'cat > /etc/update-motd.d/99-footer && chmod 0755 /etc/update-motd.d/99-footer' <<'MOTD'
#!/bin/sh
printf '  ────────────────────────────────────\n\n'
MOTD

# Set TERM for console
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Proxmox UI description ────────────────────────────────────────────────────
DESC="<a href='http://${CT_IP}:${APP_PORT}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>SearXNG Web UI</a>
<details><summary>Details</summary>SearXNG on Debian ${DEBIAN_VERSION} LXC
Native git + Python venv install
Created by searxng.sh</details>"
pct set "$CT_ID" --description "$DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  CT: $CT_ID | IP: ${CT_IP} | Login: $([ -n "$PASSWORD" ] && echo 'password set' || echo 'no password set')"
echo ""
echo "  Access (local):"
echo "    Main: http://${CT_IP}:${APP_PORT}/"
echo ""
echo "  Config files:"
echo "    ${SEARXNG_SETTINGS_PATH}"
echo "    /etc/systemd/system/searxng.service"
echo ""
echo "  App paths:"
echo "    ${SEARXNG_DIR}/searxng-src"
echo "    ${SEARXNG_DIR}/searx-pyenv"
echo ""
echo "  Service checks:"
echo "    pct exec $CT_ID -- systemctl status searxng --no-pager"
echo "    pct exec $CT_ID -- systemctl status valkey-server --no-pager"
echo ""
echo "  Maintenance:"
echo "    pct exec $CT_ID -- /usr/local/bin/searxng-maint.sh update"
echo "    pct exec $CT_ID -- /usr/local/bin/searxng-maint.sh backup"
echo "    pct exec $CT_ID -- /usr/local/bin/searxng-maint.sh list"
echo "    pct exec $CT_ID -- /usr/local/bin/searxng-maint.sh restore /var/backups/searxng/<backup.tar.gz>"
echo "    pct exec $CT_ID -- /usr/local/bin/searxng-maint.sh version"
echo ""
echo "  Done."
