#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
APP="FileBrowser Quantum"
SERVICE_USER="filebrowser"
SHARE_GROUP="media"                  # shared group for shared directory access
INSTALL_BIN="/usr/local/bin/filebrowser"
CONFIG_DIR="/opt/filebrowser"
CONFIG_FILE="${CONFIG_DIR}/fq-config.yaml"
ENV_FILE="${CONFIG_DIR}/.env"
DB_FILE="${CONFIG_DIR}/database.db"
SERVICE_NAME="filebrowser"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
APP_PORT=8080
SERVE_ROOT="/srv/files"              # dedicated directory; do NOT use /
FQ_NOAUTH=0                          # 1 = no-auth (isolated testing only — see warning below)
APP_VERSION="latest"                 # pin a release tag, e.g. "v1.2.2-stable"; "latest" pulls newest

# Derived
if [[ "$APP_VERSION" == "latest" ]]; then
  RELEASE_URL="https://github.com/gtsteffaniak/filebrowser/releases/latest/download/linux-amd64-filebrowser"
else
  RELEASE_URL="https://github.com/gtsteffaniak/filebrowser/releases/download/${APP_VERSION}/linux-amd64-filebrowser"
fi

# ── Config validation ──────────────────────────────────────────────────────────
[[ "$FQ_NOAUTH" =~ ^[01]$ ]] \
  || { echo "  ERROR: FQ_NOAUTH must be 0 or 1." >&2; exit 1; }
[[ "$APP_PORT" =~ ^[0-9]+$ ]] && (( APP_PORT >= 1 && APP_PORT <= 65535 )) \
  || { echo "  ERROR: APP_PORT must be 1–65535." >&2; exit 1; }
[[ "$SERVE_ROOT" == "/" ]] \
  && { echo "  ERROR: SERVE_ROOT=\"/\" is not allowed. Set a dedicated path, e.g. /srv/files." >&2; exit 1; }

# ── OS / init preflight ────────────────────────────────────────────────────────
[[ -f /etc/debian_version ]] \
  || { echo "  ERROR: This script supports Debian only." >&2; exit 1; }
command -v systemctl >/dev/null 2>&1 \
  || { echo "  ERROR: systemd is required." >&2; exit 1; }
[[ "$(id -u)" -eq 0 ]] \
  || { echo "  ERROR: Run as root." >&2; exit 1; }

# Bootstrap curl before checking for it — it may just need installing
if ! command -v curl >/dev/null 2>&1; then
  echo "  curl not found — installing..."
  apt-get install -y -qq curl &>/dev/null
fi
command -v curl >/dev/null 2>&1 || { echo "  ERROR: curl could not be installed." >&2; exit 1; }
command -v awk  >/dev/null 2>&1 || { echo "  ERROR: Missing required command: awk" >&2; exit 1; }

# ── IP resolution (best-effort — summary only) ─────────────────────────────────
CT_IP=""
if command -v ip >/dev/null 2>&1; then
  IFACE="$(ip -4 route 2>/dev/null | awk '/default/ {print $5; exit}')"
  CT_IP="$(ip -4 addr show "${IFACE}" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)"
fi
[[ -z "$CT_IP" ]] && CT_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -z "$CT_IP" ]] && CT_IP="127.0.0.1"

# ── Already installed — offer update or uninstall ──────────────────────────────
if [[ -f "$INSTALL_BIN" ]]; then
  echo "  [WARN]  ${APP} is already installed."
  echo ""

  read -rp "  Uninstall ${APP}? (y/N): " _uninstall
  if [[ "${_uninstall,,}" =~ ^(y|yes)$ ]]; then
    echo "  Uninstalling ${APP}..."
    systemctl disable --now "${SERVICE_NAME}.service" &>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload &>/dev/null || true
    rm -f "$INSTALL_BIN" "$CONFIG_FILE" "$ENV_FILE" "$DB_FILE"
    echo "  [OK]    ${APP} uninstalled"
    exit 0
  fi

  read -rp "  Update ${APP} to version '${APP_VERSION}'? (y/N): " _update
  if [[ "${_update,,}" =~ ^(y|yes)$ ]]; then
    echo "  Updating ${APP}..."
    TMP_BIN="$(mktemp)"
    if ! curl -fsSL "$RELEASE_URL" -o "$TMP_BIN"; then
      echo "  ERROR: Download failed — aborting update" >&2
      rm -f "$TMP_BIN"
      exit 1
    fi
    chmod +x "$TMP_BIN"
    mv -f "$TMP_BIN" "$INSTALL_BIN"
    echo "  [OK]    Binary updated"
    systemctl restart "$SERVICE_NAME" \
      && echo "  [OK]    Service restarted" \
      || echo "  [WARN]  Service restart failed — check: journalctl -u ${SERVICE_NAME}" >&2
    exit 0
  fi

  echo "  Nothing to do. Exiting."
  exit 0
