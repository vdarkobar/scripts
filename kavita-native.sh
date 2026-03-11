#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID="$(pvesh get /cluster/nextid)"
HN="kavita"
CPU=2
RAM=2048
DISK=12
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Kavita
KAVITA_TAG="v0.8.9.1"
KAVITA_ASSET="kavita-linux-x64.tar.gz"
APP_PORT=5000
APP_TZ="Europe/Berlin"
TAGS="kavita;reader;lxc"

# Set to the full hostname of your Organizr instance if you use iframe embedding.
# Leave blank to skip the CSP header in the NPM Custom Locations summary output.
ORGANIZR_HOST=""               # e.g. organizr.example.com

DEBIAN_VERSION=13

# Optional features
ENABLE_AUTO_UPDATE=0                # 1 = enable monthly kavita-update.timer
KEEP_BACKUPS=5                      # config-only backups kept by kavita-maint.sh
DISABLE_IPV6=0                      # 1 = append IPv6 disable sysctls inside CT

# Behavior
CLEANUP_ON_FAIL=1                   # 1 = destroy CT on error, 0 = keep for debugging

# Derived
APP_DIR="/opt/Kavita"
BACKUP_DIR="/opt/Kavita-backups"
DOWNLOAD_URL="https://github.com/Kareadita/Kavita/releases/download/${KAVITA_TAG}/${KAVITA_ASSET}"

# ── Custom configs created by this script ─────────────────────────────────────
#   /opt/Kavita/                           (application root)
#   /opt/Kavita/config/                    (persistent app config, DB, logs, built-in backups)
#   /opt/Kavita-backups/                   (script-level config snapshots)
#   /etc/default/kavita                    (runtime env: active tag, asset, keep-backups)
#   /usr/local/bin/kavita-maint.sh         (maintenance helper)
#   /etc/systemd/system/kavita.service
#   /etc/systemd/system/kavita-update.service
#   /etc/systemd/system/kavita-update.timer
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/apt/apt.conf.d/20auto-upgrades
#   /etc/sysctl.d/99-hardening.conf

# ── Remote access (Nginx Proxy Manager) ──────────────────────────────────────
#   Proxy host:  http://<CT_IP>:5000   (HTTP, not HTTPS)
#   Toggle on:   Websockets Support
#   Toggle on:   Block Common Exploits
#   SSL:         request cert, then enable Force SSL + HSTS
#   Optional — Organizr iframe embedding only (Custom Locations tab):
#     Add location: /  →  scheme http, hostname <CT_IP>, port 5000
#     In the location's Advanced field (set ORGANIZR_HOST in config to get this pre-filled):
#       proxy_hide_header "Content-Security-Policy";
#       add_header Content-Security-Policy "frame-ancestors <ORGANIZR_HOST>;";
#     Note: these directives go in Custom Locations → Advanced, NOT the proxy host Advanced tab.

