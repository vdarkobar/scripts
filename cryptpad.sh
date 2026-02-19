#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID="$(pvesh get /cluster/nextid)"
HN="cryptpad"
CPU=2
RAM=2048
DISK=8
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Application-specific
NODE_VERSION=22
APP_PORT=3000
APP_TZ="Europe/Berlin"
TAGS="cryptpad;lxc"

# Optional features
INSTALL_ONLYOFFICE=0  # 1 = OnlyOffice components, 0 = CKEditor (default)

DEBIAN_VERSION=13

# Behavior
CLEANUP_ON_FAIL=1  # 1 = destroy CT on error, 0 = keep for debugging

# ── Custom configs created by this script ─────────────────────────────────────
#   /opt/cryptpad/                             (application root)
#   /opt/cryptpad/config/config.js             (application config)
#   /opt/cryptpad-backups/                     (backup directory)
#   /usr/local/bin/cryptpad-maint.sh           (maintenance script)
#   /etc/systemd/system/cryptpad.service
#   /etc/systemd/system/cryptpad-update.service
#   /etc/systemd/system/cryptpad-update.timer
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/systemd/system/container-getty@1.service.d/override.conf
#   /etc/apt/apt.conf.d/52unattended-cryptpad.conf
#   /etc/sysctl.d/99-hardening.conf

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

for cmd in pvesh pveam pct pvesm; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

[[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }

# ── Show defaults & confirm ──────────────────────────────────────────────────
TMPL_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'vztmpl' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
CT_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | paste -sd', ' || echo "n/a")"

cat <<EOF

  CryptPad LXC Creator — Configuration
  ────────────────────────────────────────
  CT ID:             $CT_ID
  Hostname:          $HN
  CPU cores:         $CPU
  RAM (MB):          $RAM
  Disk (GB):         $DISK
  Bridge:            $BRIDGE ($BRIDGES)
  Template storage:  $TEMPLATE_STORAGE ($TMPL_STORES)
  Container storage: $CONTAINER_STORAGE ($CT_STORES)
  Node.js version:   $NODE_VERSION
  App port:          $APP_PORT
  OnlyOffice:        $([ "$INSTALL_ONLYOFFICE" -eq 1 ] && echo "yes" || echo "no")
  Timezone:          $APP_TZ
  Debian:            $DEBIAN_VERSION
  Tags:              $TAGS
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF

read -r -p "  Continue with these settings? [y/N]: " response
case "$response" in
  [yY][eE][sS]|[yY]) ;;
  *) echo "  Cancelled."; exit 0 ;;
esac
echo ""

# ── Preflight — environment ──────────────────────────────────────────────────
pvesm status | awk -v s="$TEMPLATE_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Template storage not found: $TEMPLATE_STORAGE" >&2; exit 1; }
pvesm status | awk -v s="$CONTAINER_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Container storage not found: $CONTAINER_STORAGE" >&2; exit 1; }
ip link show "$BRIDGE" >/dev/null 2>&1 \
  || { echo "  ERROR: Bridge not found: $BRIDGE" >&2; exit 1; }

