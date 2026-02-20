#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID="$(pvesh get /cluster/nextid)"
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
TAGS="docmost;podman;lxc"

# Images (pin here if you want)
DOCMOST_IMAGE="docker.io/docmost/docmost:latest"
POSTGRES_IMAGE="docker.io/library/postgres:18"
REDIS_IMAGE="docker.io/library/redis:8"
DEBIAN_VERSION=13

# Behavior
CLEANUP_ON_FAIL=1  # 1 = destroy CT on error, 0 = keep for debugging

# ── Custom configs created by this script ─────────────────────────────────────
#   /opt/docmost/docker-compose.yml
#   /opt/docmost/.env
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/systemd/system/container-getty@1.service.d/override.conf
#   /etc/systemd/system/docmost-stack.service
#   /etc/systemd/system/docmost-update.service
#   /etc/systemd/system/docmost-update.timer
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

# ── Preflight (root) ─────────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pvesh pveam pct pvesm; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

[[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }

# ── Discover available resources ──────────────────────────────────────────────
AVAIL_BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | sort | paste -sd', ' || echo "n/a")"
AVAIL_TMPL_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'vztmpl' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_CT_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content',''))))" 2>/dev/null || echo "n/a")"

# ── Show defaults & confirm ──────────────────────────────────────────────────
cat <<EOF

  Docmost-Podman LXC Creator — Configuration
  ────────────────────────────────────────
  CT ID:             $CT_ID
  Hostname:          $HN
  CPU:               $CPU core(s)
  RAM:               $RAM MiB
  Disk:              $DISK GB
  Bridge:            $BRIDGE ($AVAIL_BRIDGES)
  Template Storage:  $TEMPLATE_STORAGE ($AVAIL_TMPL_STORES)
  Container Storage: $CONTAINER_STORAGE ($AVAIL_CT_STORES)
  App Port:          $APP_PORT
  Debian Version:    $DEBIAN_VERSION
  Timezone:          $APP_TZ
  Tags:              $TAGS
  Docmost Image:     $DOCMOST_IMAGE
  Postgres Image:    $POSTGRES_IMAGE
  Redis Image:       $REDIS_IMAGE
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

# ── Preflight (environment) ──────────────────────────────────────────────────
pvesm status | awk -v s="$TEMPLATE_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Template storage not found: $TEMPLATE_STORAGE" >&2; exit 1; }

pvesm status | awk -v s="$CONTAINER_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Container storage not found: $CONTAINER_STORAGE" >&2; exit 1; }

ip link show "$BRIDGE" >/dev/null 2>&1 || { echo "  ERROR: Bridge not found: $BRIDGE" >&2; exit 1; }

# ── Root password ─────────────────────────────────────────────────────────────
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

# ── Template ─────────────────────────────────────────────────────────────────
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
  -features "nesting=1,keyctl=1,fuse=1"
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
  CT_IP="$(
    pct exec "$CT_ID" -- sh -lc '
      ip -4 -o addr show scope global 2>/dev/null | awk "{print \$4}" | cut -d/ -f1 | head -n1
    ' 2>/dev/null || true
  )"
  [[ -n "$CT_IP" ]] && break
  sleep 1
done
[[ -n "$CT_IP" ]] || { echo "  ERROR: No IPv4 address acquired via DHCP within timeout." >&2; exit 1; }

# ── Auto-login if no password ────────────────────────────────────────────────
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

# ── Configure locale ─────────────────────────────────────────────────────────
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

# ── Set timezone ─────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  ln -sf /usr/share/zoneinfo/${APP_TZ} /etc/localtime
  echo '${APP_TZ}' > /etc/timezone
"

# ── Install Podman ────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y podman podman-compose fuse-overlayfs curl ca-certificates iproute2 python3
'

# ── Configure storage driver ─────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  mkdir -p /etc/containers
  cat > /etc/containers/storage.conf <<EOF
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
EOF
  podman system reset --force 2>/dev/null || true
'

# ── Configure extended registries ────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  mkdir -p /etc/containers
  cat > /etc/containers/registries.conf <<EOF
unqualified-search-registries = [
  "docker.io",
  "quay.io",
  "ghcr.io",
  "registry.fedoraproject.org",
  "registry.access.redhat.com",
  "registry.redhat.io"
]
short-name-mode = "enforcing"
EOF
'

# ── Podman log rotation ──────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  mkdir -p /etc/containers
  cat > /etc/containers/containers.conf <<EOF
