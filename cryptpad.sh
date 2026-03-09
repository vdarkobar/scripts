#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID="$(pvesh get /cluster/nextid)"
HN="cryptpad"
CPU=2
RAM=2048
DISK=20
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# CryptPad
CRYPTPAD_TAG="2025.9.0"
NODE_VERSION=22
APP_PORT=3000
SAFE_PORT=3001
WS_PORT=3003
APP_TZ="Europe/Berlin"
TAGS="cryptpad;lxc"

# Domains
DOMAIN_NAME=""                         # base domain only — cryptpad. prefix added automatically; empty = local IP only mode
SANDBOX_DOMAIN="sandbox-cryptpad"      # sandbox subdomain prefix — FQDN = ${SANDBOX_DOMAIN}.${DOMAIN_NAME}

# Optional features
INSTALL_ONLYOFFICE=0                   # 1 = install OnlyOffice components
ENABLE_AUTO_UPDATE=0                   # 1 = enable biweekly CryptPad updater

DEBIAN_VERSION=13

# Behavior
CLEANUP_ON_FAIL=1  # 1 = destroy CT on error, 0 = keep for debugging

# Derived
[[ -n "$DOMAIN_NAME" && -n "$SANDBOX_DOMAIN" ]] && SANDBOX_FQDN="${SANDBOX_DOMAIN}.${DOMAIN_NAME}" || SANDBOX_FQDN=""
MAIN_FQDN=""
[[ -n "$DOMAIN_NAME" ]] && MAIN_FQDN="cryptpad.${DOMAIN_NAME}"

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

# ── Config validation ─────────────────────────────────────────────────────────
[[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }
[[ "$NODE_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: NODE_VERSION must be numeric." >&2; exit 1; }
[[ "$CRYPTPAD_TAG" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]] || {
  echo "  ERROR: CRYPTPAD_TAG must look like 2025.9.0" >&2
  exit 1
}

# ── Preflight — root & commands ───────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pvesh pveam pct pvesm curl python3 ip awk sort paste; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

# ── Discover available resources ──────────────────────────────────────────────
AVAIL_TMPL_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'vztmpl' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_CT_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^vmbr' | sort | paste -sd', ' || echo "n/a")"

# ── Show defaults & confirm ───────────────────────────────────────────────────
cat <<EOF

  CryptPad LXC Creator — Configuration
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
  Node.js version:   $NODE_VERSION
  CryptPad tag:      $CRYPTPAD_TAG
  App port:          $APP_PORT
  Safe port:         $SAFE_PORT
  WebSocket port:    $WS_PORT
  OnlyOffice:        $([ "$INSTALL_ONLYOFFICE" -eq 1 ] && echo "yes" || echo "no")
  Auto-update:       $([ "$ENABLE_AUTO_UPDATE" -eq 1 ] && echo "enabled" || echo "disabled")
  Domain (main):     ${MAIN_FQDN:-"(not set — local IP only mode)"}
  Domain (sandbox):  ${SANDBOX_FQDN:-"(not set — local safe port mode)"}
  Timezone:          $APP_TZ
  Tags:              $TAGS
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/cryptpad.sh"
SCRIPT_LOCAL="/root/cryptpad.sh"

read -r -p "  Continue with these settings? [y/N]: " response
case "$response" in
  [yY][eE][sS]|[yY]) ;;
  *)
    echo ""
    echo "  Downloading script to ${SCRIPT_LOCAL} for editing..."
    if curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_LOCAL"; then
      chmod +x "$SCRIPT_LOCAL"
      echo "  Edit:  nano ${SCRIPT_LOCAL}"
      echo "  Run:   bash ${SCRIPT_LOCAL}"
      echo ""
    else
      echo "  ERROR: Failed to download script." >&2
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
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y locales git curl ca-certificates gnupg unzip jq xz-utils
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

# ── Node.js + dedicated user ──────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive

  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_VERSION}.x nodistro main' \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update -qq
  apt-get install -y nodejs

  getent group cryptpad >/dev/null || groupadd --system cryptpad
  id -u cryptpad >/dev/null 2>&1 || useradd --system --gid cryptpad --home-dir /opt/cryptpad --shell /usr/sbin/nologin cryptpad