# ── Root password prompt ─────────────────────────────────────────────────────
PASSWORD=""
while true; do
  read -r -s -p "  Set root password (blank = auto-login): " PW1; echo
  [[ -z "$PW1" ]] && break
  if [[ "$PW1" == *" "* ]]; then echo "  Password cannot contain spaces."; continue; fi
  if [[ ${#PW1} -lt 5 ]]; then echo "  Password must be at least 5 characters."; continue; fi
  read -r -s -p "  Verify root password: " PW2; echo
  if [[ "$PW1" == "$PW2" ]]; then PASSWORD="$PW1"; break; fi
  echo "  Passwords do not match. Try again."
done
echo ""
if [[ -z "$PASSWORD" ]]; then
  echo "  WARNING: Blank password enables root auto-login on the Proxmox console."
  echo ""
fi

# ── Template discovery & download ────────────────────────────────────────────
pveam update
echo ""
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }

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

# ── Create LXC ───────────────────────────────────────────────────────────────
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

# ── Start & wait for IPv4 ───────────────────────────────────────────────────
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

# ── Auto-login (if no password) ─────────────────────────────────────────────
if [[ -z "$PASSWORD" ]]; then
  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    mkdir -p /etc/systemd/system/container-getty@1.service.d
    cat > /etc/systemd/system/container-getty@1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 \$TERM
EOF
    systemctl daemon-reload
    systemctl restart container-getty@1.service
  '
fi

# ── OS update ────────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  export LANG=C.UTF-8
  export LC_ALL=C.UTF-8
  systemctl disable -q --now systemd-networkd-wait-online.service 2>/dev/null || true
  apt-get update -qq
  apt-get -o Dpkg::Options::="--force-confold" -y dist-upgrade
  apt-get -y autoremove
  apt-get -y clean
'

# ── Locale ───────────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y locales
  sed -i "s/^# *en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
'

# ── Remove unnecessary services ─────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  systemctl disable --now ssh 2>/dev/null || true
  systemctl disable --now postfix 2>/dev/null || true
  apt-get purge -y openssh-server postfix 2>/dev/null || true
  apt-get -y autoremove
'

# ── Timezone ─────────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  ln -sf /usr/share/zoneinfo/${APP_TZ} /etc/localtime
  echo '${APP_TZ}' > /etc/timezone
"

# ── Application install (Node.js + dependencies) ────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive

  # Base packages
  apt-get update -qq
  apt-get install -y git curl ca-certificates gnupg unzip

  # Node.js ${NODE_VERSION} from NodeSource
  install -d /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_VERSION}.x nodistro main' \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update -qq
  apt-get install -y nodejs
"

# Verify Node.js
NODE_VER="$(pct exec "$CT_ID" -- node --version 2>/dev/null || echo "unknown")"
echo "  Node.js installed: $NODE_VER"

# ── Deploy CryptPad ─────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  install -d -m 0755 /opt/cryptpad
  curl -fsSL -L "https://api.github.com/repos/cryptpad/cryptpad/tarball" \
    | tar -xz --strip-components=1 -C /opt/cryptpad
  [[ -f /opt/cryptpad/server.js ]] || { echo "ERROR: CryptPad download failed." >&2; exit 1; }
'
echo "  CryptPad source deployed to /opt/cryptpad"

# ── Build CryptPad ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cd /opt/cryptpad
  npm ci
  npm run install:components
'
echo "  npm dependencies installed"

if [[ "$INSTALL_ONLYOFFICE" -eq 1 ]]; then
  echo "  Installing OnlyOffice components (this may take a while)..."
  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    cd /opt/cryptpad
    bash -c "./install-onlyoffice.sh --accept-license"
  '
  echo "  OnlyOffice components installed"
fi

# ── Application configuration ───────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cd /opt/cryptpad

  # Create config from example
  cp config/config.example.js config/config.js

  # Set httpUnsafeOrigin to this container's IP
  sed -i \"s|httpUnsafeOrigin: '.*'|httpUnsafeOrigin: 'http://${CT_IP}:${APP_PORT}'|\" config/config.js

  # Bind to all interfaces
  sed -i \"s|//httpAddress: 'localhost'|httpAddress: '0.0.0.0'|\" config/config.js

  # Backup directory
  install -d -m 0755 /opt/cryptpad-backups

  # Build
  npm run build
"
echo "  CryptPad configured and built"

# ── Systemd service ─────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/cryptpad.service <<EOF
[Unit]
Description=CryptPad Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/cryptpad
ExecStart=/usr/bin/node server
Environment="PWD=/opt/cryptpad"
StandardOutput=journal
StandardError=journal
LimitNOFILE=1000000
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now cryptpad
'

# ── Verification ─────────────────────────────────────────────────────────────
sleep 3
if pct exec "$CT_ID" -- systemctl is-active --quiet cryptpad 2>/dev/null; then
  echo "  CryptPad service is running"
else
  echo "  WARNING: CryptPad may not be running — check: pct exec $CT_ID -- journalctl -u cryptpad --no-pager -n 20" >&2
fi

# HTTP health check (CryptPad takes a moment to start)
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
  echo "  CryptPad HTTP health check passed (HTTP $HTTP_CODE)"
else
  echo "  WARNING: CryptPad not responding on port ${APP_PORT} yet — may still be initializing" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u cryptpad --no-pager -n 40" >&2
fi

# ── Deploy maintenance script ───────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/cryptpad-maint.sh <<'\''MAINT'\''
#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
APP_DIR="${APP_DIR:-/opt/cryptpad}"
BACKUP_DIR="${BACKUP_DIR:-/opt/cryptpad-backups}"
SERVICE="cryptpad"

# ── Helpers ───────────────────────────────────────────────────────────────────
need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
  CryptPad Maintenance
  ──────────────────────
  Usage:
    $0 update            Download latest + preserve config/data
    $0 backup            Create timestamped backup
    $0 list-backups      Show available backups
    $0 restore <file>    Restore from backup archive
    $0 restore-latest    Restore most recent backup

  Env overrides:
    APP_DIR=$APP_DIR
    BACKUP_DIR=$BACKUP_DIR
EOF
}

