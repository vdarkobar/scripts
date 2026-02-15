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

# NPM / Podman
NPM_ADMIN_PORT=49152
NPM_TZ="Europe/Berlin"
TAGS="npm;podman;lxc"

# Images (pin here if you want)
NPM_IMAGE="docker.io/jc21/nginx-proxy-manager:latest"
DB_IMAGE="docker.io/jc21/mariadb-aria:latest"
DEBIAN_VERSION=13

# Behavior
CLEANUP_ON_FAIL=1  # 1 = destroy CT on error, 0 = keep for debugging

# ── Trap cleanup (no functions) ───────────────────────────────────────────────
CREATED=0
trap 'trap - ERR; rc=$?;
  echo "  ERROR: failed (rc=$rc) near line ${BASH_LINENO[0]:-?}" >&2
  if [[ "${CLEANUP_ON_FAIL:-0}" -eq 1 && "${CREATED:-0}" -eq 1 ]]; then
    echo "  Cleanup: stopping/destroying CT ${CT_ID} ..." >&2
    pct stop "${CT_ID}" >/dev/null 2>&1 || true
    pct destroy "${CT_ID}" >/dev/null 2>&1 || true
  fi
  exit "$rc"
' ERR

# ── Preflight (root) ──────────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pvesh pveam pct pvesm; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