"

NODE_VER="$(pct exec "$CT_ID" -- node --version 2>/dev/null || echo "unknown")"
echo "  Node.js installed: $NODE_VER"

# ── Deploy CryptPad release tag ───────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail

  rm -rf /opt/cryptpad.new
  git clone -b '${CRYPTPAD_TAG}' --depth 1 https://github.com/cryptpad/cryptpad.git /opt/cryptpad.new
  cd /opt/cryptpad.new

  install -d -o cryptpad -g cryptpad -m 0750 /opt/cryptpad
  cp -a /opt/cryptpad.new/. /opt/cryptpad/
  rm -rf /opt/cryptpad.new

  install -d -o cryptpad -g cryptpad -m 0750 \
    /opt/cryptpad/config \
    /opt/cryptpad/customize \
    /opt/cryptpad/data \
    /opt/cryptpad/datastore \
    /opt/cryptpad/blob \
    /opt/cryptpad/block

  chown -R cryptpad:cryptpad /opt/cryptpad
"
echo "  CryptPad ${CRYPTPAD_TAG} deployed to /opt/cryptpad"

# ── Application configuration ─────────────────────────────────────────────────
LOGIN_SALT="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
)"

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cd /opt/cryptpad

  [[ -f config/config.js ]] || cp config/config.example.js config/config.js

  python3 - <<'PY'
from pathlib import Path

cfg = Path('/opt/cryptpad/config/config.js')
text = cfg.read_text()

def replace_once(src, old, new):
    if old in src:
        return src.replace(old, new, 1)
    raise SystemExit(f'Could not find expected config entry: {old}')