latest_backup() {
  ls -1t "$BACKUP_DIR"/cryptpad-*.tgz 2>/dev/null | head -n 1 || true
}

do_backup() {
  mkdir -p "$BACKUP_DIR"
  [[ -d "$APP_DIR" ]] || die "APP_DIR not found: $APP_DIR"

  local ts backup
  ts="$(date +%Y%m%d-%H%M%S)"
  backup="$BACKUP_DIR/cryptpad-${ts}.tgz"

  echo "  Creating backup: $backup"
  tar -C "$(dirname "$APP_DIR")" -czf "$backup" "$(basename "$APP_DIR")"
  echo "  OK: $backup"
}

do_list_backups() {
  mkdir -p "$BACKUP_DIR"
  ls -lh "$BACKUP_DIR"/cryptpad-*.tgz 2>/dev/null || echo "  No backups in $BACKUP_DIR"
}

do_restore() {
  local tgz="${1:-}"
  [[ -n "$tgz" ]] || die "Missing backup file. Use: restore <backup.tgz>"
  [[ -f "$tgz" ]] || die "Backup not found: $tgz"

  local base
  base="$(basename "$APP_DIR")"
  if ! tar -tzf "$tgz" | head -n 1 | grep -q "^${base}/"; then
    die "Backup does not contain '${base}/' at top-level: $tgz"
  fi

  echo "  Restoring from: $tgz"
  systemctl stop "$SERVICE" || true

  if [[ -d "$APP_DIR" ]]; then
    local keep="${APP_DIR}.pre-restore.$(date +%Y%m%d-%H%M%S)"
    echo "  Keeping current as: $keep"
    mv "$APP_DIR" "$keep"
  fi

  tar -C "$(dirname "$APP_DIR")" -xzf "$tgz"

  systemctl start "$SERVICE"
  echo "  OK: Restored to $APP_DIR"
}

