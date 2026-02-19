#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID="$(pvesh get /cluster/nextid)"
HN="privatebin"
CPU=1
RAM=512
DISK=4
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Application-specific
PHP_VERSION=8.4
APP_PORT=443
APP_TZ="Europe/Berlin"
TAGS="privatebin;lxc"

DEBIAN_VERSION=13

# Behavior
CLEANUP_ON_FAIL=1  # 1 = destroy CT on error, 0 = keep for debugging

# ── Custom configs created by this script ─────────────────────────────────────
#   /opt/privatebin/                         (application root)
#   /opt/privatebin/cfg/conf.php             (application config)
#   /opt/privatebin/data/                    (paste storage)
#   /opt/privatebin-backups/                 (backup directory)
#   /etc/ssl/privatebin/privatebin.crt       (self-signed TLS cert)
#   /etc/ssl/privatebin/privatebin.key       (TLS key)
#   /etc/nginx/sites-available/privatebin.conf
#   /etc/nginx/sites-enabled/privatebin.conf
#   /usr/local/bin/privatebin-maint.sh       (maintenance script)
#   /etc/systemd/system/privatebin-update.service
#   /etc/systemd/system/privatebin-update.timer
#   /etc/systemd/system/privatebin-purge.service
#   /etc/systemd/system/privatebin-purge.timer
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/systemd/system/container-getty@1.service.d/override.conf
#   /etc/apt/apt.conf.d/52unattended-privatebin.conf
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

  PrivateBin LXC Creator — Configuration
  ────────────────────────────────────────
  CT ID:             $CT_ID
  Hostname:          $HN
  CPU cores:         $CPU
  RAM (MB):          $RAM
  Disk (GB):         $DISK
  Bridge:            $BRIDGE ($BRIDGES)
  Template storage:  $TEMPLATE_STORAGE ($TMPL_STORES)
  Container storage: $CONTAINER_STORAGE ($CT_STORES)
  PHP version:       $PHP_VERSION
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
  apt-get install -y nginx openssl curl tar ca-certificates lsb-release

  # PHP — try Debian repos first, add Sury if needed
  if ! apt-cache show php${PHP_VERSION}-fpm >/dev/null 2>&1; then
    echo '  php${PHP_VERSION}-fpm not in repos, adding Sury...'
    apt-get install -y gnupg apt-transport-https
    install -d /etc/apt/keyrings
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/keyrings/sury-php.gpg
    echo \"deb [signed-by=/etc/apt/keyrings/sury-php.gpg] https://packages.sury.org/php/ \$(lsb_release -sc) main\" \
      >/etc/apt/sources.list.d/sury-php.list
    apt-get update -qq
  fi

  apt-get install -y \
    php${PHP_VERSION}-fpm \
    php${PHP_VERSION}-cli \
    php${PHP_VERSION}-mbstring \
    php${PHP_VERSION}-gd \
    php${PHP_VERSION}-xml
"

# ── Deploy PrivateBin ─────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  install -d -m 0755 /opt/privatebin
  curl -fsSL -L "https://api.github.com/repos/PrivateBin/PrivateBin/tarball" \
    | tar -xz --strip-components=1 -C /opt/privatebin
  [[ -f /opt/privatebin/index.php ]] || { echo "ERROR: PrivateBin download failed." >&2; exit 1; }
'

