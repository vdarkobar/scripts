#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
APP="FileBrowser Quantum"
SERVICE_USER="filebrowser"
INSTALL_BIN="/usr/local/bin/filebrowser"
CONFIG_DIR="/opt/filebrowser"
CONFIG_FILE="${CONFIG_DIR}/fq-config.yaml"
ENV_FILE="${CONFIG_DIR}/.env"
DB_FILE="${CONFIG_DIR}/database.db"
SERVICE_NAME="filebrowser"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
APP_PORT=8080
SERVE_ROOT="/srv/files"              # dedicated directory; do NOT use / or /var paths
FQ_NOAUTH=0                          # 1 = no-auth (isolated testing only — see warning below)
APP_VERSION="latest"                 # pin a release tag, e.g. "v1.2.2-stable"; "latest" is non-deterministic

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

# AUDIT FIX 9: block / and /var paths (upstream warns both are unsafe sources)
if [[ "$SERVE_ROOT" == "/" || "$SERVE_ROOT" == "/var" || "$SERVE_ROOT" == /var/* ]]; then
  echo "  ERROR: SERVE_ROOT must not be '/' or under '/var'." >&2
  exit 1
fi

# ── OS / init preflight ────────────────────────────────────────────────────────
[[ -f /etc/debian_version ]] \
  || { echo "  ERROR: This script supports Debian only." >&2; exit 1; }

command -v systemctl >/dev/null 2>&1 \
  || { echo "  ERROR: systemd is required." >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] \
  || { echo "  ERROR: Run as root." >&2; exit 1; }

# Bootstrap curl before checking for it
if ! command -v curl >/dev/null 2>&1; then
  echo "  curl not found — installing..."
  # AUDIT FIX 4: always update before install; surface errors
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl
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
# AUDIT FIX 2: require binary + config + unit all present to be "installed"
# A partial install (binary exists but config/unit missing) falls through to fresh install
if [[ -x "$INSTALL_BIN" && -f "$CONFIG_FILE" && -f "$SERVICE_FILE" ]]; then
  echo "  [WARN]  ${APP} appears to be already installed."
  echo ""

  read -rp "  Uninstall ${APP}? (y/N): " _uninstall
  if [[ "${_uninstall,,}" =~ ^(y|yes)$ ]]; then
    echo "  Uninstalling ${APP}..."
    systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null || true
    rm -f "$INSTALL_BIN" "$CONFIG_FILE" "$ENV_FILE" "$DB_FILE"
    # AUDIT FIX 8: clarify that service user, config dir, and share dir are kept
    echo ""
    echo "  [OK]    ${APP} app files removed."
    echo "  [NOTE]  The following were intentionally kept:"
    echo "          Service user : ${SERVICE_USER}"
    echo "          Config dir   : ${CONFIG_DIR}  (remove manually if desired)"
    echo "          Share dir    : ${SERVE_ROOT}  (remove manually if desired)"
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
    if systemctl restart "$SERVICE_NAME"; then
      echo "  [OK]    Service restarted"
    else
      echo "  [WARN]  Service restart failed — check: journalctl -u ${SERVICE_NAME}" >&2
    fi
    exit 0
  fi

  echo "  Nothing to do. Exiting."
  exit 0
fi

# ── Warn about partial install state ──────────────────────────────────────────
# AUDIT FIX 2: if binary exists but install is incomplete, warn before proceeding
if [[ -f "$INSTALL_BIN" && ( ! -f "$CONFIG_FILE" || ! -f "$SERVICE_FILE" ) ]]; then
  echo "  [WARN]  A binary exists at ${INSTALL_BIN} but the install appears incomplete."
  echo "          Proceeding with fresh install to complete setup."
  echo ""
fi

# ── Fresh install ──────────────────────────────────────────────────────────────
echo "  ${APP} is not fully installed."
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
    if [[ ${#AP1} -lt 8 ]];      then echo "  Password must be at least 8 characters."; continue; fi
    read -r -s -p "  Verify admin password: " AP2; echo
    if [[ "$AP1" == "$AP2" ]]; then FQ_ADMIN_PASS="$AP1"; break; fi
    echo "  Passwords do not match. Try again."
  done
  echo ""
fi

# ── Dependencies ───────────────────────────────────────────────────────────────
echo "  Updating package index..."
# AUDIT FIX 4: always run apt-get update; add ca-certificates; surface errors
apt-get update -qq
echo "  Installing dependencies..."
apt-get install -y -qq ca-certificates curl ffmpeg acl
echo "  [OK]    Dependencies installed"

# ── Service user ───────────────────────────────────────────────────────────────
if ! id "$SERVICE_USER" &>/dev/null; then
  adduser --system --no-create-home --group "$SERVICE_USER" &>/dev/null
  echo "  [OK]    Service user '${SERVICE_USER}' created"
fi

# ── Suggest users for shared access ───────────────────────────────────────────
# AUDIT FIX 5: show human accounts (UID >= 1000), not just service accounts (100–999)
_noise="nobody"

echo ""
echo "  Human users found on this system (UID >= 1000):"
_found=0
while IFS=: read -r _name _ _uid _; do
  if (( _uid >= 1000 && _uid <= 60000 )); then
    _skip=0
    for _n in $_noise; do [[ "$_name" == "$_n" ]] && _skip=1 && break; done
    if [[ "$_skip" -eq 0 ]]; then
      echo "    - ${_name}"
      _found=1
    fi
  fi
done < /etc/passwd
[[ "$_found" -eq 0 ]] && echo "    (none — you may still enter usernames manually)"

echo ""
read -rp "  Add users to access '${SERVE_ROOT}' (space-separated, or Enter to skip): " _input
SHARE_USERS="${_input:-}"
echo ""

# ── Download binary ────────────────────────────────────────────────────────────
echo "  Downloading ${APP} binary (${APP_VERSION})..."
# AUDIT FIX 7: note — no checksum/signature available from this upstream yet.
# Validate by inspecting the binary's reported version after install.
TMP_BIN="$(mktemp)"
if ! curl -fsSL "$RELEASE_URL" -o "$TMP_BIN"; then
  echo "  ERROR: Download failed" >&2
  rm -f "$TMP_BIN"
  exit 1
fi
chmod +x "$TMP_BIN"
mv -f "$TMP_BIN" "$INSTALL_BIN"
echo "  [OK]    Binary installed"

# Confirm binary is executable and report its version
if "$INSTALL_BIN" --version >/dev/null 2>&1; then
  _ver="$("$INSTALL_BIN" --version 2>/dev/null | head -n1 || true)"
  echo "  [OK]    Binary version: ${_ver:-unknown}"
else
  echo "  [WARN]  Binary installed but --version check failed — verify the download manually"
fi

# ── Directories ────────────────────────────────────────────────────────────────
mkdir -p "$CONFIG_DIR" "$SERVE_ROOT"

chown -R "${SERVICE_USER}:${SERVICE_USER}" "$CONFIG_DIR"
chmod 0750 "$CONFIG_DIR"

# AUDIT FIX 3: 0750 (not 0755) — world-traversal gives unrelated local users
# read access to filenames and metadata even without explicit ACL grants
chown root:"${SERVICE_USER}" "$SERVE_ROOT"
chmod 0750 "$SERVE_ROOT"

# ── ACLs ───────────────────────────────────────────────────────────────────────
setfacl -m "u:${SERVICE_USER}:rwx" "$SERVE_ROOT"
setfacl -d -m "u:${SERVICE_USER}:rwx" "$SERVE_ROOT"
echo "  [OK]    ACL set for '${SERVICE_USER}' on ${SERVE_ROOT}"

for _u in $SHARE_USERS; do
  if id "$_u" &>/dev/null; then
    setfacl -m "u:${_u}:rwx" "$SERVE_ROOT"
    setfacl -d -m "u:${_u}:rwx" "$SERVE_ROOT"
    echo "  [OK]    ACL set for '${_u}' on ${SERVE_ROOT}"
  else
    echo "  [WARN]  User '${_u}' not found — skipping"
  fi
done

# ── Write config ───────────────────────────────────────────────────────────────
# AUDIT FIX 1: add defaultEnabled: true so the source is visible on first login.
# Without this, Quantum starts healthy but the admin sees no source in the UI.
if [[ "$FQ_NOAUTH" -eq 1 ]]; then
  cat > "$CONFIG_FILE" <<EOF
server:
  port: ${APP_PORT}
  database: "${DB_FILE}"
  sources:
    - path: "${SERVE_ROOT}"
      name: "Files"
      config:
        defaultEnabled: true
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
        defaultEnabled: true
        denyByDefault: false
        disableIndexing: false
        indexingIntervalMinutes: 240
auth:
  adminUsername: ${FQ_ADMIN_USER}
  methods:
    password:
      enabled: true
      minLength: 8
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

# AUDIT FIX 4: don't suppress systemctl output — surface failures visibly
systemctl daemon-reload
if systemctl enable --now "$SERVICE_NAME"; then
  echo "  [OK]    Service registered and started"
else
  echo "  ERROR: Failed to enable/start service — check: journalctl -u ${SERVICE_NAME}" >&2
  exit 1
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "  [OK]    ${APP} is running"
echo "    URL   : http://${CT_IP}:${APP_PORT}/"
echo "    Files : ${SERVE_ROOT}"
echo "    Conf  : ${CONFIG_FILE}"
echo "    DB    : ${DB_FILE}"
echo "    Bin   : ${INSTALL_BIN}"
if [[ "$FQ_NOAUTH" -eq 1 ]]; then
  echo "    Auth  : disabled (no-auth mode)"
else
  echo "    Auth  : ${FQ_ADMIN_USER} / (password set at install)"
  echo "    Env   : ${ENV_FILE}"
fi
# AUDIT FIX 6: surface the non-determinism of "latest" so the operator knows to pin
if [[ "$APP_VERSION" == "latest" ]]; then
  echo ""
  echo "  [NOTE]  APP_VERSION=\"latest\" was used. The installed version is shown above."
  echo "          Pin APP_VERSION to that tag in the script for reproducible future installs."
fi
echo ""
