#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
APP="FileBrowser Quantum"
INSTALL_BIN="/usr/local/bin/filebrowser"
CONFIG_DIR="/opt/filebrowser"
CONFIG_FILE="${CONFIG_DIR}/fq-config.yaml"
SERVICE_NAME="filebrowser"
APP_PORT=8080
SERVE_ROOT="/"
FQ_NOAUTH=0                          # 1 = no-authentication mode, 0 = require login
APP_VERSION="latest"                 # pin a release tag, e.g. "v0.7.0"; "latest" pulls newest

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

# ── OS detection ───────────────────────────────────────────────────────────────
if [[ -f /etc/alpine-release ]]; then
  OS="alpine"
  PKG_MGR="apk add --no-cache"
  SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"
elif [[ -f /etc/debian_version ]]; then
  OS="debian"
  PKG_MGR="apt-get install -y -qq"
  SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
else
  echo "  ERROR: Unsupported OS. Only Alpine and Debian-based systems are supported." >&2
  exit 1
fi

# ── Preflight ──────────────────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }

for cmd in curl ip awk; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

# ── IP resolution ──────────────────────────────────────────────────────────────
IFACE="$(ip -4 route 2>/dev/null | awk '/default/ {print $5; exit}')"
CT_IP="$(ip -4 addr show "${IFACE}" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)"
[[ -z "$CT_IP" ]] && CT_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -z "$CT_IP" ]] && CT_IP="127.0.0.1"

# ── Already installed — offer update or uninstall ──────────────────────────────
if [[ -f "$INSTALL_BIN" ]]; then
  echo "  [WARN]  ${APP} is already installed."
  echo ""

  read -rp "  Uninstall ${APP}? (y/N): " _uninstall
  if [[ "${_uninstall,,}" =~ ^(y|yes)$ ]]; then
    echo "  Uninstalling ${APP}..."
    if [[ "$OS" == "debian" ]]; then
      systemctl disable --now "${SERVICE_NAME}.service" &>/dev/null || true
      rm -f "$SERVICE_FILE"
      systemctl daemon-reload &>/dev/null || true
    else
      rc-service "$SERVICE_NAME" stop &>/dev/null || true
      rc-update del "$SERVICE_NAME" &>/dev/null || true
      rm -f "$SERVICE_FILE"
    fi
    rm -f "$INSTALL_BIN" "$CONFIG_FILE"
    echo "  [OK]    ${APP} uninstalled"
    exit 0
  fi

  read -rp "  Update ${APP} to latest release? (y/N): " _update
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
    echo "  [OK]    ${APP} updated"
    exit 0
  fi

  echo "  Nothing to do. Exiting."
  exit 0
fi

# ── Fresh install ──────────────────────────────────────────────────────────────
echo "  ${APP} is not installed."
echo ""

read -rp "  Install ${APP}? (y/N): " _install
if ! [[ "${_install,,}" =~ ^(y|yes)$ ]]; then
  echo "  Installation skipped. Exiting."
  exit 0
fi

# ── Admin credentials ──────────────────────────────────────────────────────────
FQ_ADMIN_USER="admin"
FQ_ADMIN_PASS=""
if [[ "$FQ_NOAUTH" -eq 0 ]]; then
  while true; do
    read -r -s -p "  Set FileBrowser admin password: " AP1; echo
    if [[ -z "$AP1" ]]; then echo "  Password cannot be blank."; continue; fi
    if [[ "$AP1" == *" "* ]]; then echo "  Password cannot contain spaces."; continue; fi
    if [[ ${#AP1} -lt 5 ]]; then echo "  Password must be at least 5 characters."; continue; fi
    if [[ "$AP1" =~ [:\#\"\''\`\<\>\{\}\|\\] ]]; then
      echo "  Password cannot contain: : # \" ' \` < > { } | \\"
      continue
    fi
    read -r -s -p "  Verify admin password: " AP2; echo
    if [[ "$AP1" == "$AP2" ]]; then FQ_ADMIN_PASS="$AP1"; break; fi
    echo "  Passwords do not match. Try again."
  done
  echo ""
fi

# ── Dependencies ───────────────────────────────────────────────────────────────
echo "  Installing dependencies..."
${PKG_MGR} curl ffmpeg &>/dev/null
echo "  [OK]    Dependencies installed"

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

# ── Config directory ───────────────────────────────────────────────────────────
mkdir -p "$CONFIG_DIR"
chmod 0755 "$CONFIG_DIR"

# ── Write config ───────────────────────────────────────────────────────────────
if [[ "$FQ_NOAUTH" -eq 1 ]]; then
  cat > "$CONFIG_FILE" <<EOF
server:
  port: ${APP_PORT}
  sources:
    - path: "${SERVE_ROOT}"
      name: "RootFS"
      config:
        denyByDefault: false
        disableIndexing: false
        indexingIntervalMinutes: 240
        conditionals:
          rules:
            - neverWatchPath: "/proc"
            - neverWatchPath: "/sys"
            - neverWatchPath: "/dev"
            - neverWatchPath: "/run"
            - neverWatchPath: "/tmp"
            - neverWatchPath: "/lost+found"
auth:
  methods:
    noauth: true
EOF
  echo "  [OK]    Configured — no authentication"
else
  cat > "$CONFIG_FILE" <<EOF
server:
  port: ${APP_PORT}
  sources:
    - path: "${SERVE_ROOT}"
      name: "RootFS"
      config:
        denyByDefault: false
        disableIndexing: false
        indexingIntervalMinutes: 240
        conditionals:
          rules:
            - neverWatchPath: "/proc"
            - neverWatchPath: "/sys"
            - neverWatchPath: "/dev"
            - neverWatchPath: "/run"
            - neverWatchPath: "/tmp"
            - neverWatchPath: "/lost+found"
auth:
  adminUsername: ${FQ_ADMIN_USER}
  adminPassword: ${FQ_ADMIN_PASS}
EOF
  chmod 0600 "$CONFIG_FILE"
  echo "  [OK]    Configured — auth enabled (user: ${FQ_ADMIN_USER})"
fi

# ── Service registration ───────────────────────────────────────────────────────
echo "  Registering service..."
if [[ "$OS" == "debian" ]]; then
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=${APP}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${CONFIG_DIR}
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
else
  cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run
command="${INSTALL_BIN}"
command_args="-c ${CONFIG_FILE}"
command_background=true
directory="${CONFIG_DIR}"
pidfile="${CONFIG_DIR}/${SERVICE_NAME}.pid"

depend() {
  need net
}
EOF
  chmod +x "$SERVICE_FILE"
  rc-update add "$SERVICE_NAME" default &>/dev/null
  rc-service "$SERVICE_NAME" start &>/dev/null
fi
echo "  [OK]    Service registered and started"

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "  [OK]    ${APP} is running"
echo "    URL  : http://${CT_IP}:${APP_PORT}/"
echo "    Conf : ${CONFIG_FILE}"
echo "    Bin  : ${INSTALL_BIN}"
if [[ "$FQ_NOAUTH" -eq 1 ]]; then
  echo "    Auth : disabled"
else
  echo "    Auth : ${FQ_ADMIN_USER} / (password set at install)"
fi
echo ""