text = replace_once(text, \"httpUnsafeOrigin: 'http://localhost:3000'\", \"httpUnsafeOrigin: 'https://${MAIN_FQDN}'\" if '${MAIN_FQDN}' else \"httpUnsafeOrigin: 'http://${CT_IP}:${APP_PORT}'\")
if '${SANDBOX_FQDN}':
    if '// httpSafeOrigin: \"https://some-other-domain.xyz\",' in text:
        text = text.replace('// httpSafeOrigin: \"https://some-other-domain.xyz\",', 'httpSafeOrigin: \"https://${SANDBOX_FQDN}\",', 1)
    elif '//httpSafeOrigin:' in text:
        text = text.replace('//httpSafeOrigin:', 'httpSafeOrigin:', 1)
else:
    # leave httpSafeOrigin commented in local mode
    pass

if '//httpAddress: \\'localhost\\',' in text:
    text = text.replace(\"//httpAddress: 'localhost',\", \"httpAddress: '0.0.0.0',\", 1)
if '//httpPort: 3000,' in text:
    text = text.replace('//httpPort: 3000,', 'httpPort: ${APP_PORT},', 1)
if not '${SANDBOX_FQDN}' and '//httpSafePort: 3001,' in text:
    text = text.replace('//httpSafePort: 3001,', 'httpSafePort: ${SAFE_PORT},', 1)
if '// websocketPort: 3003,' in text:
    text = text.replace('// websocketPort: 3003,', 'websocketPort: ${WS_PORT},', 1)
if \"installMethod: 'unspecified',\" in text:
    text = text.replace(\"installMethod: 'unspecified',\", \"installMethod: 'native-lxc',\", 1)

cfg.write_text(text)
PY

  if [[ ! -f customize/application_config.js ]]; then
    if [[ -f customize.dist/application_config.js ]]; then
      cp customize.dist/application_config.js customize/application_config.js
    else
      : > customize/application_config.js
    fi
  fi

  grep -q 'AppConfig.loginSalt' customize/application_config.js 2>/dev/null \
    || printf \"\\nAppConfig.loginSalt = '%s';\\n\" '${LOGIN_SALT}' >> customize/application_config.js

  chown -R cryptpad:cryptpad /opt/cryptpad
  chmod 0640 /opt/cryptpad/config/config.js
  chmod 0640 /opt/cryptpad/customize/application_config.js
"

# ── Build CryptPad ────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cd /opt/cryptpad
  su -s /bin/bash -c "npm ci" cryptpad
  su -s /bin/bash -c "npm run install:components" cryptpad
'
echo "  npm dependencies installed"

if [[ "$INSTALL_ONLYOFFICE" -eq 1 ]]; then
  echo "  Installing OnlyOffice components (this may take a while)..."
  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    cd /opt/cryptpad
    su -s /bin/bash -c "./install-onlyoffice.sh --accept-license" cryptpad
  '
  echo "  OnlyOffice components installed"
fi

pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cd /opt/cryptpad
  su -s /bin/bash -c "npm run build" cryptpad
'
echo "  CryptPad configured and built (main port: ${APP_PORT}, safe port: ${SAFE_PORT}, websocket port: ${WS_PORT})"

# ── Systemd service ───────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/cryptpad.service <<EOF
[Unit]
Description=CryptPad Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=cryptpad
Group=cryptpad
WorkingDirectory=/opt/cryptpad
ExecStart=/usr/bin/node server
Environment="HOME=/opt/cryptpad"
Environment="PWD=/opt/cryptpad"
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=/opt/cryptpad

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now cryptpad
'

# ── Verification ──────────────────────────────────────────────────────────────
sleep 3
if pct exec "$CT_ID" -- systemctl is-active --quiet cryptpad 2>/dev/null; then
  echo "  CryptPad service is running"
else
  echo "  WARNING: CryptPad may not be running — check: pct exec $CT_ID -- journalctl -u cryptpad --no-pager -n 50" >&2
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
  echo "  CryptPad HTTP health check passed (main port ${APP_PORT} — HTTP $HTTP_CODE)"
else
  echo "  WARNING: CryptPad not responding on port ${APP_PORT} yet — may still be initializing" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u cryptpad --no-pager -n 80" >&2
fi

if pct exec "$CT_ID" -- sh -lc "ss -tlnp 2>/dev/null | grep -q ':${WS_PORT} '" 2>/dev/null; then
  echo "  CryptPad websocket port ${WS_PORT} is listening"
else
  echo "  WARNING: Websocket not listening on port ${WS_PORT} yet — check config.js and journal" >&2
fi

if [[ -z "$DOMAIN_NAME" ]]; then
  if pct exec "$CT_ID" -- sh -lc "ss -tlnp 2>/dev/null | grep -q ':${SAFE_PORT} '" 2>/dev/null; then
    echo "  CryptPad safe port ${SAFE_PORT} is listening (local sandbox mode)"
  else
    echo "  WARNING: Safe port ${SAFE_PORT} is not listening yet — check config.js and journal" >&2
  fi
fi

# ── Extract admin token URL ───────────────────────────────────────────────────
ADMIN_TOKEN_URL=""
for i in $(seq 1 12); do
  ADMIN_TOKEN_URL="$(pct exec "$CT_ID" -- journalctl -u cryptpad --no-pager -n 200 2>/dev/null \
    | grep -o 'http[^[:space:]]*/install/#[^[:space:]]*' | head -n1 || true)"
  [[ -n "$ADMIN_TOKEN_URL" ]] && break
  sleep 2
done
if [[ -n "$ADMIN_TOKEN_URL" ]]; then
  echo "  Admin setup URL found"
else
  echo "  WARNING: Admin token URL not found in journal yet — check manually:" >&2
  echo "  pct exec $CT_ID -- journalctl -u cryptpad --no-pager -n 100 | grep install" >&2
fi

# ── Maintenance script ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "cat > /usr/local/bin/cryptpad-maint.sh <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR=\"\${APP_DIR:-/opt/cryptpad}\"
SERVICE=\"cryptpad\"
CRYPTPAD_TAG=\"\${CRYPTPAD_TAG:-${CRYPTPAD_TAG}}\"
INSTALL_ONLYOFFICE=\"\${INSTALL_ONLYOFFICE:-${INSTALL_ONLYOFFICE}}\"

need_root() { [[ \$EUID -eq 0 ]] || { echo '  ERROR: Run as root.' >&2; exit 1; }; }
die() { echo \"  ERROR: \$*\" >&2; exit 1; }

usage() {
  cat <<EOF
  CryptPad Maintenance
  ──────────────────────
  Usage:
    \$0 update

  Env overrides:
    APP_DIR=\$APP_DIR
    CRYPTPAD_TAG=\$CRYPTPAD_TAG
    INSTALL_ONLYOFFICE=\$INSTALL_ONLYOFFICE
EOF
}

do_update() {
  [[ -d \"\$APP_DIR\" ]] || die \"APP_DIR not found: \$APP_DIR\"
  [[ -f \"\$APP_DIR/server.js\" ]] || die \"Not a CryptPad install: \$APP_DIR/server.js missing\"

  local work new_dir old_dir
  work=\"\$(mktemp -d /tmp/cryptpad-update.XXXXXX)\"
  new_dir=\"\$work/new\"
  old_dir=\"\$work/old\"

  cleanup() { rm -rf \"\$work\"; }
  rollback() {
    echo '  !! Rolling back...'
    systemctl stop \"\$SERVICE\" 2>/dev/null || true
    if [[ -d \"\$old_dir\" ]]; then
      rm -rf \"\$APP_DIR\"
      mv \"\$old_dir\" \"\$APP_DIR\"
      chown -R cryptpad:cryptpad \"\$APP_DIR\"
      systemctl start \"\$SERVICE\" || true
    fi
  }
  trap rollback ERR

  echo \"  Downloading CryptPad tag \$CRYPTPAD_TAG ...\"
  git clone -b \"\$CRYPTPAD_TAG\" --depth 1 https://github.com/cryptpad/cryptpad.git \"\$new_dir\"
  cd \"\$new_dir\"

  echo '  Restoring persistent paths'
  rm -rf \"\$new_dir/config\" \"\$new_dir/customize\" \"\$new_dir/data\" \"\$new_dir/datastore\" \"\$new_dir/blob\" \"\$new_dir/block\"
  cp -a \"\$APP_DIR/config\" \"\$new_dir/config\"
  cp -a \"\$APP_DIR/customize\" \"\$new_dir/customize\"
  cp -a \"\$APP_DIR/data\" \"\$new_dir/data\"
  cp -a \"\$APP_DIR/datastore\" \"\$new_dir/datastore\"
  cp -a \"\$APP_DIR/blob\" \"\$new_dir/blob\"
  cp -a \"\$APP_DIR/block\" \"\$new_dir/block\"

  echo '  Stopping service'
  systemctl stop \"\$SERVICE\"

  echo '  Swapping directories'
  mv \"\$APP_DIR\" \"\$old_dir\"
  mv \"\$new_dir\" \"\$APP_DIR\"
  chown -R cryptpad:cryptpad \"\$APP_DIR\"

  echo '  Rebuilding'
  cd \"\$APP_DIR\"
  su -s /bin/bash -c 'npm ci' cryptpad
  su -s /bin/bash -c 'npm run install:components' cryptpad
  if [[ \"\$INSTALL_ONLYOFFICE\" -eq 1 && -f \"\$APP_DIR/install-onlyoffice.sh\" ]]; then
    echo '  Re-installing OnlyOffice components ...'
    su -s /bin/bash -c './install-onlyoffice.sh --accept-license' cryptpad
  fi
  su -s /bin/bash -c 'npm run build' cryptpad

  echo '  Starting service'
  systemctl start \"\$SERVICE\"

  trap - ERR
  rm -rf \"\$old_dir\"
  cleanup
  echo \"  OK: Updated CryptPad to \$CRYPTPAD_TAG.\"
}

need_root
cmd=\"\${1:-}\"

case \"\$cmd\" in
  update) do_update ;;
  ''|-h|--help) usage ;;
  *) usage; die \"Unknown command: \$cmd\" ;;
esac
MAINT
chmod 0755 /usr/local/bin/cryptpad-maint.sh"
echo "  Maintenance script deployed: /usr/local/bin/cryptpad-maint.sh"

# ── Auto-update timer (optional) ──────────────────────────────────────────────
if [[ "$ENABLE_AUTO_UPDATE" -eq 1 ]]; then
  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail

    cat > /etc/systemd/system/cryptpad-update.service <<EOF
[Unit]
Description=CryptPad auto-update (pinned tag)
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
else
  echo "  Auto-update timer not enabled"
fi

# ── Unattended upgrades ───────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y unattended-upgrades
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
  systemctl enable --now unattended-upgrades
'

# ── Sysctl hardening ──────────────────────────────────────────────────────────
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
printf '\n  CryptPad\n'
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
node_ver=\$(node --version 2>/dev/null || echo 'n/a')
service_active=\$(systemctl is-active cryptpad 2>/dev/null || echo 'unknown')
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '\n'
printf '  CryptPad:\n'
printf '    App dir:         /opt/cryptpad\n'
printf '    Config:          /opt/cryptpad/config/config.js\n'
printf '    App config:      /opt/cryptpad/customize/application_config.js\n'
printf '    Node.js:         %s\n' \"\$node_ver\"
printf '    Service:         %s\n' \"\$service_active\"
timer_next=\$(systemctl list-timers cryptpad-update.timer --no-pager 2>/dev/null | awk 'NR==2{for(i=1;i<=NF;i++) if(\$i ~ /^[0-9]{4}-/) {printf \"%s %s\", \$i, \$(i+1); break}}' || echo 'disabled')
printf '    Auto-update:     %s\n' \"\${timer_next:-disabled}\"
printf '    Web UI (local):  http://%s:${APP_PORT}/\n' \"\$ip\"
printf '    Safe UI (local): http://%s:${SAFE_PORT}/\n' \"\$ip\"
[ -n '${MAIN_FQDN}' ] && printf '    Main  (public):  https://${MAIN_FQDN}/\n' || true
[ -n '${SANDBOX_FQDN}' ] && printf '    Safe  (public):  https://${SANDBOX_FQDN}/\n' || true
printf '\n'
printf '  Maintenance:\n'
printf '    cryptpad-maint.sh update\n'
printf '\n'
printf '  Admin setup:\n'
printf '    journalctl -u cryptpad --no-pager -n 100 | grep install\n'
printf '\n'
printf '  Known issue:\n'
printf '    OnlyOffice Document may freeze after typing\n'
printf '    if inner.js still maps doc -> text.\n'
printf '    Check:\n'
printf '      grep -o "file.doc = \'[^\']*\'" /opt/cryptpad/www/common/onlyoffice/inner.js\n'
printf '    If it shows: file.doc = '\''text'\'', patch it:\n'
printf '      sed -i "s/file\.doc = \'text\'/file.doc = \'word\'/" /opt/cryptpad/www/common/onlyoffice/inner.js\n'
printf '      systemctl restart cryptpad\n'
MOTD

  cat > /etc/update-motd.d/99-footer <<'MOTD'
#!/bin/sh
printf '  ────────────────────────────────────\n\n'
MOTD

  chmod +x /etc/update-motd.d/*
"

# Set TERM for console
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Proxmox UI description ────────────────────────────────────────────────────
OO_NOTE=""
[[ "$INSTALL_ONLYOFFICE" -eq 1 ]] && OO_NOTE=" + OnlyOffice"
DESC="<a href='http://${CT_IP}:${APP_PORT}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>CryptPad Web UI</a>
<details><summary>Details</summary>CryptPad ${CRYPTPAD_TAG} on Debian ${DEBIAN_VERSION} LXC
Node.js ${NODE_VERSION} (native)${OO_NOTE}
Created by cryptpad.sh</details>"
pct set "$CT_ID" --description "$DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  CT: $CT_ID | IP: ${CT_IP} | Login: password set"
echo ""
echo "  Access (local):"
echo "    Main: http://${CT_IP}:${APP_PORT}/"
if [[ -z "$DOMAIN_NAME" ]]; then
  echo "    Safe: http://${CT_IP}:${SAFE_PORT}/"
fi
echo ""

ADMIN_TOKEN_HASH="${ADMIN_TOKEN_URL##*#}"
if [[ -n "$MAIN_FQDN" ]]; then
  echo "  Access (public):"
  echo "    Main: https://${MAIN_FQDN}/"
  [[ -n "$SANDBOX_FQDN" ]] && echo "    Safe: https://${SANDBOX_FQDN}/"
  echo ""
fi

if [[ -n "$ADMIN_TOKEN_HASH" ]]; then
  if [[ -n "$MAIN_FQDN" ]]; then
    echo "  Admin setup URL:"
    echo "    https://${MAIN_FQDN}/install/#${ADMIN_TOKEN_HASH}"
  else
    echo "  Admin setup URLs:"
    echo "    Main: http://${CT_IP}:${APP_PORT}/install/#${ADMIN_TOKEN_HASH}"
    echo "    Safe: http://${CT_IP}:${SAFE_PORT}/install/#${ADMIN_TOKEN_HASH}"
  fi
else
  echo "  Admin setup:"
  echo "    pct exec $CT_ID -- journalctl -u cryptpad --no-pager -n 100 | grep install"
fi
echo ""
echo "  Config files:"
echo "    /opt/cryptpad/config/config.js"
echo "    /opt/cryptpad/customize/application_config.js"
echo ""

if [[ -n "$MAIN_FQDN" ]]; then
  echo "  Reverse proxy (NPM + Cloudflared):"
  echo ""
  echo "  Step 1 — Cloudflare tunnel public hostnames:"
  echo "    ${MAIN_FQDN}  -> http://localhost:80"
  [[ -n "$SANDBOX_FQDN" ]] && echo "    ${SANDBOX_FQDN}  -> http://localhost:80"
  echo ""
  echo "  Step 2 — NPM proxy host 1 — main interface:"
  echo "      ${MAIN_FQDN} -> http://${CT_IP}:${APP_PORT}"
  echo "      WebSockets enabled in NPM."
  echo "      Custom Nginx config:"
  echo "        location /cryptpad_websocket {"
  echo "            proxy_pass http://${CT_IP}:${WS_PORT};"
  echo "            proxy_http_version 1.1;"
  echo "            proxy_set_header Upgrade \$http_upgrade;"
  echo "            proxy_set_header Connection \"upgrade\";"
  echo "        }"
  echo ""
  if [[ -n "$SANDBOX_FQDN" ]]; then
    echo "  Step 2 — NPM proxy host 2 — sandbox iframe:"
    echo "      ${SANDBOX_FQDN} -> http://${CT_IP}:${APP_PORT}"
    echo "      WebSockets enabled in NPM."
    echo "      Custom Nginx config:"
    echo "        location /cryptpad_websocket {"
    echo "            proxy_pass http://${CT_IP}:${WS_PORT};"
    echo "            proxy_http_version 1.1;"
    echo "            proxy_set_header Upgrade \$http_upgrade;"
    echo "            proxy_set_header Connection \"upgrade\";"
    echo "        }"
    echo ""
  fi
  echo "  !! Create the first admin account only after both public hostnames work."
  echo ""
fi

echo "  Maintenance:"
echo "    pct exec $CT_ID -- cryptpad-maint.sh update"
echo ""
echo "  NOTE: npm build steps require more RAM than normal operation."
echo "    If update OOMs at ${RAM} MiB, bump CT memory before running:"
echo "    pct set $CT_ID --memory 4096  # then restore after update"
echo ""
echo "  Known issue (OnlyOffice Document editor):"
echo "    Some installs may freeze after typing if inner.js still uses"
echo "    file.doc = 'text' instead of 'word'."
echo ""
echo "  Check:"
echo "    pct exec $CT_ID -- grep -o \"file.doc = '[^']*'\" /opt/cryptpad/www/common/onlyoffice/inner.js"
echo ""
echo "  If it shows: file.doc = 'text', apply:"
echo "    pct exec $CT_ID -- sed -i \"s/file\\.doc = 'text'/file.doc = 'word'/\" /opt/cryptpad/www/common/onlyoffice/inner.js"
echo "    pct exec $CT_ID -- systemctl restart cryptpad"
echo ""
echo "  Done."