do_update() {
  [[ -d "$APP_DIR" ]] || die "APP_DIR not found: $APP_DIR"
  [[ -f "$APP_DIR/server.js" ]] || die "Not a CryptPad install: $APP_DIR/server.js missing"

  local ts work new_dir old_dir
  ts="$(date +%Y%m%d-%H%M%S)"
  work="$(mktemp -d /tmp/cryptpad-update.XXXXXX)"
  new_dir="$work/new"
  old_dir="$work/old"

  rollback() {
    echo "  !! Rolling back..."
    if [[ -d "$old_dir" ]]; then
      rm -rf "$APP_DIR"
      mv "$old_dir" "$APP_DIR"
      systemctl restart "$SERVICE" || true
    fi
  }
  trap 'rollback' ERR

  do_backup

  mkdir -p "$new_dir"

  echo "  Downloading latest CryptPad ..."
  curl -fsSL -L "https://api.github.com/repos/cryptpad/cryptpad/tarball" \
    | tar -xz --strip-components=1 -C "$new_dir"
  [[ -f "$new_dir/server.js" ]] || die "Downloaded bundle invalid (server.js missing)"

  echo "  Preserving config + data"
  local config_tmp="$work/config.js"
  local data_tmp="$work/data"
  local customize_tmp="$work/customize"
  if [[ -f "$APP_DIR/config/config.js" ]]; then cp -a "$APP_DIR/config/config.js" "$config_tmp"; fi
  if [[ -d "$APP_DIR/data" ]]; then cp -a "$APP_DIR/data" "$data_tmp"; fi
  if [[ -d "$APP_DIR/customize" ]]; then cp -a "$APP_DIR/customize" "$customize_tmp"; fi

  echo "  Stopping service"
  systemctl stop "$SERVICE"

  echo "  Swapping directories"
  mv "$APP_DIR" "$old_dir"
  mv "$new_dir" "$APP_DIR"

  echo "  Restoring config + data"
  mkdir -p "$APP_DIR/config" "$APP_DIR/data"
  if [[ -f "$config_tmp" ]]; then
    cp -a "$config_tmp" "$APP_DIR/config/config.js"
  else
    [[ -f "$APP_DIR/config/config.example.js" ]] && cp -a "$APP_DIR/config/config.example.js" "$APP_DIR/config/config.js" || true
  fi
  if [[ -d "$data_tmp" ]]; then
    rm -rf "$APP_DIR/data"
    cp -a "$data_tmp" "$APP_DIR/data"
  fi
  if [[ -d "$customize_tmp" ]]; then
    rm -rf "$APP_DIR/customize" 2>/dev/null || true
    cp -a "$customize_tmp" "$APP_DIR/customize"
  fi

  echo "  Rebuilding ..."
  cd "$APP_DIR"
  npm ci
  npm run install:components
  if [[ -f "$APP_DIR/install-onlyoffice.sh" && -d "$old_dir/www/common/onlyoffice" ]]; then
    echo "  Re-installing OnlyOffice components ..."
    bash "$APP_DIR/install-onlyoffice.sh" --accept-license
  fi
  npm run build

  echo "  Starting service"
  systemctl start "$SERVICE"

  trap - ERR
  rm -rf "$work"

  echo "  OK: Updated CryptPad."
}

# ── Main ──────────────────────────────────────────────────────────────────────
need_root
cmd="${1:-}"
shift || true

case "$cmd" in
  update)          do_update ;;
  backup)          do_backup ;;
  list-backups)    do_list_backups ;;
  restore)         do_restore "${1:-}" ;;
  restore-latest)  b="$(latest_backup)"; [[ -n "$b" ]] || die "No backups found in $BACKUP_DIR"; do_restore "$b" ;;
  ""|-h|--help)    usage ;;
  *)               usage; die "Unknown command: $cmd" ;;
esac
MAINT
chmod +x /usr/local/bin/cryptpad-maint.sh'

echo "  Maintenance script deployed: /usr/local/bin/cryptpad-maint.sh"

# ── Auto-update timer ───────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail

  cat > /etc/systemd/system/cryptpad-update.service <<EOF
[Unit]
Description=CryptPad auto-update (backup + download + rebuild)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cryptpad-maint.sh update
StandardOutput=journal
StandardError=journal
EOF

  cat > /etc/systemd/system/cryptpad-update.timer <<EOF
[Unit]
Description=CryptPad biweekly auto-update

[Timer]
OnCalendar=*-*-01 04:30:00
OnCalendar=*-*-15 04:30:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now cryptpad-update.timer
'
echo "  Auto-update timer enabled (1st + 15th of each month)"

# ── Unattended upgrades ─────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y unattended-upgrades
  distro_codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  cat > /etc/apt/apt.conf.d/52unattended-cryptpad.conf <<EOF
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
EOF
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  systemctl enable --now unattended-upgrades
'

# ── Sysctl hardening ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/sysctl.d/99-hardening.conf <<EOF
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
EOF
  sysctl --system >/dev/null 2>&1 || true
