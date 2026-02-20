#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID="$(pvesh get /cluster/nextid)"
HN="docmost"
CPU=3
RAM=4096
DISK=8
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Application-specific
APP_PORT=3000
APP_TZ="Europe/Berlin"
TAGS="docmost;lxc"

NODE_VERSION=22
PG_VERSION=16
DEBIAN_VERSION=13

# Behavior
CLEANUP_ON_FAIL=1  # 1 = destroy CT on error, 0 = keep for debugging

# ── Custom configs created by this script ─────────────────────────────────────
#   /opt/docmost/                              (application root)
#   /opt/docmost/.env                          (application config)
#   /opt/docmost/data/                         (file uploads)
#   /etc/systemd/system/docmost.service        (systemd unit)
#   /usr/local/bin/docmost-maint.sh            (maintenance script)
#   /etc/systemd/system/docmost-update.service
#   /etc/systemd/system/docmost-update.timer
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/systemd/system/container-getty@1.service.d/override.conf
#   /etc/apt/apt.conf.d/52unattended-docmost.conf
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

# ── Show defaults & confirm ───────────────────────────────────────────────────
TMPL_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'vztmpl' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
CT_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | paste -sd', ' || echo "n/a")"

cat <<EOF

  Docmost LXC Creator — Configuration
  ────────────────────────────────────────
  CT ID:             $CT_ID
  Hostname:          $HN
  CPU cores:         $CPU
  RAM (MB):          $RAM
  Disk (GB):         $DISK
  Bridge:            $BRIDGE ($BRIDGES)
  Template storage:  $TEMPLATE_STORAGE ($TMPL_STORES)
  Container storage: $CONTAINER_STORAGE ($CT_STORES)
  Node.js:           $NODE_VERSION
  PostgreSQL:        $PG_VERSION
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

# ── Preflight — environment ───────────────────────────────────────────────────
pvesm status | awk -v s="$TEMPLATE_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Template storage not found: $TEMPLATE_STORAGE" >&2; exit 1; }
pvesm status | awk -v s="$CONTAINER_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Container storage not found: $CONTAINER_STORAGE" >&2; exit 1; }
ip link show "$BRIDGE" >/dev/null 2>&1 \
  || { echo "  ERROR: Bridge not found: $BRIDGE" >&2; exit 1; }

# ── Root password prompt ──────────────────────────────────────────────────────
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

# ── Template discovery & download ─────────────────────────────────────────────
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

# ── Start & wait for IPv4 ────────────────────────────────────────────────────
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

# ── Auto-login (if no password) ──────────────────────────────────────────────
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
  apt-get -y clean
'

# ── Locale ────────────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y locales
  sed -i "s/^# *en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
'

# ── Remove unnecessary services ──────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  systemctl disable --now ssh 2>/dev/null || true
  systemctl disable --now postfix 2>/dev/null || true
  apt-get purge -y openssh-server postfix 2>/dev/null || true
  apt-get -y autoremove
'

# ── Timezone ──────────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  ln -sf /usr/share/zoneinfo/${APP_TZ} /etc/localtime
  echo '${APP_TZ}' > /etc/timezone
"

# ── Application install ──────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive

  # Base packages
  apt-get update -qq
  apt-get install -y curl tar ca-certificates gnupg openssl jq make

  # Redis 8 from official repo
  install -d /etc/apt/keyrings
  curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /etc/apt/keyrings/redis.gpg
  echo \"deb [signed-by=/etc/apt/keyrings/redis.gpg] https://packages.redis.io/deb \$(awk -F= '/^VERSION_CODENAME=/{print \$2}' /etc/os-release) main\" \
    > /etc/apt/sources.list.d/redis.list
  apt-get update -qq
  apt-get install -y redis
  systemctl enable --now redis-server
  echo \"  Redis: \$(redis-server --version)\"

  # Node.js ${NODE_VERSION}
  install -d /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_VERSION}.x nodistro main' \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update -qq
  apt-get install -y nodejs

  # pnpm — fetch version from upstream package.json
  PNPM_VER=\$(curl -fsSL https://raw.githubusercontent.com/docmost/docmost/main/package.json \
    | jq -r '.packageManager | split(\"@\")[1]')
  npm install -g \"pnpm@\${PNPM_VER}\"
  echo \"  Node: \$(node -v) | pnpm: \$(pnpm -v)\"

  # PostgreSQL ${PG_VERSION}
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /etc/apt/keyrings/postgresql.gpg
  echo \"deb [signed-by=/etc/apt/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt \$(awk -F= '/^VERSION_CODENAME=/{print \$2}' /etc/os-release)-pgdg main\" \
    > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
  apt-get install -y postgresql-${PG_VERSION}
"