# ── Config validation ─────────────────────────────────────────────────────────
[[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }
[[ "$APP_PORT" =~ ^[0-9]+$ ]] || { echo "  ERROR: APP_PORT must be numeric." >&2; exit 1; }
(( APP_PORT >= 1 && APP_PORT <= 65535 )) || { echo "  ERROR: APP_PORT must be between 1 and 65535." >&2; exit 1; }
[[ "$KEEP_BACKUPS" =~ ^[0-9]+$ ]] || { echo "  ERROR: KEEP_BACKUPS must be numeric." >&2; exit 1; }
[[ "$ENABLE_AUTO_UPDATE" =~ ^[01]$ ]] || { echo "  ERROR: ENABLE_AUTO_UPDATE must be 0 or 1." >&2; exit 1; }
[[ "$DISABLE_IPV6" =~ ^[01]$ ]] || { echo "  ERROR: DISABLE_IPV6 must be 0 or 1." >&2; exit 1; }
[[ "$CLEANUP_ON_FAIL" =~ ^[01]$ ]] || { echo "  ERROR: CLEANUP_ON_FAIL must be 0 or 1." >&2; exit 1; }
[[ "$KAVITA_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || {
  echo "  ERROR: KAVITA_TAG must look like v0.8.9.1" >&2
  exit 1
}
[[ "$KAVITA_ASSET" =~ ^kavita-linux-[A-Za-z0-9_-]+\.tar\.gz$ ]] || {
  echo "  ERROR: KAVITA_ASSET must look like kavita-linux-x64.tar.gz" >&2
  exit 1
}
[[ -e "/usr/share/zoneinfo/${APP_TZ}" ]] || { echo "  ERROR: APP_TZ not found in /usr/share/zoneinfo: $APP_TZ" >&2; exit 1; }

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

  Kavita LXC Creator — Configuration
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
  Kavita tag:        $KAVITA_TAG
  Release asset:     $KAVITA_ASSET
  App port:          $APP_PORT
  Timezone:          $APP_TZ
  Tags:              $TAGS
  Auto-update:       $([ "$ENABLE_AUTO_UPDATE" -eq 1 ] && echo "enabled" || echo "disabled")
  Keep backups:      $KEEP_BACKUPS
  Disable IPv6:      $DISABLE_IPV6
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/kavita.sh"
SCRIPT_LOCAL="/root/kavita.sh"
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
  -features "nesting=1"
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
# Note: jq and unzip removed — Kavita ships as tar.gz, no JSON processing needed in-container
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y locales curl ca-certificates tar procps iproute2 unattended-upgrades
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

# ── Deploy Kavita release ─────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail

  getent group kavita >/dev/null || groupadd --system kavita
  id -u kavita >/dev/null 2>&1 || useradd --system --gid kavita --home-dir '${APP_DIR}' --shell /usr/sbin/nologin kavita

  install -d -m 0755 '${APP_DIR}' '${BACKUP_DIR}'
  rm -rf /opt/Kavita.new
  install -d -m 0755 /opt/Kavita.new

  curl -fsSL '${DOWNLOAD_URL}' -o /tmp/${KAVITA_ASSET}
  tar -xzf /tmp/${KAVITA_ASSET} -C /opt/Kavita.new --strip-components=1
  rm -f /tmp/${KAVITA_ASSET}

  [[ -x /opt/Kavita.new/Kavita ]] || { echo 'ERROR: Kavita binary not found after extract.' >&2; exit 1; }

  cp -a /opt/Kavita.new/. '${APP_DIR}/'
  rm -rf /opt/Kavita.new

  install -d -o kavita -g kavita -m 0750 '${APP_DIR}/config'
  chmod +x '${APP_DIR}/Kavita'
  chown -R kavita:kavita '${APP_DIR}' '${BACKUP_DIR}'
"
echo "  Kavita ${KAVITA_TAG} deployed to ${APP_DIR}"

# ── Runtime env file ──────────────────────────────────────────────────────────
# Persists the active tag and asset so kavita-maint.sh update/version/timer
# always converge to the last explicitly applied version, not the install-time
# baked-in default. update_cmd rewrites this file after a successful upgrade.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > /etc/default/kavita <<EOF
# Managed by kavita-maint.sh — do not edit by hand unless you know what you are doing.
KAVITA_TAG=${KAVITA_TAG}
KAVITA_ASSET=${KAVITA_ASSET}
KAVITA_KEEP_BACKUPS=${KEEP_BACKUPS}
EOF
  chmod 0644 /etc/default/kavita
"
echo "  Runtime env written: /etc/default/kavita"

# ── Systemd service ───────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/kavita.service <<EOF
[Unit]
Description=Kavita Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=kavita
Group=kavita
WorkingDirectory=/opt/Kavita
ExecStart=/opt/Kavita/Kavita
TimeoutStopSec=20
KillMode=process
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=/opt/Kavita

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now kavita
'
echo "  Service started: kavita.service"

# ── Verification ──────────────────────────────────────────────────────────────
sleep 3
if pct exec "$CT_ID" -- systemctl is-active --quiet kavita 2>/dev/null; then
  echo "  Kavita service is running"
else
  echo "  WARNING: Kavita may not be running — check: pct exec $CT_ID -- journalctl -u kavita --no-pager -n 80" >&2
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
  echo "  Kavita HTTP health check passed (port ${APP_PORT} — HTTP $HTTP_CODE)"
else
  echo "  WARNING: Kavita not responding on port ${APP_PORT} yet — check: pct exec $CT_ID -- journalctl -u kavita --no-pager -n 120" >&2
fi

if pct exec "$CT_ID" -- sh -lc "ss -tlnp 2>/dev/null | grep -q ':${APP_PORT} '" 2>/dev/null; then
  echo "  Kavita port ${APP_PORT} is listening"
else
  echo "  WARNING: Port ${APP_PORT} is not listening yet" >&2
fi

# ── Maintenance helper ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "cat > /usr/local/bin/kavita-maint.sh <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR=\"\${APP_DIR:-/opt/Kavita}\"
BACKUP_DIR=\"\${BACKUP_DIR:-/opt/Kavita-backups}\"
SERVICE=\"\${SERVICE:-kavita}\"

# Source runtime env file if present; baked-in values are last-resort fallbacks only.
# update_cmd rewrites /etc/default/kavita after every successful upgrade so the
# active tag is always the last one explicitly applied, not the install-time default.
ENV_FILE=\"/etc/default/kavita\"
if [[ -f \"\$ENV_FILE\" ]]; then
  # shellcheck disable=SC1090
  . \"\$ENV_FILE\"
fi
KAVITA_TAG=\"\${KAVITA_TAG:-${KAVITA_TAG}}\"
KAVITA_ASSET=\"\${KAVITA_ASSET:-${KAVITA_ASSET}}\"
KEEP_BACKUPS=\"\${KAVITA_KEEP_BACKUPS:-${KEEP_BACKUPS}}\"

need_root() { [[ \"\$(id -u)\" -eq 0 ]] || { echo '  ERROR: Run as root.' >&2; exit 1; }; }
die() { echo \"  ERROR: \$*\" >&2; exit 1; }

usage() {
  cat <<EOF
  Kavita Maintenance
  ──────────────────
  Usage:
    \$0 backup
    \$0 list-backups
    \$0 restore <backup.tar.gz>
    \$0 restore-latest
    \$0 update [vX.Y.Z[.W]]
    \$0 version

  Backup scope:
    - stops Kavita, snapshots \${APP_DIR}/config, restarts Kavita
    - does NOT back up media libraries
    - PBS / external backups should cover CT + bulk media
EOF
}

backup_cmd() {
  local out was_active=0
  install -d -m 0755 \"\$BACKUP_DIR\"
  [[ -d \"\$APP_DIR/config\" ]] || die \"Missing persistent path: \$APP_DIR/config\"
  out=\"\$BACKUP_DIR/kavita-config-backup-\$(date +%F-%H%M%S).tar.gz\"

  systemctl is-active --quiet \"\$SERVICE\" 2>/dev/null && was_active=1

  if [[ \"\$was_active\" -eq 1 ]]; then
    echo \"  Stopping service for consistent config snapshot .\"
    systemctl stop \"\$SERVICE\"
  fi

  echo \"  Creating config snapshot: \$out\"
  if ! tar -C / -czf \"\$out\" \"\${APP_DIR#/}/config\"; then
    [[ \"\$was_active\" -eq 1 ]] && systemctl start \"\$SERVICE\" || true
    die \"Failed to create config snapshot.\"
  fi

  if [[ \"\$was_active\" -eq 1 ]]; then
    echo \"  Starting service .\"
    systemctl start \"\$SERVICE\"
  fi

  if [[ \"\$KEEP_BACKUPS\" =~ ^[0-9]+$ ]] && (( KEEP_BACKUPS > 0 )); then
    ls -1t \"\$BACKUP_DIR\"/kavita-config-backup-*.tar.gz 2>/dev/null | awk -v keep=\"\$KEEP_BACKUPS\" 'NR>keep' | xargs -r rm -f --
  fi
  echo \"  OK: \$out\"
}

list_cmd() {
  ls -1t \"\$BACKUP_DIR\"/kavita-config-backup-*.tar.gz 2>/dev/null || echo '  No backups found.'
}

restore_cmd() {
  local backup=\"\$1\"
  [[ -n \"\$backup\" ]] || die 'Usage: kavita-maint.sh restore <backup.tar.gz>'
  [[ -f \"\$backup\" ]] || die \"Backup not found: \$backup\"

  echo '  Stopping service .'
  systemctl stop \"\$SERVICE\" 2>/dev/null || true

  echo '  Removing current config .'
  rm -rf \"\$APP_DIR/config\"

  echo '  Restoring config .'
  tar -C / -xzf \"\$backup\"
  chown -R kavita:kavita \"\$APP_DIR/config\"

  echo '  Starting service .'
  systemctl start \"\$SERVICE\"
  echo '  OK: restore completed.'
}

restore_latest_cmd() {
  local latest
  latest=\"\$(ls -1t \"\$BACKUP_DIR\"/kavita-config-backup-*.tar.gz 2>/dev/null | head -n1 || true)\"
  [[ -n \"\$latest\" ]] || die 'No backups found.'
  restore_cmd \"\$latest\"
}

update_cmd() {
  local target_tag=\"\${1:-\$KAVITA_TAG}\" work new_dir old_dir asset url
  [[ \"\$target_tag\" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die \"Invalid tag: \$target_tag\"
  [[ -d \"\$APP_DIR\" ]] || die \"APP_DIR not found: \$APP_DIR\"
  [[ -x \"\$APP_DIR/Kavita\" ]] || die \"Not a Kavita install: \$APP_DIR/Kavita missing\"

  work=\"\$(mktemp -d /tmp/kavita-update.XXXXXX)\"
  new_dir=\"\$work/new\"
  old_dir=\"\$work/old\"
  asset=\"\$KAVITA_ASSET\"
  url=\"https://github.com/Kareadita/Kavita/releases/download/\${target_tag}/\${asset}\"

  cleanup() { rm -rf \"\$work\"; }
  rollback() {
    echo '  !! Rolling back .' >&2
    systemctl stop \"\$SERVICE\" 2>/dev/null || true
    if [[ -d \"\$old_dir\" ]]; then
      rm -rf \"\$APP_DIR\"
      mv \"\$old_dir\" \"\$APP_DIR\"
      chown -R kavita:kavita \"\$APP_DIR\"
      systemctl start \"\$SERVICE\" || true
    fi
    cleanup
  }
  trap rollback ERR

  backup_cmd

  echo \"  Downloading Kavita \$target_tag .\"
  mkdir -p \"\$new_dir\"
  curl -fsSL \"\$url\" -o \"\$work/\$asset\"
  tar -xzf \"\$work/\$asset\" -C \"\$new_dir\" --strip-components=1
  [[ -x \"\$new_dir/Kavita\" ]] || die 'Downloaded release did not contain Kavita binary.'

  echo '  Preserving persistent config .'
  rm -rf \"\$new_dir/config\"

  echo '  Stopping service .'
  systemctl stop \"\$SERVICE\"

  echo '  Swapping directories .'
  mv \"\$APP_DIR\" \"\$old_dir\"
  mv \"\$new_dir\" \"\$APP_DIR\"
  cp -a \"\$old_dir/config\" \"\$APP_DIR/config\"
  chown -R kavita:kavita \"\$APP_DIR\"
  chmod +x \"\$APP_DIR/Kavita\"

  echo '  Starting service .'
  systemctl start \"\$SERVICE\"

  # Persist the newly applied tag before clearing the rollback trap — if this
  # write fails, rollback still fires and the installed binary matches the tag.
  cat > \"\$ENV_FILE\" <<ENVEOF
# Managed by kavita-maint.sh — do not edit by hand unless you know what you are doing.
KAVITA_TAG=\${target_tag}
KAVITA_ASSET=\${asset}
KAVITA_KEEP_BACKUPS=\${KEEP_BACKUPS}
ENVEOF
  chmod 0644 \"\$ENV_FILE\"

  trap - ERR
  rm -rf \"\$old_dir\"
  cleanup
  echo \"  OK: Updated Kavita to \$target_tag.\"
}

version_cmd() {
  echo \"APP_DIR=\$APP_DIR\"
  echo \"KAVITA_TAG=\$KAVITA_TAG  (source: \${ENV_FILE})\"
  echo \"KAVITA_ASSET=\$KAVITA_ASSET\"
  echo \"BACKUP_DIR=\$BACKUP_DIR\"
  echo \"SERVICE=\$SERVICE\"
  echo \"KEEP_BACKUPS=\$KEEP_BACKUPS\"
}

need_root
cmd=\"\${1:-}\"
case \"\$cmd\" in
  backup) backup_cmd ;;
  list-backups) list_cmd ;;
  restore) shift; restore_cmd \"\${1:-}\" ;;
  restore-latest) restore_latest_cmd ;;
  update) shift; update_cmd \"\${1:-}\" ;;
  version) version_cmd ;;
  ''|-h|--help) usage ;;
  *) usage; die \"Unknown command: \$cmd\" ;;
esac
MAINT
chmod 0755 /usr/local/bin/kavita-maint.sh"
echo "  Maintenance script deployed: /usr/local/bin/kavita-maint.sh"

# ── Auto-update timer (optional) ──────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/kavita-update.service <<EOF
[Unit]
Description=Kavita auto-update maintenance run
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kavita-maint.sh update
StandardOutput=journal
StandardError=journal
EOF

  cat > /etc/systemd/system/kavita-update.timer <<EOF
[Unit]
Description=Kavita monthly auto-update timer

[Timer]
OnCalendar=monthly
Persistent=true
RandomizedDelaySec=600

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
'
if [[ "$ENABLE_AUTO_UPDATE" -eq 1 ]]; then
  pct exec "$CT_ID" -- bash -lc 'systemctl enable --now kavita-update.timer'
  echo "  Auto-update timer enabled"
else
  pct exec "$CT_ID" -- bash -lc 'systemctl disable --now kavita-update.timer >/dev/null 2>&1 || true'
  echo "  Auto-update timer installed but disabled"
fi

# ── Unattended upgrades ───────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  distro_codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  cat > /etc/apt/apt.conf.d/52unattended-$(hostname).conf <<EOF
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
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
'

# ── Sysctl hardening ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/sysctl.d/99-hardening.conf <<EOF
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOF
'
if [[ "$DISABLE_IPV6" -eq 1 ]]; then
  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    cat >> /etc/sysctl.d/99-hardening.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  '
fi
pct exec "$CT_ID" -- bash -lc 'sysctl --system >/dev/null 2>&1 || true'

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

  cat > /etc/update-motd.d/00-header <<'MOTD'
#!/bin/sh
printf '\n  Kavita\n'
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
service_active=\$(systemctl is-active kavita 2>/dev/null || echo 'unknown')
timer_next=\$(systemctl list-timers kavita-update.timer --no-pager 2>/dev/null | awk 'NR==2{for(i=1;i<=NF;i++) if(\$i ~ /^[0-9]{4}-/) {printf \"%s %s\", \$i, \$(i+1); break}}' || echo 'disabled')
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '\n'
printf '  Kavita:\n'
printf '    App dir:       /opt/Kavita\n'
printf '    Config dir:    /opt/Kavita/config\n'
printf '    Service:       %s\n' \"\$service_active\"
printf '    Auto-update:   %s\n' \"\${timer_next:-disabled}\"
printf '    Web UI:        http://%s:${APP_PORT}/\n' \"\${ip:-127.0.0.1}\"
printf '\n'
printf '  Maintenance:\n'
printf '    kavita-maint.sh update\n'
printf '    kavita-maint.sh backup\n'
printf '    kavita-maint.sh list-backups\n'
printf '    kavita-maint.sh restore <file>\n'
printf '\n'
printf '  Backup scope:\n'
printf '    Service stopped during snapshot; config only; media libraries external.\n'
MOTD

  cat > /etc/update-motd.d/99-footer <<'MOTD'
#!/bin/sh
printf '  ────────────────────────────────────\n\n'
MOTD

  chmod +x /etc/update-motd.d/*
"

# ── Set TERM for console ───────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Proxmox UI description ────────────────────────────────────────────────────
DESC="<a href='http://${CT_IP}:${APP_PORT}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Kavita Web UI</a>
<details><summary>Details</summary>Kavita ${KAVITA_TAG} on Debian ${DEBIAN_VERSION} LXC
Native release tarball + systemd service
Config: /opt/Kavita/config
Maintenance: pct exec ${CT_ID} -- bash -lc 'kavita-maint.sh {update|backup|restore|list-backups}'
Created by kavita.sh</details>"
pct set "$CT_ID" --description "$DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  CT: $CT_ID | IP: ${CT_IP} | Web UI: http://${CT_IP}:${APP_PORT}/ | Login: password set"
echo "  App dir: ${APP_DIR} | Persistent config: ${APP_DIR}/config"
echo "  Maintenance: pct exec $CT_ID -- bash -lc 'kavita-maint.sh {update|backup|restore|list-backups|restore-latest|version}'"
echo "  Media note: add library folders outside ${APP_DIR}; do not store bulk media in the app directory."
echo "  Reverse proxy (NPM):"
echo "    1. New proxy host → http://${CT_IP}:${APP_PORT}, Websockets on, Block Common Exploits on"
echo "    2. SSL tab → Request cert, Force SSL on, HSTS on"
echo "    3. Organizr iframe only → Custom Locations tab, add location /"
echo "         scheme http · hostname ${CT_IP} · port ${APP_PORT}"
echo "         Advanced field: proxy_hide_header \"Content-Security-Policy\";"
if [[ -n "$ORGANIZR_HOST" ]]; then
  echo "                         add_header Content-Security-Policy \"frame-ancestors ${ORGANIZR_HOST};\";"
else
  echo "                         add_header Content-Security-Policy \"frame-ancestors <your-organizr-host>;\";"
  echo "                         (set ORGANIZR_HOST in config for a ready-to-paste value)"
fi
echo ""
echo "  Done."