'

# ── Cleanup packages ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y man-db manpages 2>/dev/null || true
  apt-get -y autoremove
  apt-get -y clean
'

# ── MOTD (dynamic drop-ins) ─────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  > /etc/motd
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
  rm -f /etc/update-motd.d/*

  cat > /etc/update-motd.d/00-header <<'MOTD'
#!/bin/sh
  printf '\\n'
  printf '  CryptPad\\n'
  printf '  ──────────────────────────────────────\\n'
MOTD

  cat > /etc/update-motd.d/10-sysinfo <<'MOTD'
#!/bin/sh
  hostname=\$(hostname)
  ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
  uptime_str=\$(uptime -p 2>/dev/null | sed 's/^up //' || echo 'n/a')
  disk=\$(df -h / 2>/dev/null | awk 'NR==2{printf \"%s / %s (%s)\", \$3, \$2, \$5}')
  printf '  Hostname:  %s\\n' \"\$hostname\"
  printf '  IP:        %s\\n' \"\$ip\"
  printf '  Uptime:    %s\\n' \"\$uptime_str\"
  printf '  Disk:      %s\\n' \"\$disk\"
MOTD

  cat > /etc/update-motd.d/30-app <<'MOTD'
#!/bin/sh
  node_ver=\$(node --version 2>/dev/null || echo 'n/a')
  service_active=\$(systemctl is-active cryptpad 2>/dev/null || echo 'unknown')
  printf '\\n'
  printf '  CryptPad:\\n'
  printf '    App dir:       /opt/cryptpad\\n'
  printf '    Node.js:       %s\\n' \"\$node_ver\"
  printf '    Service:       %s\\n' \"\$service_active\"
  timer_next=\$(systemctl list-timers cryptpad-update.timer --no-pager 2>/dev/null | awk 'NR==2{for(i=1;i<=NF;i++) if(\$i ~ /^[0-9]{4}-/) {printf \"%s %s\", \$i, \$(i+1); break}}' || echo 'n/a')
  printf '    Auto-update:   %s\\n' \"\${timer_next:-enabled}\"
  printf '    Web UI:        http://%s:${APP_PORT}/\\n' \"\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)\"
  printf '\\n'
  printf '  Maintenance:\\n'
  printf '    cryptpad-maint.sh update\\n'
  printf '    cryptpad-maint.sh backup\\n'
  printf '    cryptpad-maint.sh list-backups\\n'
  printf '    cryptpad-maint.sh restore <file>\\n'
  printf '    cryptpad-maint.sh restore-latest\\n'
MOTD

  cat > /etc/update-motd.d/99-footer <<'MOTD'
#!/bin/sh
  printf '  ──────────────────────────────────────\\n'
  printf '\\n'
MOTD

  chmod +x /etc/update-motd.d/*
"

# Set TERM for console
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Proxmox UI description ──────────────────────────────────────────────────
OO_NOTE=""
[[ "$INSTALL_ONLYOFFICE" -eq 1 ]] && OO_NOTE=" + OnlyOffice"
DESC="<a href='http://${CT_IP}:${APP_PORT}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>CryptPad Web UI</a>
<details><summary>Details</summary>CryptPad on Debian ${DEBIAN_VERSION} LXC
Node.js ${NODE_VERSION} (native)${OO_NOTE}
Maintenance: cryptpad-maint.sh
Created by cryptpad.sh</details>"
pct set "$CT_ID" --description "$DESC"

# ── Protection ───────────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "  CT: $CT_ID | IP: ${CT_IP} | Web UI: http://${CT_IP}:${APP_PORT}/ | Login: $([ -n "$PASSWORD" ] && echo 'password set' || echo 'auto-login')"
echo "  Maintenance: pct exec $CT_ID -- cryptpad-maint.sh {update|backup|restore|list-backups|restore-latest}"
echo ""

# ── Reboot ───────────────────────────────────────────────────────────────────
pct stop "$CT_ID"
sleep 2
pct start "$CT_ID"
echo "  Done."