# ── Application configuration ────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail

  # Data directory
  install -d -m 0755 /opt/privatebin/data
  install -d -m 0755 /opt/privatebin-backups

  # Config
  cp -f /opt/privatebin/cfg/conf.sample.php /opt/privatebin/cfg/conf.php

  # Permissions
  chown -R www-data:www-data /opt/privatebin
  chmod -R 0755 /opt/privatebin/data

  # PHP hardening
  PHP_INI=\"/etc/php/${PHP_VERSION}/fpm/php.ini\"
  if [[ -f \"\$PHP_INI\" ]]; then
    sed -i 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/' \"\$PHP_INI\"
  fi
  systemctl restart php${PHP_VERSION}-fpm

  # TLS self-signed cert
  install -d -m 0755 /etc/ssl/privatebin
  if [[ ! -f /etc/ssl/privatebin/privatebin.crt ]]; then
    openssl req -x509 -nodes -newkey rsa:2048 \
      -keyout /etc/ssl/privatebin/privatebin.key \
      -out /etc/ssl/privatebin/privatebin.crt \
      -days 825 -subj '/CN=privatebin'
  fi
  chmod 600 /etc/ssl/privatebin/privatebin.key

  # Nginx vhost
  cat > /etc/nginx/sites-available/privatebin.conf <<'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    ssl_certificate     /etc/ssl/privatebin/privatebin.crt;
    ssl_certificate_key /etc/ssl/privatebin/privatebin.key;
    root /opt/privatebin;
    index index.php;
    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php__PHP_VERSION__-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
    location ~ /\.ht {
        deny all;
    }
    add_header Strict-Transport-Security \"max-age=63072000; includeSubdomains; preload\";
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options \"SAMEORIGIN\";
    add_header X-XSS-Protection \"1; mode=block\";
}
NGINX

  ln -sf /etc/nginx/sites-available/privatebin.conf /etc/nginx/sites-enabled/privatebin.conf
  rm -f /etc/nginx/sites-enabled/default
"

# Substitute PHP version in nginx config (safe — no user input)
pct exec "$CT_ID" -- sed -i \
  -e "s|__PHP_VERSION__|${PHP_VERSION}|g" \
  /etc/nginx/sites-available/privatebin.conf

# Patch PrivateBin config — enable traffic limiter
pct exec "$CT_ID" -- sed -i "s|// 'traffic'|'traffic'|g" /opt/privatebin/cfg/conf.php

# ── Verification ──────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  nginx -t
  systemctl reload nginx
'

# Health checks
if pct exec "$CT_ID" -- systemctl is-active --quiet nginx 2>/dev/null; then
  echo "  Nginx is running"
else
  echo "  WARNING: Nginx may not be running — check: pct exec $CT_ID -- journalctl -u nginx --no-pager -n 20" >&2
fi
if pct exec "$CT_ID" -- systemctl is-active --quiet "php${PHP_VERSION}-fpm" 2>/dev/null; then
  echo "  PHP-FPM is running"
else
  echo "  WARNING: PHP-FPM may not be running — check: pct exec $CT_ID -- journalctl -u php${PHP_VERSION}-fpm --no-pager -n 20" >&2
fi

# ── Deploy maintenance script ────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/privatebin-maint.sh <<'\''MAINT'\''
#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
PHP_VERSION="${PHP_VERSION:-8.4}"
APP_DIR="${APP_DIR:-/opt/privatebin}"
BACKUP_DIR="${BACKUP_DIR:-/opt/privatebin-backups}"

CONF_REL="cfg/conf.php"
DATA_REL="data"
FPM_SERVICE="php${PHP_VERSION}-fpm"

# ── Helpers ───────────────────────────────────────────────────────────────────
need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
  PrivateBin Maintenance
  ──────────────────────
  Usage:
    $0 update            Download latest + preserve config/data
    $0 backup            Create timestamped backup
    $0 list-backups      Show available backups
    $0 restore <file>    Restore from backup archive
    $0 restore-latest    Restore most recent backup
    $0 purge             Remove expired pastes + empty dirs
    $0 stats             Show paste statistics

  Env overrides:
    PHP_VERSION=$PHP_VERSION
    APP_DIR=$APP_DIR
    BACKUP_DIR=$BACKUP_DIR
EOF
}

latest_backup() {
  ls -1t "$BACKUP_DIR"/privatebin-*.tgz 2>/dev/null | head -n 1 || true
}

do_backup() {
  mkdir -p "$BACKUP_DIR"
  [[ -d "$APP_DIR" ]] || die "APP_DIR not found: $APP_DIR"

  local ts backup
  ts="$(date +%Y%m%d-%H%M%S)"
  backup="$BACKUP_DIR/privatebin-${ts}.tgz"

  echo "  Creating backup: $backup"
  tar -C "$(dirname "$APP_DIR")" -czf "$backup" "$(basename "$APP_DIR")"
  echo "  OK: $backup"
}