# ── Application configuration ────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail

  # Create database and user
  PG_DB_PASS=\"\$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | cut -c1-24)\"
  su - postgres -c \"psql -c \\\"CREATE USER docmost_user WITH PASSWORD '\${PG_DB_PASS}';\\\"\"
  su - postgres -c \"psql -c \\\"CREATE DATABASE docmost_db OWNER docmost_user;\\\"\"

  # Deploy Docmost from latest GitHub release
  install -d -m 0755 /opt/docmost
  LATEST_TAG=\$(curl -fsSL https://api.github.com/repos/docmost/docmost/releases/latest | jq -r '.tag_name')
  curl -fsSL -L \"https://github.com/docmost/docmost/archive/refs/tags/\${LATEST_TAG}.tar.gz\" \
    | tar -xz --strip-components=1 -C /opt/docmost
  [[ -f /opt/docmost/package.json ]] || { echo 'ERROR: Docmost download failed.' >&2; exit 1; }

  # Data directory
  install -d -m 0755 /opt/docmost/data

  # Environment file
  APP_SECRET=\"\$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | cut -c1-32)\"
  cat > /opt/docmost/.env <<ENVFILE
APP_URL=http://${CT_IP}:${APP_PORT}
APP_SECRET=\${APP_SECRET}
DATABASE_URL=postgres://docmost_user:\${PG_DB_PASS}@localhost:5432/docmost_db?schema=public
REDIS_URL=redis://localhost:6379
FILE_UPLOAD_SIZE_LIMIT=50mb
DRAWIO_URL=https://embed.diagrams.net
DISABLE_TELEMETRY=true
PORT=${APP_PORT}
ENVFILE
  chmod 600 /opt/docmost/.env

  # Build
  cd /opt/docmost
  export NODE_OPTIONS='--max_old_space_size=4096'
  pnpm install
  pnpm build
"

# ── Verification ──────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  [[ -f /opt/docmost/.env ]] || { echo "ERROR: .env missing" >&2; exit 1; }
  node --version
  pnpm --version
  su - postgres -c "psql -c \"SELECT 1 FROM pg_database WHERE datname = '\''docmost_db'\''\"" | grep -q 1
'
echo "  Docmost build verified"

# ── Systemd service ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail

  cat > /etc/systemd/system/docmost.service <<EOF
[Unit]
Description=Docmost Service
After=network.target postgresql.service redis-server.service

[Service]
WorkingDirectory=/opt/docmost
ExecStart=/usr/bin/pnpm start
Restart=always
EnvironmentFile=/opt/docmost/.env

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now docmost
'

# Health check
sleep 5
if pct exec "$CT_ID" -- systemctl is-active --quiet docmost 2>/dev/null; then
  echo "  Docmost is running"
else
  echo "  WARNING: Docmost may not be running — check: pct exec $CT_ID -- journalctl -u docmost --no-pager -n 30" >&2
fi

# ── Deploy maintenance script ────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/docmost-maint.sh <<'\''MAINT'\''
#!/usr/bin/env bash
set -Eeo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

# ── Config ────────────────────────────────────────────────────────────────────
APP_DIR="${APP_DIR:-/opt/docmost}"
SERVICE="docmost"

# ── Helpers ───────────────────────────────────────────────────────────────────
need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
  Docmost Maintenance
  ──────────────────────
  Usage:
    $0 update       Download latest release + rebuild

  Backups: Use Proxmox vzdump / PBS.
EOF
}

do_update() {
  [[ -d "$APP_DIR" ]] || die "APP_DIR not found: $APP_DIR"
  [[ -f "$APP_DIR/package.json" ]] || die "Not a Docmost install: $APP_DIR/package.json missing"

  echo "  Downloading latest Docmost ..."
  LATEST_TAG=$(curl -fsSL https://api.github.com/repos/docmost/docmost/releases/latest | jq -r '.tag_name')
  [[ -n "$LATEST_TAG" && "$LATEST_TAG" != "null" ]] || die "Failed to fetch latest release tag"

  # Update pnpm to version expected by new release
  PNPM_VER=$(curl -fsSL https://raw.githubusercontent.com/docmost/docmost/main/package.json \
    | jq -r ".packageManager" | cut -d@ -f2)
  [[ -n "$PNPM_VER" && "$PNPM_VER" != "null" ]] && npm install -g "pnpm@${PNPM_VER}"

  echo "  Stopping service"
  systemctl stop "$SERVICE"

  echo "  Backing up config + data"
  cp "$APP_DIR/.env" /opt/
  cp -r "$APP_DIR/data" /opt/
  rm -rf "$APP_DIR"

  echo "  Deploying ${LATEST_TAG} ..."
  install -d -m 0755 "$APP_DIR"
  curl -fsSL -L "https://github.com/docmost/docmost/archive/refs/tags/${LATEST_TAG}.tar.gz" \
    | tar -xz --strip-components=1 -C "$APP_DIR"
  [[ -f "$APP_DIR/package.json" ]] || die "Downloaded bundle invalid (package.json missing)"

  mv /opt/.env "$APP_DIR/.env"
  mv /opt/data "$APP_DIR/data"

  echo "  Building ..."
  cd "$APP_DIR"
  export NODE_OPTIONS="--max_old_space_size=4096"
  pnpm install --force
  pnpm build

  echo "  Starting service"
  systemctl start "$SERVICE"

  # Health check
  sleep 5
  if ! systemctl is-active --quiet "$SERVICE"; then
    die "Service failed to start after update. Check: journalctl -u $SERVICE --no-pager -n 30"
  fi

  echo "  OK: Updated Docmost to ${LATEST_TAG}."
}

# ── Main ──────────────────────────────────────────────────────────────────────
need_root
cmd="${1:-}"
shift || true

case "$cmd" in
  update)          do_update ;;
  ""|-h|--help)    usage ;;
  *)               usage; die "Unknown command: $cmd" ;;
