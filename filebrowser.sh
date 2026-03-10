#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
APP="FileBrowser Quantum"
SERVICE_USER="filebrowser"
INSTALL_BIN="/usr/local/bin/filebrowser"
CONFIG_DIR="/opt/filebrowser"
CONFIG_FILE="${CONFIG_DIR}/fq-config.yaml"
CACHE_DIR="${CONFIG_DIR}/cache"
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

# Bootstrap curl before checking for it — it may just need installing
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
    systemctl disable --now "${SERVICE_NAME}.service" &>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload &>/dev/null || true
    rm -f "$INSTALL_BIN" "$CONFIG_FILE" "$DB_FILE"
    rm -rf "$CACHE_DIR"
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
    if ! "$TMP_BIN" version >/dev/null 2>&1; then
      echo "  ERROR: Downloaded binary failed version check — aborting update" >&2
      rm -f "$TMP_BIN"
      exit 1
    fi
    _ver="$("$TMP_BIN" version 2>/dev/null | head -n1 || true)"
    mv -f "$TMP_BIN" "$INSTALL_BIN"
    echo "  [OK]    Binary updated to: ${_ver:-unknown}"
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
    if [[ "$AP1" == *","* ]];    then echo "  Password cannot contain commas."; continue; fi
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
# Show both installed service accounts (UID 100–999) and human accounts (UID 1000+)
# as candidates for share access — e.g. jellyfin, kavita, vaultwarden, or a human login.
# Well-known OS noise is filtered out; the filebrowser service user is excluded (it already
# has direct ACL access set below).
_svc_noise="nobody messagebus systemd-network systemd-resolve systemd-timesync \
            _apt daemon bin sys games man lp mail news uucp proxy www-data \
            backup list irc gnats sshd"

_found=0
_share_candidates=()

while IFS=: read -r _name _ _uid _; do
  # Service accounts: 100–999 (installed apps)
  if (( _uid >= 100 && _uid <= 999 )); then
    [[ "$_name" == "$SERVICE_USER" ]] && continue
    _skip=0
    for _n in $_svc_noise; do [[ "$_name" == "$_n" ]] && _skip=1 && break; done
    [[ "$_skip" -eq 0 ]] && _share_candidates+=("$_name") && _found=1
  # Human accounts: 1000–60000
  elif (( _uid >= 1000 && _uid <= 60000 )); then
    _share_candidates+=("$_name") && _found=1
  fi
done < /etc/passwd

SHARE_USERS=""
if [[ "$_found" -eq 1 ]]; then
  echo ""
  echo "  Users available for share access:"
  for _u in "${_share_candidates[@]}"; do echo "    - ${_u}"; done
  echo ""
  read -rp "  Add users to access '${SERVE_ROOT}' (space-separated, or Enter to skip): " _input
  SHARE_USERS="${_input:-}"
  echo ""
else
  echo "  [NOTE]  No candidate users found — skipping share-access prompt."
  echo "          Add users later with: setfacl -m u:<username>:rwx ${SERVE_ROOT}"
  echo ""
fi

# ── Download binary ────────────────────────────────────────────────────────────
echo "  Downloading ${APP} binary (${APP_VERSION})..."
# No checksum/signature feed available from this upstream yet.
# Validate the download before replacing any live binary.
TMP_BIN="$(mktemp)"
if ! curl -fsSL "$RELEASE_URL" -o "$TMP_BIN"; then
  echo "  ERROR: Download failed" >&2
  rm -f "$TMP_BIN"
  exit 1
fi
chmod +x "$TMP_BIN"

# Validate BEFORE overwriting the live binary — 'version' is the correct subcommand
if ! "$TMP_BIN" version >/dev/null 2>&1; then
  echo "  ERROR: Downloaded binary failed version check — aborting" >&2
  rm -f "$TMP_BIN"
  exit 1
fi
_ver="$("$TMP_BIN" version 2>/dev/null | head -n1 || true)"
echo "  [OK]    Downloaded binary version: ${_ver:-unknown}"

mv -f "$TMP_BIN" "$INSTALL_BIN"
echo "  [OK]    Binary installed"

# ── Directories ────────────────────────────────────────────────────────────────
mkdir -p "$CONFIG_DIR" "$CACHE_DIR" "$SERVE_ROOT"

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
  cacheDir: "${CACHE_DIR}"
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
  cacheDir: "${CACHE_DIR}"
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

# ── Admin password seeding ─────────────────────────────────────────────────────
# Seed the password once via the CLI user-setup flow before the service starts.
# Using FILEBROWSER_ADMIN_PASSWORD via EnvironmentFile would reset the password
# on every service restart, overwriting any UI-based password change. The CLI
# approach writes the credential into the database once and is not re-applied
# on subsequent starts. The service must be stopped during CLI DB operations
# (upstream warns only one process should access the database at a time).
if [[ "$FQ_NOAUTH" -eq 0 ]]; then
  echo "  Seeding admin credentials..."
  # runuser is used instead of sudo — sudo is not guaranteed on minimal Debian/LXC systems.
  # cd into CONFIG_DIR first so the binary's working directory matches WorkingDirectory= in
  # the service unit. Without this, runuser inherits the caller's cwd (e.g. /root) and the
  # binary cannot create its cache directory there.
  # The service is not yet started, satisfying upstream's requirement that only one process
  # accesses the database at a time.
  if ! ( cd "$CONFIG_DIR" && runuser -u "${SERVICE_USER}" -- \
         "${INSTALL_BIN}" set -u "${FQ_ADMIN_USER},${FQ_ADMIN_PASS}" -a -c "${CONFIG_FILE}" ); then
    echo "  ERROR: Failed to seed admin credentials" >&2
    exit 1
  fi
  echo "  [OK]    Admin credentials seeded"
fi

# ── Service registration ───────────────────────────────────────────────────────
echo "  Registering service..."

# No EnvironmentFile in the unit — password was seeded into the DB above.
# Leaving EnvironmentFile with FILEBROWSER_ADMIN_PASSWORD would cause it to be
# reset on every restart, making UI password changes non-persistent.
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
ExecStart=${INSTALL_BIN} -c ${CONFIG_FILE}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

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
echo "    Cache : ${CACHE_DIR}"
echo "    DB    : ${DB_FILE}"
echo "    Bin   : ${INSTALL_BIN}"
if [[ "$FQ_NOAUTH" -eq 1 ]]; then
  echo "    Auth  : disabled (no-auth mode)"
else
  echo "    Auth  : ${FQ_ADMIN_USER} / (password set at install)"
  echo "    Note  : Password is stored in the DB only — changing it in the UI is permanent."
fi
if [[ "$APP_VERSION" == "latest" ]]; then
  echo ""
  echo "  [NOTE]  APP_VERSION=\"latest\" was used. The resolved version is shown above."
  echo "          Pin APP_VERSION to that tag in the script for reproducible future installs."
fi
echo ""