do_list_backups() {
  mkdir -p "$BACKUP_DIR"
  ls -lh "$BACKUP_DIR"/privatebin-*.tgz 2>/dev/null || echo "  No backups in $BACKUP_DIR"
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
  systemctl stop nginx || true
  systemctl stop "$FPM_SERVICE" || true

  if [[ -d "$APP_DIR" ]]; then
    local keep="${APP_DIR}.pre-restore.$(date +%Y%m%d-%H%M%S)"
    echo "  Keeping current as: $keep"
    mv "$APP_DIR" "$keep"
  fi

  tar -C "$(dirname "$APP_DIR")" -xzf "$tgz"

  chown -R www-data:www-data "$APP_DIR" || true
  chmod -R 0755 "$APP_DIR/$DATA_REL" 2>/dev/null || true

  systemctl start "$FPM_SERVICE"
  systemctl start nginx

  echo "  OK: Restored to $APP_DIR"
}

do_update() {
  [[ -d "$APP_DIR" ]] || die "APP_DIR not found: $APP_DIR"
  [[ -f "$APP_DIR/index.php" ]] || die "Not a PrivateBin install: $APP_DIR/index.php missing"

  local ts work new_dir old_dir
  ts="$(date +%Y%m%d-%H%M%S)"
  work="$(mktemp -d /tmp/privatebin-update.XXXXXX)"
  new_dir="$work/new"
  old_dir="$work/old"

  rollback() {
    echo "  !! Rolling back..."
    if [[ -d "$old_dir" ]]; then
      rm -rf "$APP_DIR"
      mv "$old_dir" "$APP_DIR"
      chown -R www-data:www-data "$APP_DIR" || true
      systemctl reload nginx || true
      systemctl restart "$FPM_SERVICE" || true
    fi
  }
  trap 'rollback' ERR

  do_backup

  mkdir -p "$new_dir"

  echo "  Downloading latest PrivateBin ..."
  curl -fsSL -L "https://api.github.com/repos/PrivateBin/PrivateBin/tarball" \
    | tar -xz --strip-components=1 -C "$new_dir"
  [[ -f "$new_dir/index.php" ]] || die "Downloaded bundle invalid (index.php missing)"

  echo "  Preserving config + data"
  local conf_tmp="$work/conf.php"
  local data_tmp="$work/data"
  if [[ -f "$APP_DIR/$CONF_REL" ]]; then cp -a "$APP_DIR/$CONF_REL" "$conf_tmp"; fi
  if [[ -d "$APP_DIR/$DATA_REL" ]]; then cp -a "$APP_DIR/$DATA_REL" "$data_tmp"; fi

  echo "  Swapping directories"
  mv "$APP_DIR" "$old_dir"
  mv "$new_dir" "$APP_DIR"

  echo "  Restoring config + data"
  mkdir -p "$APP_DIR/cfg" "$APP_DIR/$DATA_REL"
  if [[ -f "$conf_tmp" ]]; then
    cp -a "$conf_tmp" "$APP_DIR/$CONF_REL"
  else
    [[ -f "$APP_DIR/cfg/conf.sample.php" ]] && cp -a "$APP_DIR/cfg/conf.sample.php" "$APP_DIR/$CONF_REL" || true
  fi

  if [[ -d "$data_tmp" ]]; then
    rm -rf "$APP_DIR/$DATA_REL"
    cp -a "$data_tmp" "$APP_DIR/$DATA_REL"
  fi

  chown -R www-data:www-data "$APP_DIR"
  chmod -R 0755 "$APP_DIR/$DATA_REL" || true

  echo "  Reloading services"
  systemctl reload nginx
  systemctl restart "$FPM_SERVICE"

  trap - ERR
  rm -rf "$work"

  echo "  OK: Updated PrivateBin."
}

do_purge() {
  [[ -f "$APP_DIR/bin/administration" ]] || die "Administration script not found: $APP_DIR/bin/administration"
  echo "  Purging expired pastes..."
  php "$APP_DIR/bin/administration" --purge --empty-dirs
  echo "  OK: Purge complete."
}

do_stats() {
  [[ -f "$APP_DIR/bin/administration" ]] || die "Administration script not found: $APP_DIR/bin/administration"
  php "$APP_DIR/bin/administration" --statistics
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
  purge)           do_purge ;;
  stats)           do_stats ;;
  ""|-h|--help)    usage ;;
  *)               usage; die "Unknown command: $cmd" ;;
esac
MAINT
chmod +x /usr/local/bin/privatebin-maint.sh'

echo "  Maintenance script deployed: /usr/local/bin/privatebin-maint.sh"