fi

# ── Fresh install ──────────────────────────────────────────────────────────────
echo "  ${APP} is not installed."
echo ""

if [[ "$FQ_NOAUTH" -eq 1 ]]; then
  echo "  [WARN]  FQ_NOAUTH=1 is set."
  echo "          No-auth mode disables all authentication."
  echo "          Upstream recommends this only for isolated testing environments."
  echo ""
  read -rp "  Confirm no-auth install? (y/N): " _noauth_confirm
  [[ "${_noauth_confirm,,}" =~ ^(y|yes)$ ]] \
    || { echo "  Aborted. Set FQ_NOAUTH=0 to use authentication."; exit 0; }
  echo ""
fi

read -rp "  Install ${APP}? (y/N): " _install
[[ "${_install,,}" =~ ^(y|yes)$ ]] || { echo "  Installation skipped. Exiting."; exit 0; }

# ── Admin credentials ──────────────────────────────────────────────────────────
FQ_ADMIN_USER="admin"
FQ_ADMIN_PASS=""
if [[ "$FQ_NOAUTH" -eq 0 ]]; then
  while true; do
    read -r -s -p "  Set FileBrowser admin password: " AP1; echo
    if [[ -z "$AP1" ]];          then echo "  Password cannot be blank."; continue; fi
    if [[ "$AP1" == *" "* ]];    then echo "  Password cannot contain spaces."; continue; fi
    if [[ ${#AP1} -lt 5 ]];      then echo "  Password must be at least 5 characters."; continue; fi
    read -r -s -p "  Verify admin password: " AP2; echo
    if [[ "$AP1" == "$AP2" ]]; then FQ_ADMIN_PASS="$AP1"; break; fi
    echo "  Passwords do not match. Try again."
  done
  echo ""
fi

# ── Dependencies ───────────────────────────────────────────────────────────────
echo "  Installing dependencies..."
apt-get install -y -qq curl ffmpeg &>/dev/null
echo "  [OK]    Dependencies installed"

# ── Service user and shared group ──────────────────────────────────────────────
getent group "$SHARE_GROUP" >/dev/null || groupadd "$SHARE_GROUP"

if ! id "$SERVICE_USER" &>/dev/null; then
  adduser --system --no-create-home --group "$SERVICE_USER" &>/dev/null
  echo "  [OK]    Service user '${SERVICE_USER}' created"
fi
usermod -aG "$SHARE_GROUP" "$SERVICE_USER"

# ── Suggest users for shared group ────────────────────────────────────────────
_noise="nobody messagebus systemd-network systemd-resolve systemd-timesync \
        _apt daemon bin sys games man lp mail news uucp proxy www-data \
        backup list irc gnats sshd"

echo ""
echo "  Service users found on this system:"
_found=0
while IFS=: read -r _name _ _uid _; do
  if (( _uid >= 100 && _uid <= 999 )); then
    _skip=0
    for _n in $_noise; do [[ "$_name" == "$_n" ]] && _skip=1 && break; done
    if [[ "$_skip" -eq 0 && "$_name" != "$SERVICE_USER" ]]; then
      echo "    - ${_name}"
      _found=1
    fi
  fi
done < /etc/passwd
[[ "$_found" -eq 0 ]] && echo "    (none)"

echo ""
read -rp "  Add users to group '${SHARE_GROUP}' (space-separated, or Enter to skip): " _input
SHARE_USERS="${_input:-}"
echo ""

for _u in $SHARE_USERS; do
  if id "$_u" &>/dev/null; then
    usermod -aG "$SHARE_GROUP" "$_u"
    echo "  [OK]    Added '${_u}' to group '${SHARE_GROUP}'"
  else
    echo "  [WARN]  User '${_u}' not found — skipping"
  fi
done

# ── Download binary ────────────────────────────────────────────────────────────
echo "  Downloading ${APP} binary (${APP_VERSION})..."
TMP_BIN="$(mktemp)"
if ! curl -fsSL "$RELEASE_URL" -o "$TMP_BIN"; then
  echo "  ERROR: Download failed" >&2
  rm -f "$TMP_BIN"
  exit 1
fi
chmod +x "$TMP_BIN"
mv -f "$TMP_BIN" "$INSTALL_BIN"
echo "  [OK]    Binary installed"

# ── Directories ────────────────────────────────────────────────────────────────
mkdir -p "$CONFIG_DIR" "$SERVE_ROOT"

chown -R "${SERVICE_USER}:${SERVICE_USER}" "$CONFIG_DIR"
chmod 0750 "$CONFIG_DIR"

chown root:"$SHARE_GROUP" "$SERVE_ROOT"
chmod 2770 "$SERVE_ROOT"

# ── Write config ───────────────────────────────────────────────────────────────
if [[ "$FQ_NOAUTH" -eq 1 ]]; then
  cat > "$CONFIG_FILE" <<EOF
server:
  port: ${APP_PORT}
  database: "${DB_FILE}"
  sources:
    - path: "${SERVE_ROOT}"
      name: "Files"
      config:
        denyByDefault: false
        disableIndexing: false
        indexingIntervalMinutes: 240
auth:
  methods:
    noauth: true
EOF
else
  cat > "$CONFIG_FILE" <<EOF
server:
  port: ${APP_PORT}
  database: "${DB_FILE}"
  sources:
    - path: "${SERVE_ROOT}"
      name: "Files"
      config:
        denyByDefault: false
        disableIndexing: false
        indexingIntervalMinutes: 240
auth:
  adminUsername: ${FQ_ADMIN_USER}
EOF
fi
chown "${SERVICE_USER}:${SERVICE_USER}" "$CONFIG_FILE"
chmod 0640 "$CONFIG_FILE"
echo "  [OK]    Config written"

# ── Write env file (secrets) ───────────────────────────────────────────────────
if [[ "$FQ_NOAUTH" -eq 0 ]]; then
  cat > "$ENV_FILE" <<EOF
FILEBROWSER_ADMIN_PASSWORD=${FQ_ADMIN_PASS}
EOF
  chown "${SERVICE_USER}:${SERVICE_USER}" "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
  echo "  [OK]    Env file written"
fi

# ── Service registration ───────────────────────────────────────────────────────
echo "  Registering service..."

ENV_LINE=""
[[ "$FQ_NOAUTH" -eq 0 ]] && ENV_LINE="EnvironmentFile=${ENV_FILE}"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=${APP}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${CONFIG_DIR}
${ENV_LINE}
ExecStart=${INSTALL_BIN} -c ${CONFIG_FILE}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload &>/dev/null
systemctl enable --now "$SERVICE_NAME" &>/dev/null
echo "  [OK]    Service registered and started"

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "  [OK]    ${APP} is running"
echo "    URL   : http://${CT_IP}:${APP_PORT}/"
echo "    Files : ${SERVE_ROOT}  (group: ${SHARE_GROUP})"
echo "    Conf  : ${CONFIG_FILE}"
echo "    DB    : ${DB_FILE}"
echo "    Bin   : ${INSTALL_BIN}"
if [[ "$FQ_NOAUTH" -eq 1 ]]; then
  echo "    Auth  : disabled (no-auth mode)"
else
  echo "    Auth  : ${FQ_ADMIN_USER} / (password set at install)"
  echo "    Env   : ${ENV_FILE}"
fi
echo ""