esac
MAINT
chmod +x /usr/local/bin/docmost-maint.sh'

echo "  Maintenance script deployed: /usr/local/bin/docmost-maint.sh"

# ── Auto-update timer ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail

  cat > /etc/systemd/system/docmost-update.service <<EOF
[Unit]
Description=Docmost auto-update (download + rebuild)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/local/bin/docmost-maint.sh update
StandardOutput=journal
StandardError=journal
EOF

  cat > /etc/systemd/system/docmost-update.timer <<EOF
[Unit]
Description=Docmost biweekly auto-update

[Timer]
OnCalendar=*-*-01 04:30:00
OnCalendar=*-*-15 04:30:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now docmost-update.timer
'
echo "  Auto-update timer enabled (1st + 15th of each month)"

# ── Unattended upgrades ──────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y unattended-upgrades
  distro_codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  cat > /etc/apt/apt.conf.d/52unattended-docmost.conf <<EOF
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

# ── Sysctl hardening ─────────────────────────────────────────────────────────
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

# ── Cleanup packages ─────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y man-db manpages 2>/dev/null || true
  apt-get -y autoremove
  apt-get -y clean
'

# ── MOTD (dynamic drop-ins) ──────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  > /etc/motd
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
  rm -f /etc/update-motd.d/*

  cat > /etc/update-motd.d/00-header <<'MOTD'
#!/bin/sh
  printf '\\n'
  printf '  Docmost\\n'
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
  node_ver=\$(node -v 2>/dev/null || echo 'n/a')
  docmost_active=\$(systemctl is-active docmost 2>/dev/null || echo 'unknown')
  pg_active=\$(systemctl is-active postgresql 2>/dev/null || echo 'unknown')
  redis_active=\$(systemctl is-active redis-server 2>/dev/null || echo 'unknown')
  printf '\\n'
  printf '  Docmost:\\n'
  printf '    App dir:       /opt/docmost\\n'
  printf '    Node.js:       %s\\n' \"\$node_ver\"
  printf '    Docmost:       %s\\n' \"\$docmost_active\"
  printf '    PostgreSQL:    %s\\n' \"\$pg_active\"
  printf '    Redis:         %s\\n' \"\$redis_active\"
  timer_next=\$(systemctl list-timers docmost-update.timer --no-pager 2>/dev/null | awk 'NR==2{for(i=1;i<=NF;i++) if(\$i ~ /^[0-9]{4}-/) {printf \"%s %s\", \$i, \$(i+1); break}}' || echo 'n/a')
  printf '    Auto-update:   %s\\n' \"\${timer_next:-enabled}\"
  printf '    Web UI:        http://%s:${APP_PORT}/\\n' \"\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)\"
  printf '\\n'
  printf '  Maintenance:\\n'
  printf '    docmost-maint.sh update\\n'
  printf '    Snapshot before manual update: pct snapshot <CT_ID> pre-update\\n'
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

# ── Proxmox UI description ───────────────────────────────────────────────────
DESC="<a href='http://${CT_IP}:${APP_PORT}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Docmost Web UI</a>
<details><summary>Details</summary>Docmost on Debian ${DEBIAN_VERSION} LXC
Node.js ${NODE_VERSION} + PostgreSQL ${PG_VERSION} + Redis 8 (native)
Maintenance: docmost-maint.sh
Created by docmost.sh</details>"
pct set "$CT_ID" --description "$DESC"

# ── Protection ────────────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  CT: $CT_ID | IP: ${CT_IP} | Web UI: http://${CT_IP}:${APP_PORT}/ | Login: $([ -n "$PASSWORD" ] && echo 'password set' || echo 'auto-login')"
echo "  Maintenance: pct exec $CT_ID -- docmost-maint.sh update"
echo ""

# ── Reboot ────────────────────────────────────────────────────────────────────
pct stop "$CT_ID"
sleep 2
pct start "$CT_ID"
echo "  Done."