# ── Auto-update timer ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail

  cat > /etc/systemd/system/privatebin-update.service <<EOF
[Unit]
Description=PrivateBin auto-update (backup + download + swap)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/privatebin-maint.sh update
StandardOutput=journal
StandardError=journal
EOF

  cat > /etc/systemd/system/privatebin-update.timer <<EOF
[Unit]
Description=PrivateBin biweekly auto-update

[Timer]
OnCalendar=*-*-01 04:30:00
OnCalendar=*-*-15 04:30:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now privatebin-update.timer
'
echo "  Auto-update timer enabled (1st + 15th of each month)"

# ── Purge timer (daily cleanup of expired pastes) ────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail

  cat > /etc/systemd/system/privatebin-purge.service <<EOF
[Unit]
Description=PrivateBin purge expired pastes + empty dirs

[Service]
Type=oneshot
WorkingDirectory=/opt/privatebin
ExecStart=/usr/bin/php /opt/privatebin/bin/administration --purge --empty-dirs
StandardOutput=journal
StandardError=journal
EOF

  cat > /etc/systemd/system/privatebin-purge.timer <<EOF
[Unit]
Description=PrivateBin daily purge

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=600

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now privatebin-purge.timer
'
echo "  Purge timer enabled (daily)"

# ── Unattended upgrades ──────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y unattended-upgrades
  distro_codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  cat > /etc/apt/apt.conf.d/52unattended-privatebin.conf <<EOF
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
  printf '  PrivateBin\\n'
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
  php_ver=\$(php -v 2>/dev/null | head -n1 | awk '{print \$2}' || echo 'n/a')
  nginx_active=\$(systemctl is-active nginx 2>/dev/null || echo 'unknown')
  fpm_active=\$(systemctl is-active php${PHP_VERSION}-fpm 2>/dev/null || echo 'unknown')
  printf '\\n'
  printf '  PrivateBin:\\n'
  printf '    App dir:       /opt/privatebin\\n'
  printf '    PHP:           %s\\n' \"\$php_ver\"
  printf '    Nginx:         %s\\n' \"\$nginx_active\"
  printf '    PHP-FPM:       %s\\n' \"\$fpm_active\"
  timer_next=\$(systemctl list-timers privatebin-update.timer --no-pager 2>/dev/null | awk 'NR==2{for(i=1;i<=NF;i++) if(\$i ~ /^[0-9]{4}-/) {printf \"%s %s\", \$i, \$(i+1); break}}' || echo 'n/a')
  printf '    Auto-update:   %s\\n' \"\${timer_next:-enabled}\"
  purge_active=\$(systemctl is-active privatebin-purge.timer 2>/dev/null || echo 'unknown')
  printf '    Purge timer:   %s (daily)\\n' \"\$purge_active\"
  printf '    Web UI:        https://%s/\\n' \"\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)\"
  printf '\\n'
  printf '  Maintenance:\\n'
  printf '    privatebin-maint.sh update\\n'
  printf '    privatebin-maint.sh backup\\n'
  printf '    privatebin-maint.sh list-backups\\n'
  printf '    privatebin-maint.sh restore <file>\\n'
  printf '    privatebin-maint.sh restore-latest\\n'
  printf '    privatebin-maint.sh purge\\n'
  printf '    privatebin-maint.sh stats\\n'
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
DESC="<a href='https://${CT_IP}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>PrivateBin Web UI</a>
<details><summary>Details</summary>PrivateBin on Debian ${DEBIAN_VERSION} LXC
PHP ${PHP_VERSION} + Nginx (native, self-signed TLS)
Maintenance: privatebin-maint.sh
Created by privatebin.sh</details>"
pct set "$CT_ID" --description "$DESC"

# ── Protection ────────────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  CT: $CT_ID | IP: ${CT_IP} | Web UI: https://${CT_IP}/ | Login: $([ -n "$PASSWORD" ] && echo 'password set' || echo 'auto-login')"
echo "  Maintenance: pct exec $CT_ID -- privatebin-maint.sh {update|backup|restore|list-backups|restore-latest}"
echo ""

# ── Reboot ────────────────────────────────────────────────────────────────────
pct stop "$CT_ID"
sleep 2
pct start "$CT_ID"
echo "  Done."