[[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }

# ── Show defaults & confirm ───────────────────────────────────────────────────
cat <<EOF

  NPM-Podman LXC Creator — Configuration
  ────────────────────────────────────────
  CT ID:             $CT_ID
  Hostname:          $HN
  CPU:               $CPU core(s)
  RAM:               $RAM MiB
  Disk:              $DISK GB
  Bridge:            $BRIDGE
  Template Storage:  $TEMPLATE_STORAGE
  Container Storage: $CONTAINER_STORAGE
  NPM Admin Port:    $NPM_ADMIN_PORT
  Debian Version:    $DEBIAN_VERSION
  Timezone:          $NPM_TZ
  Tags:              $TAGS
  NPM Image:         $NPM_IMAGE
  DB Image:          $DB_IMAGE
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

# ── Preflight (environment) ───────────────────────────────────────────────────
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

# ── Template ──────────────────────────────────────────────────────────────────
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

# ── Start & wait for IPv4 ─────────────────────────────────────────────────────
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

# ── Auto-login if no password ─────────────────────────────────────────────────
if [[ -z "$PASSWORD" ]]; then
  pct exec "$CT_ID" -- bash -lc '
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
  export DEBIAN_FRONTEND=noninteractive
  export LANG=C.UTF-8
  export LC_ALL=C.UTF-8
  systemctl disable -q --now systemd-networkd-wait-online.service 2>/dev/null || true
  apt-get update -qq
  apt-get -o Dpkg::Options::="--force-confold" -y dist-upgrade
  apt-get -y autoremove
  apt-get -y clean
'

# ── Configure locale ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y locales
  sed -i "s/^# *en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
'

# ── Remove unnecessary services ───────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  export DEBIAN_FRONTEND=noninteractive
  systemctl disable --now ssh 2>/dev/null || true
  systemctl disable --now postfix 2>/dev/null || true
  apt-get purge -y openssh-server postfix 2>/dev/null || true
  apt-get -y autoremove
'

# ── Set timezone ──────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  ln -sf /usr/share/zoneinfo/${NPM_TZ} /etc/localtime
  echo '${NPM_TZ}' > /etc/timezone
"

# ── Install Podman ────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y podman podman-compose fuse-overlayfs curl ca-certificates iproute2
'

# ── Configure storage driver ──────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
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

# ── Configure extended registries ─────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
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

# ── Podman log rotation ───────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
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

# ── Secrets (ensure enough entropy after filtering) ───────────────────────────
set +o pipefail
DB_ROOT_PWD="$(head -c 4096 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 35)"
MYSQL_PWD="$(head -c 4096 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 35)"
set -o pipefail
[[ ${#DB_ROOT_PWD} -eq 35 && ${#MYSQL_PWD} -eq 35 ]] || { echo "  ERROR: Failed to generate secrets." >&2; exit 1; }

pct exec "$CT_ID" -- bash -lc "
  umask 077
  mkdir -p /opt/npm/.secrets /opt/npm/data /opt/npm/letsencrypt /opt/npm/mysql
  chmod 700 /opt/npm/.secrets
  printf '%s' '${DB_ROOT_PWD}' > /opt/npm/.secrets/db_root_pwd.secret
  printf '%s' '${MYSQL_PWD}' > /opt/npm/.secrets/mysql_pwd.secret
  chmod 600 /opt/npm/.secrets/*.secret
"

# ── Compose file ──────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc 'cat > /opt/npm/docker-compose.yml <<YAML
networks:
  npm:
    driver: bridge

services:
  app:
    image: __NPM_IMAGE__
    restart: unless-stopped
    networks:
      - npm
    ports:
      - "80:80"
      - "__ADMIN_PORT__:81"
      - "443:443"
    environment:
      - TZ=__TZ__
      - DB_MYSQL_HOST=db
      - DB_MYSQL_PORT=3306
      - DB_MYSQL_USER=npm_user
      - DB_MYSQL_PASSWORD__FILE=/run/secrets/mysql_pwd
      - DB_MYSQL_NAME=npm_db
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
      - ./.secrets/mysql_pwd.secret:/run/secrets/mysql_pwd:ro
    depends_on:
      db:
        condition: service_healthy

  db:
    image: __DB_IMAGE__
    restart: unless-stopped
    networks:
      - npm
    environment:
      - TZ=__TZ__
      - MYSQL_ROOT_PASSWORD__FILE=/run/secrets/db_root_pwd
      - MYSQL_DATABASE=npm_db
      - MYSQL_USER=npm_user
      - MYSQL_PASSWORD__FILE=/run/secrets/mysql_pwd
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "--silent"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
    volumes:
      - ./mysql:/var/lib/mysql
      - ./.secrets/db_root_pwd.secret:/run/secrets/db_root_pwd:ro
      - ./.secrets/mysql_pwd.secret:/run/secrets/mysql_pwd:ro
YAML
'

pct exec "$CT_ID" -- sed -i \
  -e "s|__ADMIN_PORT__|${NPM_ADMIN_PORT}|g" \
  -e "s|__TZ__|${NPM_TZ}|g" \
  -e "s|__NPM_IMAGE__|${NPM_IMAGE}|g" \
  -e "s|__DB_IMAGE__|${DB_IMAGE}|g" \
  /opt/npm/docker-compose.yml

# ── .env (reference only — values are baked into compose via sed) ─────────────
pct exec "$CT_ID" -- bash -lc "
  cat > /opt/npm/.env <<EOF
# Reference only — these values are baked into docker-compose.yml at creation time.
# To change ports/TZ, edit docker-compose.yml directly and run: podman-compose up -d
COMPOSE_PROJECT_NAME=npm
NPM_TZ=${NPM_TZ}
NPM_ADMIN_PORT=${NPM_ADMIN_PORT}
EOF
  chmod 600 /opt/npm/.env
"

# ── Auto-update timer ─────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  cat > /etc/systemd/system/npm-update.service <<EOF
[Unit]
Description=Pull and update NPM Podman containers
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=/opt/npm
ExecStart=/bin/bash -c "/usr/bin/podman-compose pull && /usr/bin/podman-compose up -d"
EOF

  cat > /etc/systemd/system/npm-update.timer <<EOF
[Unit]
Description=Auto-update NPM containers biweekly

[Timer]
OnCalendar=*-*-01 05:30:00
OnCalendar=*-*-15 05:30:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now npm-update.timer
'

# ── Pull container images ─────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc 'cd /opt/npm && podman-compose pull'

# ── Auto-start on LXC boot (and start now) ────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  cat > /etc/systemd/system/npm-stack.service <<EOF
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
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now npm-stack.service
'

# Wait until both containers are running
for i in $(seq 1 60); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc 'podman ps --format "{{.Names}}" 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge 2 ]] && break
  sleep 1
done
pct exec "$CT_ID" -- bash -lc 'cd /opt/npm && podman-compose ps'

# Health check — verify NPM admin is responding on the published port
NPM_HEALTHY=0
for i in $(seq 1 30); do
  if pct exec "$CT_ID" -- curl -sf -o /dev/null --max-time 3 "http://127.0.0.1:${NPM_ADMIN_PORT}/"; then
    NPM_HEALTHY=1
    break
  fi
  sleep 2
done

if [[ "$NPM_HEALTHY" -eq 1 ]]; then
  echo "  NPM admin interface is responding"
else
  echo "  WARNING: NPM admin not responding yet — containers are running but app may still be initializing." >&2
  echo "  Check manually: pct enter $CT_ID -> curl -sf http://127.0.0.1:${NPM_ADMIN_PORT}/" >&2
  pct exec "$CT_ID" -- bash -lc 'cd /opt/npm && podman-compose logs --tail=80' >&2 || true
fi

# ── Unattended upgrades (do NOT overwrite Debian defaults) ────────────────────
pct exec "$CT_ID" -- bash -lc '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y unattended-upgrades

  distro_codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

  cat > /etc/apt/apt.conf.d/52unattended-npm.conf <<EOF
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security";
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

# ── Sysctl hardening ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
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

# ── Cleanup unnecessary packages ──────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y man-db manpages 2>/dev/null || true
  apt-get -y autoremove
  apt-get -y clean
'

# ── MOTD ──────────────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  cat > /etc/motd <<EOF

  Nginx Proxy Manager (Podman)
  ────────────────────────────
  Stack:    /opt/npm
  Compose:  cd /opt/npm && podman-compose [up -d|down|logs|ps]
  Updates:  systemctl status npm-update.timer

EOF
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
'

pct exec "$CT_ID" -- bash -lc '
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Proxmox UI description ────────────────────────────────────────────────────
NPM_DESC="<a href='http://${CT_IP}:${NPM_ADMIN_PORT}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>NPM Admin</a>
<details><summary>Details</summary>Nginx Proxy Manager (Podman) on Debian 13 LXC
Created by npm-lxc-podman.sh</details>"
pct set "$CT_ID" --description "$NPM_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "CT: $CT_ID | IP: ${CT_IP} | Admin: http://${CT_IP}:${NPM_ADMIN_PORT} | Login: $([ -n "$PASSWORD" ] && echo 'password set' || echo 'auto-login')"
echo ""