[containers]
log_size_max = 10485760
EOF
'

# ── Verify ────────────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- podman info >/dev/null 2>&1
pct exec "$CT_ID" -- podman --version
pct exec "$CT_ID" -- podman-compose --version

# ── Secrets ──────────────────────────────────────────────────────────────────
DB_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 63 || true)"
APP_SECRET="$(tr -dc 'a-f0-9' </dev/urandom | head -c 64 || true)"
[[ ${#DB_PASSWORD} -eq 63 && ${#APP_SECRET} -eq 64 ]] || { echo "  ERROR: Failed to generate secrets." >&2; exit 1; }

# ── Prepare persistent volumes (absolute paths) ─────────────────────────────
# Verified UIDs: postgres:18(debian)=999, redis:8(debian)=999, docmost=node(1000) (2025-02)
echo "  Preparing persistent volumes with correct UIDs..."
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  mkdir -p /opt/docmost/postgresdata /opt/docmost/redis /opt/docmost/storage

  chown -R 999:999 /opt/docmost/postgresdata
  chmod 700 /opt/docmost/postgresdata

  chown -R 999:999 /opt/docmost/redis

  chown -R 1000:1000 /opt/docmost/storage

  echo "  ✅ Volumes pre-created (postgres=999, redis=999, docmost=1000)"
'

# ── Compose file ─────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc 'cat > /opt/docmost/docker-compose.yml <<YAML
networks:
  docmost:
    driver: bridge

services:

  db:
    image: __POSTGRES_IMAGE__
    container_name: docmost_db
    restart: unless-stopped
    networks:
      - docmost
    environment:
      - POSTGRES_DB=docmost
      - POSTGRES_USER=docmost
      - POSTGRES_PASSWORD=__DB_PASSWORD__
      - TZ=__TZ__
    volumes:
      - /opt/docmost/postgresdata:/var/lib/postgresql:Z
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U docmost -d docmost"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

  redis:
    image: __REDIS_IMAGE__
    container_name: docmost_redis
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes", "--maxmemory-policy", "noeviction"]
    networks:
      - docmost
    volumes:
      - /opt/docmost/redis:/data:Z
    environment:
      - TZ=__TZ__
    healthcheck:
      test: ["CMD-SHELL", "redis-cli ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

  docmost:
    image: __DOCMOST_IMAGE__
    container_name: docmost
    restart: unless-stopped
    networks:
      - docmost
    ports:
      - "__APP_PORT__:3000"
    environment:
      - APP_URL=http://__CT_IP__:__APP_PORT__
      - APP_SECRET=__APP_SECRET__
      - DATABASE_URL=postgresql://docmost:__DB_PASSWORD__@db:5432/docmost
      - REDIS_URL=redis://redis:6379
      - TZ=__TZ__
    volumes:
      - /opt/docmost/storage:/app/data/storage:Z
    depends_on:
      - db
      - redis
YAML
'

pct exec "$CT_ID" -- sed -i \
  -e "s|__DOCMOST_IMAGE__|${DOCMOST_IMAGE}|g" \
  -e "s|__POSTGRES_IMAGE__|${POSTGRES_IMAGE}|g" \
  -e "s|__REDIS_IMAGE__|${REDIS_IMAGE}|g" \
  -e "s|__APP_PORT__|${APP_PORT}|g" \
  -e "s|__CT_IP__|${CT_IP}|g" \
  -e "s|__TZ__|${APP_TZ}|g" \
  -e "s|__DB_PASSWORD__|${DB_PASSWORD}|g" \
  -e "s|__APP_SECRET__|${APP_SECRET}|g" \
  /opt/docmost/docker-compose.yml

pct exec "$CT_ID" -- chmod 600 /opt/docmost/docker-compose.yml

# ── .env (reference only) ────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > /opt/docmost/.env <<EOF
# Reference only — values are baked into docker-compose.yml at creation time.
# To change, edit docker-compose.yml directly and run: podman-compose up -d
COMPOSE_PROJECT_NAME=docmost
APP_TZ=${APP_TZ}
APP_PORT=${APP_PORT}
APP_URL=http://${CT_IP}:${APP_PORT}
EOF
  chmod 600 /opt/docmost/.env
"

# ── Auto-update timer ────────────────────────────────────────────────────────
# Docmost official upgrade: pull latest image, then force-recreate only docmost
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/docmost-update.service <<EOF
[Unit]
Description=Pull and update Docmost Podman containers
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=/opt/docmost
ExecStart=/bin/bash -c "/usr/bin/podman-compose pull docmost && /usr/bin/podman-compose up -d --force-recreate docmost"
EOF

  cat > /etc/systemd/system/docmost-update.timer <<EOF
[Unit]
Description=Auto-update Docmost containers biweekly

[Timer]
OnCalendar=*-*-01 05:30:00
OnCalendar=*-*-15 05:30:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now docmost-update.timer
'

# ── Pull container images ────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc 'cd /opt/docmost && podman-compose pull'

# ── Auto-start on LXC boot (and start now) ───────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/docmost-stack.service <<EOF
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
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now docmost-stack.service
'

# Wait until all containers are running (3: postgres, redis, docmost)
for i in $(seq 1 90); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc 'podman ps --format "{{.Names}}" 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge 3 ]] && break
  sleep 2
done
pct exec "$CT_ID" -- bash -lc 'cd /opt/docmost && podman-compose ps'

# Health check — verify Docmost is responding
DOCMOST_HEALTHY=0
for i in $(seq 1 30); do
  if pct exec "$CT_ID" -- curl -sf -o /dev/null --max-time 3 "http://127.0.0.1:${APP_PORT}/api/health"; then
    DOCMOST_HEALTHY=1
    break
  fi
  sleep 2
done

if [[ "$DOCMOST_HEALTHY" -eq 1 ]]; then
  echo "  Docmost is responding"
else
  echo "  WARNING: Docmost not responding yet — containers may still be initializing." >&2
  echo "  Check manually: pct enter $CT_ID -> curl -sf http://127.0.0.1:${APP_PORT}/api/health" >&2
  pct exec "$CT_ID" -- bash -lc 'cd /opt/docmost && podman-compose logs --tail=80' >&2 || true
fi

# ── Unattended upgrades (do NOT overwrite Debian defaults) ───────────────────
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
Unattended-Upgrade::Package-Blacklist {
};
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
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  sysctl --system >/dev/null 2>&1 || true
'

# ── Cleanup unnecessary packages ─────────────────────────────────────────────
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
printf '\n  Docmost (Podman)\n'
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
printf '  Stack:     /opt/docmost (%s containers running)\n' \"\$running\"
printf '  Compose:   cd /opt/docmost && podman-compose [up -d|down|logs|ps]\n'
printf '  Updates:   systemctl status docmost-update.timer\n'
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '  Web UI:    http://%s:${APP_PORT}\n' \"\${ip:-n/a}\"
printf '  Health:    http://%s:${APP_PORT}/api/health\n' \"\${ip:-n/a}\"
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

# ── Proxmox UI description ───────────────────────────────────────────────────
DOCMOST_DESC="<a href='http://${CT_IP}:${APP_PORT}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Docmost Web UI</a>
<details><summary>Details</summary>Docmost (Podman) on Debian ${DEBIAN_VERSION} LXC
Created by docmost-lxc-podman.sh</details>"
pct set "$CT_ID" --description "$DOCMOST_DESC"

# ── Protect container ────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ──────────────────────────────────────────────────────────────────
cat <<EOF

  CT: $CT_ID | IP: ${CT_IP} | Web UI: http://${CT_IP}:${APP_PORT} | Login: $([ -n "$PASSWORD" ] && echo 'password set' || echo 'auto-login')

  Open http://${CT_IP}:${APP_PORT} in your browser to complete
  the initial workspace setup (create owner account).

  Reverse proxy (NPM):
    docmost.example.com -> http://${CT_IP}:${APP_PORT}
      SSL tab: enable SSL, Force SSL
      Enable "Websockets Support" toggle
      (required for real-time collaborative editor)

    After setting up the reverse proxy, update APP_URL:
      pct enter $CT_ID
      cd /opt/docmost
      sed -i 's|APP_URL=http://.*|APP_URL=https://docmost.example.com|' docker-compose.yml
      podman-compose up -d --force-recreate docmost

EOF

# ── Reboot CT so all settings take effect cleanly ────────────────────────────
echo "  Rebooting container..."
pct reboot "$CT_ID"

# Wait for stack to come back (3 containers: postgres, redis, docmost)
RUNNING=0
for i in $(seq 1 90); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc 'podman ps --format "{{.Names}}" 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge 3 ]] && break
  sleep 2
done
[[ "$RUNNING" -ge 3 ]] && echo "  Stack came up after reboot" \
  || echo "  WARNING: Stack not fully up after reboot — check docmost-stack.service" >&2

echo "  Done."
echo ""
