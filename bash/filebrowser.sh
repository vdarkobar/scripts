#!/usr/bin/env bash
set -Eeo pipefail

# FileBrowser Quantum — native installer / updater / repair / uninstall
#
# Targets: Debian 12/13 on bare metal, VM, Proxmox VE host (opt-in), LXC.
# Model  : re-run the script to update (bump APP_VERSION), repair or uninstall.
#          Config and database are never overwritten by repair; the unit and
#          the hardening drop-in are script-owned and always rewritten.
# Uninstall: removes service, binary, CONFIG_DIR, user+group; keeps SERVE_ROOT.
# Backup : none in-script. Take a PBS/PVE snapshot (CT/VM) or your own backup
#          (bare metal / PVE host) before updating.

# ── Config ─────────────────────────────────────────────────────────────────────
APP="FileBrowser Quantum"
APP_VERSION="v1.5.5-stable"          # v1.x.y-stable only — v2 changes DB and config, needs a migration path
APP_SHA256=""                        # optional expected sha256 of the downloaded binary; "" = skip check

SERVICE_USER="filebrowser"
SERVICE_NAME="filebrowser"
INSTALL_BIN="/usr/local/bin/filebrowser"
CONFIG_DIR="/opt/filebrowser"
CONFIG_FILE="${CONFIG_DIR}/fq-config.yaml"
CACHE_DIR="${CONFIG_DIR}/cache"
DB_FILE="${CONFIG_DIR}/database.db"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
DROPIN_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
HARDENING_FILE="${DROPIN_DIR}/10-hardening.conf"

APP_PORT=8080
SERVE_ROOT="/srv/files"              # dedicated directory or mount point; never / or /var paths
FQ_NOAUTH=0                          # 1 = no authentication (isolated networks only)
INSTALL_FFMPEG=1                     # 0 = skip ffmpeg (video thumbnails); consider 0 on a PVE host
ALLOW_PVE_HOST=0                     # 1 = permit installing directly on a Proxmox VE host

HEALTH_TIMEOUT=30                    # seconds to wait for /health after (re)start
LOCK_FILE="/run/lock/filebrowser-install.lock"
GITHUB_REPO="gtsteffaniak/filebrowser"

# ── Config validation ──────────────────────────────────────────────────────────
[[ "$APP_VERSION" =~ ^v1\.[0-9]+\.[0-9]+-stable$ ]] \
  || { echo "  ERROR: APP_VERSION must be a v1.x.y-stable tag (got '${APP_VERSION}')." >&2
       echo "         v2 uses SQLite and a different config layout; it needs a migration path, not this script." >&2; exit 1; }

[[ "$APP_SHA256" =~ ^([0-9a-f]{64})?$ ]] \
  || { echo "  ERROR: APP_SHA256 must be empty or 64 lowercase hex characters." >&2; exit 1; }

for _flag in FQ_NOAUTH INSTALL_FFMPEG ALLOW_PVE_HOST; do
  [[ "${!_flag}" =~ ^[01]$ ]] || { echo "  ERROR: ${_flag} must be 0 or 1." >&2; exit 1; }
done

[[ "$APP_PORT" =~ ^[0-9]+$ ]] && (( APP_PORT >= 1 && APP_PORT <= 65535 )) \
  || { echo "  ERROR: APP_PORT must be 1–65535." >&2; exit 1; }

[[ "$HEALTH_TIMEOUT" =~ ^[0-9]+$ ]] && (( HEALTH_TIMEOUT >= 5 )) \
  || { echo "  ERROR: HEALTH_TIMEOUT must be an integer >= 5." >&2; exit 1; }

# SERVE_ROOT: absolute, canonical, not a symlink, not a sensitive system path
[[ "$SERVE_ROOT" == /* ]] \
  || { echo "  ERROR: SERVE_ROOT must be an absolute path." >&2; exit 1; }
_resolved="$(realpath -m -- "$SERVE_ROOT")"
[[ "$_resolved" == "$SERVE_ROOT" ]] \
  || { echo "  ERROR: SERVE_ROOT '${SERVE_ROOT}' resolves to '${_resolved}' — use the canonical path, no '..' or symlinks." >&2; exit 1; }
[[ -L "$SERVE_ROOT" ]] \
  && { echo "  ERROR: SERVE_ROOT must not be a symlink." >&2; exit 1; }
for _bad in / /bin /boot /dev /etc /lib /lib64 /proc /root /run /sbin /sys /usr /var; do
  if [[ "$SERVE_ROOT" == "$_bad" || "$SERVE_ROOT" == "${_bad}/"* ]]; then
    echo "  ERROR: SERVE_ROOT must not be '${_bad}' or below it." >&2; exit 1
  fi
done
[[ "$SERVE_ROOT" == "$CONFIG_DIR" || "$SERVE_ROOT" == "${CONFIG_DIR}/"* ]] \
  && { echo "  ERROR: SERVE_ROOT must not be inside CONFIG_DIR." >&2; exit 1; }

# CONFIG_DIR is removed wholesale on uninstall — keep it a dedicated, nested, canonical path
[[ "$CONFIG_DIR" == /*/* && "$CONFIG_DIR" != */ && "$CONFIG_DIR" == "$(realpath -m -- "$CONFIG_DIR")" ]] \
  || { echo "  ERROR: CONFIG_DIR must be a canonical path at least two levels deep (e.g. /opt/filebrowser)." >&2; exit 1; }
for _bad in /bin /boot /dev /etc /home /lib /lib64 /proc /root /run /sbin /srv /sys /usr /var; do
  [[ "$CONFIG_DIR" == "${_bad}/"* ]] \
    && { echo "  ERROR: CONFIG_DIR must not be below '${_bad}'." >&2; exit 1; }
done

# ── Trap cleanup ───────────────────────────────────────────────────────────────
TMP_FILES=()
_cleanup() { local f; for f in "${TMP_FILES[@]:-}"; do [[ -n "$f" ]] && rm -f -- "$f"; done; return 0; }
trap 'rc=$?; trap - ERR; echo "  ERROR: line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" >&2; _cleanup; exit "$rc"' ERR
trap 'trap - INT TERM; echo; echo "  Interrupted." >&2; _cleanup; exit 130' INT TERM

# ── Preflight — root, tty, lock, commands ──────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }
[[ -t 0 ]]             || { echo "  ERROR: This script is interactive; run it from a terminal." >&2; exit 1; }

mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "  ERROR: Another instance is running (${LOCK_FILE})." >&2; exit 1; }

for _cmd in systemctl journalctl awk install realpath mountpoint sha256sum unshare runuser setpriv flock ss dpkg; do
  command -v "$_cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: ${_cmd}" >&2; exit 1; }
done

if ! command -v curl >/dev/null 2>&1; then
  echo "  curl not found — installing..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl
fi
command -v curl >/dev/null 2>&1 || { echo "  ERROR: curl could not be installed." >&2; exit 1; }

# ── Preflight — OS, environment, architecture ──────────────────────────────────
[[ -r /etc/os-release ]] || { echo "  ERROR: /etc/os-release not found." >&2; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "debian" ]] \
  || { echo "  ERROR: Debian only (detected ID='${ID:-unknown}')." >&2; exit 1; }

OS_LABEL="Debian ${VERSION_ID:-?}"
case "${VERSION_ID:-}" in
  12|13) ;;
  *) echo "  [WARN]  Untested Debian release '${VERSION_ID:-unknown}' — only 12 and 13 are tested."
     read -rp "  Continue anyway? (y/N): " _os_ok
     [[ "${_os_ok,,}" =~ ^(y|yes)$ ]] || { echo "  Aborted."; exit 0; } ;;
esac

IS_PVE_HOST=0
if [[ -d /etc/pve ]] || command -v pveversion >/dev/null 2>&1; then IS_PVE_HOST=1; fi

ENV_KIND="bare metal / VM"
_virt="$(systemd-detect-virt 2>/dev/null || true)"
if [[ "$_virt" == "lxc" ]]; then
  if awk 'NR==1 && $1==0 && $2==0 {found=1} END {exit !found}' /proc/1/uid_map 2>/dev/null; then
    ENV_KIND="privileged LXC"
  else
    ENV_KIND="unprivileged LXC"
  fi
elif [[ "$IS_PVE_HOST" -eq 1 ]]; then
  ENV_KIND="Proxmox VE host"
fi

if [[ "$IS_PVE_HOST" -eq 1 && "$ALLOW_PVE_HOST" -ne 1 ]]; then
  echo "  ERROR: This is a Proxmox VE host. Set ALLOW_PVE_HOST=1 to install here (a file manager on the" >&2
  echo "         hypervisor is rarely what you want — an LXC is the usual place)." >&2
  exit 1
fi

case "$(dpkg --print-architecture)" in
  amd64) ARCH="amd64" ;;
  arm64) ARCH="arm64" ;;
  *)     echo "  ERROR: Unsupported architecture '$(dpkg --print-architecture)' (amd64/arm64 only)." >&2; exit 1 ;;
esac
RELEASE_URL="https://github.com/${GITHUB_REPO}/releases/download/${APP_VERSION}/linux-${ARCH}-filebrowser"

# Mount-namespace probe: mirrors what ProtectSystem= / PrivateTmp= need.
# Fails on unprivileged LXC without nesting=1.
NS_HARDENING=0
if unshare -m -- sh -c 'mount --bind /usr /usr && mount -o remount,bind,ro /usr' >/dev/null 2>&1; then
  NS_HARDENING=1
fi

# ── IP resolution (best-effort — summary only) ─────────────────────────────────
CT_IP=""
if command -v ip >/dev/null 2>&1; then
  IFACE="$(ip -4 route 2>/dev/null | awk '/^default/ {print $5; exit}' || true)"
  if [[ -n "$IFACE" ]]; then
    CT_IP="$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2; exit}' | cut -d/ -f1 || true)"
  fi
fi
[[ -z "$CT_IP" ]] && CT_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
[[ -z "$CT_IP" ]] && CT_IP="127.0.0.1"

# ── Helpers (small, used from several phases) ──────────────────────────────────
_installed_version() {
  # prints e.g. 1.5.5-stable, or nothing if unknown
  [[ -x "$INSTALL_BIN" ]] || return 0
  runuser -u "$SERVICE_USER" -- "$INSTALL_BIN" version 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[a-z]+' | head -n1 || true
}

_wait_healthy() {
  # 0 = /health answers, service active, no automatic restarts since last start
  local i
  for (( i = 0; i < HEALTH_TIMEOUT; i++ )); do
    if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:${APP_PORT}/health" 2>/dev/null \
       && systemctl is-active --quiet "$SERVICE_NAME" \
       && [[ "$(systemctl show -p NRestarts --value "$SERVICE_NAME")" == "0" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

_show_journal() { journalctl -u "$SERVICE_NAME" -n 25 --no-pager 2>/dev/null | sed 's/^/          /' || true; }

_download_binary() {
  # downloads + verifies into ${INSTALL_BIN}.new (mode 0755 root:root); caller moves it into place
  local _new="${INSTALL_BIN}.new" _tmp _sum
  _tmp="$(mktemp -p "$(dirname "$INSTALL_BIN")" .filebrowser.dl.XXXXXX)"
  TMP_FILES+=("$_tmp" "$_new")
  echo "  Downloading ${APP} ${APP_VERSION} (linux-${ARCH})..."
  curl -fsSL --proto '=https' --retry 3 --retry-delay 3 --connect-timeout 15 --max-time 300 \
       -o "$_tmp" "$RELEASE_URL" \
    || { echo "  ERROR: Download failed: ${RELEASE_URL}" >&2; return 1; }
  if [[ -n "$APP_SHA256" ]]; then
    _sum="$(sha256sum "$_tmp" | awk '{print $1}')"
    [[ "$_sum" == "$APP_SHA256" ]] \
      || { echo "  ERROR: sha256 mismatch: got ${_sum}, expected ${APP_SHA256}" >&2; return 1; }
    echo "  [OK]    sha256 verified"
  fi
  install -m 0755 -o root -g root "$_tmp" "$_new"
  rm -f "$_tmp"
  # run the version check unprivileged, never as root
  local _out _ver
  _out="$(runuser -u "$SERVICE_USER" -- "$_new" version 2>/dev/null || true)"
  [[ -n "$_out" ]] \
    || { echo "  ERROR: Downloaded binary failed 'version' check." >&2; return 1; }
  # 'version' prints a banner first; the tag is on a later line
  _ver="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[a-z]+' <<<"$_out" | head -n1 || true)"
  [[ "$_ver" == "${APP_VERSION#v}" ]] \
    || { echo "  ERROR: Binary reports '${_ver:-unknown}', expected ${APP_VERSION#v}." >&2
         sed 's/^/          /' <<<"$_out" >&2; return 1; }
  echo "  [OK]    Binary verified: ${_ver}"
}

_write_units() {
  # unit + hardening drop-in are script-owned and always rewritten
  local _tmp _caps="" _amb="" _home="ProtectHome=true"
  if (( APP_PORT < 1024 )); then
    _caps="CAP_NET_BIND_SERVICE"; _amb="CAP_NET_BIND_SERVICE"
  fi
  case "$SERVE_ROOT" in /home|/home/*|/root|/root/*) _home="" ;; esac

  _tmp="$(mktemp)"; TMP_FILES+=("$_tmp")
  cat > "$_tmp" <<EOF
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
UMask=0027
NoNewPrivileges=true
CapabilityBoundingSet=${_caps}
AmbientCapabilities=${_amb}
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictNamespaces=true
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF
  install -m 0644 -o root -g root "$_tmp" "$SERVICE_FILE"
  rm -f "$_tmp"

  if [[ "$NS_HARDENING" -eq 1 ]]; then
    mkdir -p "$DROPIN_DIR"
    _tmp="$(mktemp)"; TMP_FILES+=("$_tmp")
    cat > "$_tmp" <<EOF
# Managed by filebrowser.sh — requires mount namespaces (nesting=1 on unprivileged LXC).
[Service]
ProtectSystem=strict
${_home}
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ReadWritePaths=${CONFIG_DIR} ${SERVE_ROOT}
EOF
    install -m 0644 -o root -g root "$_tmp" "$HARDENING_FILE"
    rm -f "$_tmp"
  else
    rm -f "$HARDENING_FILE"
    rmdir "$DROPIN_DIR" 2>/dev/null || true
  fi
  systemctl daemon-reload
}

_start_and_verify() {
  # enable+start, health check; if the namespace drop-in is the cause, drop it and retry once
  systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  if _wait_healthy; then return 0; fi
  if [[ -f "$HARDENING_FILE" ]] \
     && journalctl -u "$SERVICE_NAME" -n 30 --no-pager 2>/dev/null | grep -qiE 'namespac|NAMESPACE'; then
    echo "  [WARN]  Service failed on mount-namespace hardening — removing drop-in and retrying."
    NS_HARDENING=0
    rm -f "$HARDENING_FILE"; rmdir "$DROPIN_DIR" 2>/dev/null || true
    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
    if _wait_healthy; then return 0; fi
  fi
  return 1
}

# ── Detect current state ───────────────────────────────────────────────────────
_has_bin=0;  [[ -f "$INSTALL_BIN"  ]] && _has_bin=1
_has_cfg=0;  [[ -f "$CONFIG_FILE"  ]] && _has_cfg=1
_has_db=0;   [[ -f "$DB_FILE"      ]] && _has_db=1
_has_unit=0; [[ -f "$SERVICE_FILE" ]] && _has_unit=1
_has_user=0; id "$SERVICE_USER" &>/dev/null && _has_user=1

_present=$(( _has_bin + _has_cfg + _has_db + _has_unit ))
_complete=0; (( _has_bin && _has_cfg && _has_unit && (_has_db || FQ_NOAUTH) )) && _complete=1

INSTALLED_VER=""
if (( _has_bin && _has_user )); then INSTALLED_VER="$(_installed_version)"; fi

_p() { [[ "$1" -eq 1 ]] && echo present || echo missing; }

echo ""
echo "  ${APP} installer"
echo "  Environment : ${ENV_KIND}, ${OS_LABEL}, ${ARCH}"
echo "  Hardening   : $([[ "$NS_HARDENING" -eq 1 ]] && echo 'full (mount namespaces available)' || echo 'basic (no mount namespaces — enable nesting on the CT for full)')"
echo ""

ACTION="install"
if (( _present > 0 )); then
  echo "  Existing state:"
  echo "    Binary  : $(_p "$_has_bin")  ${INSTALLED_VER:+(${INSTALLED_VER})}"
  echo "    Config  : $(_p "$_has_cfg")"
  echo "    Database: $(_p "$_has_db")"
  echo "    Unit    : $(_p "$_has_unit")  $( (( _has_unit )) && echo "enabled=$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true) active=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)")"
  echo ""
  if (( _complete )); then
    echo "  Actions: [u] update to ${APP_VERSION}   [r] repair (rewrite unit, recreate missing pieces)"
    echo "           [x] uninstall                 [a] abort"
    read -rp "  Choice (u/r/x/A): " _choice
    case "${_choice,,}" in
      u) ACTION="update" ;;
      r) ACTION="repair" ;;
      x) ACTION="uninstall" ;;
      *) echo "  Aborted."; exit 0 ;;
    esac
  else
    echo "  [WARN]  Partial installation detected."
    echo "  Actions: [r] repair (recreate missing pieces, keep existing config/database)"
    echo "           [x] uninstall                 [a] abort"
    read -rp "  Choice (r/x/A): " _choice
    case "${_choice,,}" in
      r) ACTION="repair" ;;
      x) ACTION="uninstall" ;;
      *) echo "  Aborted."; exit 0 ;;
    esac
  fi
fi

# ── Uninstall ──────────────────────────────────────────────────────────────────
if [[ "$ACTION" == "uninstall" ]]; then
  echo ""
  echo "  This removes ${APP} completely:"
  echo "    - service unit, hardening drop-in, binary"
  echo "    - ${CONFIG_DIR} (config, database, cache — all users, shares, tokens, settings)"
  echo "    - user and group '${SERVICE_USER}'"
  echo "    - '${SERVICE_USER}' ACL entries in ${SERVE_ROOT}; files it created there -> root:root"
  echo "  Kept: ${SERVE_ROOT} and its contents (ownership reset to root:root if it is still"
  echo "        root:${SERVICE_USER}), ACLs of other users, installed packages."
  echo "  Not recoverable without a backup."
  read -rp "  Type REMOVE to confirm, anything else to abort: " _g1
  [[ "$_g1" == "REMOVE" ]] || { echo "  Aborted."; exit 0; }

  if systemctl is-active --quiet "$SERVICE_NAME"; then
    systemctl stop "$SERVICE_NAME" \
      || { echo "  ERROR: Could not stop ${SERVICE_NAME} — nothing removed." >&2; _show_journal; exit 1; }
  fi
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$HARDENING_FILE"
  rmdir "$DROPIN_DIR" 2>/dev/null || true
  systemctl daemon-reload
  systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$INSTALL_BIN" "${INSTALL_BIN}.new" "${INSTALL_BIN}.prev"
  echo "  [OK]    Service and binary removed"

  rm -rf -- "$CONFIG_DIR"
  echo "  [OK]    ${CONFIG_DIR} removed"

  if [[ -d "$SERVE_ROOT" ]] && command -v setfacl >/dev/null 2>&1; then
    # strip the service user's ACL entries from the whole tree (default entries apply to dirs only)
    setfacl -R -x "u:${SERVICE_USER}" -d -x "u:${SERVICE_USER}" "$SERVE_ROOT" 2>/dev/null || true
    # files/dirs the service created inside the share → root:root (only those, other owners untouched)
    if id "$SERVICE_USER" &>/dev/null; then
      find "$SERVE_ROOT" -xdev -user  "$SERVICE_USER" -exec chown -h root {} + 2>/dev/null || true
      find "$SERVE_ROOT" -xdev -group "$SERVICE_USER" -exec chgrp -h root {} + 2>/dev/null || true
    fi
    # no other named ACL entries left on the share root → drop mask/default skeleton so '+' disappears
    if ! getfacl -p --omit-header "$SERVE_ROOT" 2>/dev/null | grep -qE '^(default:)?(user|group):[^:]+:'; then
      setfacl -R -b -k "$SERVE_ROOT" 2>/dev/null || true
      echo "  [OK]    ${SERVE_ROOT} kept, ACL remnants removed"
    else
      echo "  [OK]    ${SERVE_ROOT} kept, other users' ACLs retained"
    fi
    if [[ "$(stat -c %U:%G "$SERVE_ROOT")" == "root:${SERVICE_USER}" ]]; then
      chown root:root "$SERVE_ROOT"
      echo "  [OK]    ${SERVE_ROOT} ownership reset to root:root"
    else
      echo "  [OK]    ${SERVE_ROOT} ownership left as $(stat -c %U:%G "$SERVE_ROOT")"
    fi
  fi

  if id "$SERVICE_USER" &>/dev/null; then
    pkill -KILL -u "$SERVICE_USER" 2>/dev/null || true
    deluser --system "$SERVICE_USER" >/dev/null 2>&1 \
      || echo "  [WARN]  Could not remove user '${SERVICE_USER}' — remove manually: deluser --system ${SERVICE_USER}" >&2
  fi
  if getent group "$SERVICE_USER" >/dev/null; then
    delgroup --system --only-if-empty "$SERVICE_USER" >/dev/null 2>&1 \
      || echo "  [WARN]  Could not remove group '${SERVICE_USER}' — remove manually: delgroup ${SERVICE_USER}" >&2
  fi
  echo "  [OK]    User and group '${SERVICE_USER}' removed"
  echo ""
  echo "  [NOTE]  Packages (acl, ffmpeg, curl, ca-certificates) were left installed."
  exit 0
fi

# ── Update ─────────────────────────────────────────────────────────────────────
if [[ "$ACTION" == "update" ]]; then
  echo ""
  _want="${APP_VERSION#v}"
  if [[ -z "$INSTALLED_VER" ]]; then
    echo "  [WARN]  Installed version could not be determined."
  elif [[ "$INSTALLED_VER" == "$_want" ]]; then
    echo "  [OK]    Already at ${APP_VERSION} — nothing to update (use repair to rewrite the unit)."
    exit 0
  elif [[ "${INSTALLED_VER%%.*}" != "${_want%%.*}" ]]; then
    echo "  ERROR: Major version change ${INSTALLED_VER} -> ${_want} is not a binary swap." >&2
    echo "         v1 -> v2 requires stopping the service, backing up the database and running the" >&2
    echo "         upstream migration. This script does not do that." >&2
    exit 1
  fi
  echo "  Update ${INSTALLED_VER:-unknown} -> ${_want}"
  echo "  Take a snapshot/backup first (PBS or PVE snapshot for CT/VM; your own backup on bare metal)."
  read -rp "  Proceed with update? (y/N): " _upd
  [[ "${_upd,,}" =~ ^(y|yes)$ ]] || { echo "  Aborted."; exit 0; }

  _download_binary

  mv -f "$INSTALL_BIN" "${INSTALL_BIN}.prev"
  mv -f "${INSTALL_BIN}.new" "$INSTALL_BIN"
  _write_units
  systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true

  if _start_and_verify; then
    rm -f "${INSTALL_BIN}.prev"
    echo "  [OK]    ${APP} updated to $(_installed_version) and healthy."
    echo "    URL   : http://${CT_IP}:${APP_PORT}/"
    exit 0
  fi

  echo "  ERROR: Service unhealthy after update — rolling back binary." >&2
  _show_journal
  mv -f "${INSTALL_BIN}.prev" "$INSTALL_BIN"
  systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
  if _wait_healthy; then
    echo "  [OK]    Rollback to ${INSTALLED_VER:-previous} succeeded." >&2
  else
    echo "  ERROR: Rollback also unhealthy — check: journalctl -u ${SERVICE_NAME}" >&2
  fi
  exit 1
fi

# ── Install / repair — confirm ─────────────────────────────────────────────────
# From here on: create whatever is missing, never overwrite config or DB.
echo ""
if [[ "$ACTION" == "install" ]]; then
  echo "  ${APP} ${APP_VERSION} will be installed:"
else
  echo "  Repair will:"
fi
(( _has_bin ))  || echo "    - download binary -> ${INSTALL_BIN}"
(( _has_user )) || echo "    - create service user '${SERVICE_USER}'"
(( _has_cfg ))  || echo "    - write config -> ${CONFIG_FILE}"
if (( ! _has_db && ! FQ_NOAUTH )); then echo "    - create database and seed admin user"; fi
echo "    - (re)write ${SERVICE_FILE}$([[ "$NS_HARDENING" -eq 1 ]] && echo " + hardening drop-in")"
echo "    - grant '${SERVICE_USER}' access to ${SERVE_ROOT} via ACL"
[[ "$IS_PVE_HOST" -eq 1 ]] && echo "    [WARN] installing directly on the Proxmox VE host (ALLOW_PVE_HOST=1)"

if [[ "$FQ_NOAUTH" -eq 1 && ! "$_has_cfg" -eq 1 ]]; then
  echo ""
  echo "  [WARN]  FQ_NOAUTH=1 — no authentication. The service listens on all interfaces;"
  echo "          upstream recommends this only for isolated/controlled networks."
  read -rp "  Confirm no-auth install? (y/N): " _noauth_ok
  [[ "${_noauth_ok,,}" =~ ^(y|yes)$ ]] || { echo "  Aborted. Set FQ_NOAUTH=0 to use authentication."; exit 0; }
fi

echo ""
read -rp "  Proceed? (y/N): " _go
[[ "${_go,,}" =~ ^(y|yes)$ ]] || { echo "  Aborted."; exit 0; }

# ── Port conflict check (only when our service is not the listener) ───────────
if ! systemctl is-active --quiet "$SERVICE_NAME"; then
  if ss -ltnH "sport = :${APP_PORT}" 2>/dev/null | grep -q .; then
    echo "  ERROR: Port ${APP_PORT} is already in use:" >&2
    ss -ltnpH "sport = :${APP_PORT}" 2>/dev/null | sed 's/^/          /' >&2 || true
    exit 1
  fi
fi

# ── Admin credentials (only when a database must be created) ──────────────────
FQ_ADMIN_USER="admin"
FQ_ADMIN_PASS=""
NEED_SEED=0
if (( ! _has_db && ! FQ_NOAUTH )); then
  NEED_SEED=1
  echo ""
  echo "  Password restrictions: min 8 characters, no spaces or commas"
  while true; do
    read -r -s -p "  Set ${APP} admin password: " AP1; echo
    if [[ -z "$AP1" ]];          then echo "  Password cannot be blank.";             continue; fi
    if [[ "$AP1" == *" "* ]];    then echo "  Password cannot contain spaces.";       continue; fi
    if [[ "$AP1" == *","* ]];    then echo "  Password cannot contain commas.";       continue; fi
    if [[ ${#AP1} -lt 8 ]];      then echo "  Password must be at least 8 characters."; continue; fi
    read -r -s -p "  Verify admin password: " AP2; echo
    if [[ "$AP1" == "$AP2" ]]; then FQ_ADMIN_PASS="$AP1"; break; fi
    echo "  Passwords do not match — please re-enter both."
  done
  unset AP1 AP2
fi

# ── Dependencies ───────────────────────────────────────────────────────────────
echo ""
echo "  Installing dependencies..."
_pkgs=(ca-certificates curl acl)
[[ "$INSTALL_FFMPEG" -eq 1 ]] && _pkgs+=(ffmpeg)
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${_pkgs[@]}"
echo "  [OK]    Dependencies installed (${_pkgs[*]})"

# ── Service user ───────────────────────────────────────────────────────────────
if ! id "$SERVICE_USER" &>/dev/null; then
  adduser --system --no-create-home --group --home "$CONFIG_DIR" --shell /usr/sbin/nologin "$SERVICE_USER" >/dev/null
  echo "  [OK]    Service user '${SERVICE_USER}' created"
fi

# ── Binary ─────────────────────────────────────────────────────────────────────
if [[ ! -f "$INSTALL_BIN" ]]; then
  _download_binary
  mv -f "${INSTALL_BIN}.new" "$INSTALL_BIN"
  echo "  [OK]    Binary installed: ${INSTALL_BIN}"
else
  chmod 0755 "$INSTALL_BIN"; chown root:root "$INSTALL_BIN"
  echo "  [OK]    Binary present ($(_installed_version || echo unknown)) — not replaced (use update)"
fi

# ── Config directory ───────────────────────────────────────────────────────────
mkdir -p "$CONFIG_DIR" "$CACHE_DIR"
chown -R "${SERVICE_USER}:${SERVICE_USER}" "$CONFIG_DIR"
chmod 0750 "$CONFIG_DIR"

# ── Share directory — never touch an existing directory's owner/mode ──────────
SERVE_ROOT_CREATED=0
if [[ ! -e "$SERVE_ROOT" ]]; then
  mkdir -p "$SERVE_ROOT"
  chown "root:${SERVICE_USER}" "$SERVE_ROOT"
  chmod 0750 "$SERVE_ROOT"      # 0750: no world traversal for unrelated local users
  SERVE_ROOT_CREATED=1
  echo "  [OK]    Created ${SERVE_ROOT} (root:${SERVICE_USER} 0750)"
elif [[ ! -d "$SERVE_ROOT" ]]; then
  echo "  ERROR: ${SERVE_ROOT} exists but is not a directory." >&2; exit 1
else
  echo "  [NOTE]  ${SERVE_ROOT} already exists — owner/mode left unchanged:"
  echo "          $(stat -c '%U:%G %a' "$SERVE_ROOT")$(mountpoint -q "$SERVE_ROOT" && echo '  (mount point)')"
fi

# ACL preflight in a scratch subdir (ZFS acltype=off, some NFS/FUSE mounts reject ACLs)
_acltest="$(mktemp -d -p "$SERVE_ROOT" .acltest.XXXXXX)"
if ! setfacl -m "u:${SERVICE_USER}:rwx" "$_acltest" 2>/dev/null; then
  rm -rf "$_acltest"
  echo "  ERROR: POSIX ACLs are not supported on ${SERVE_ROOT}." >&2
  echo "         ZFS: 'zfs set acltype=posixacl xattr=sa <dataset>' on the host, then re-run." >&2
  exit 1
fi
rm -rf "$_acltest"

# ── Share access users ─────────────────────────────────────────────────────────
_svc_noise=" nobody messagebus systemd-network systemd-resolve systemd-timesync _apt daemon bin sys games man lp mail news uucp proxy www-data backup list irc gnats sshd _chrony tss "
_share_candidates=()
while IFS=: read -r _name _ _uid _; do
  [[ "$_name" == "$SERVICE_USER" ]] && continue
  if (( _uid >= 100 && _uid <= 999 )); then
    [[ "$_svc_noise" == *" ${_name} "* ]] && continue
    _share_candidates+=("$_name")
  elif (( _uid >= 1000 && _uid <= 60000 )); then
    _share_candidates+=("$_name")
  fi
done < /etc/passwd

SHARE_USERS=""
if (( ${#_share_candidates[@]} > 0 )); then
  echo ""
  echo "  Local users that could be granted access to ${SERVE_ROOT}:"
  printf '    - %s\n' "${_share_candidates[@]}"
  read -rp "  Users to grant rwx via ACL (space-separated, Enter to skip): " _input
  SHARE_USERS="${_input:-}"
else
  echo "  [NOTE]  No candidate users — grant later with: setfacl -m u:<user>:rwx -d -m u:<user>:rwx ${SERVE_ROOT}"
fi

# ── ACLs ───────────────────────────────────────────────────────────────────────
_apply_acl=1
if (( ! SERVE_ROOT_CREATED )); then
  echo ""
  read -rp "  Apply ACL for '${SERVICE_USER}'${SHARE_USERS:+ and ${SHARE_USERS}} on existing ${SERVE_ROOT} (top level + default)? (y/N): " _acl_ok
  [[ "${_acl_ok,,}" =~ ^(y|yes)$ ]] || _apply_acl=0
fi

if (( _apply_acl )); then
  setfacl -m "u:${SERVICE_USER}:rwx" -d -m "u:${SERVICE_USER}:rwx" "$SERVE_ROOT"
  echo "  [OK]    ACL set for '${SERVICE_USER}' on ${SERVE_ROOT}"
  for _u in $SHARE_USERS; do
    if id "$_u" &>/dev/null; then
      setfacl -m "u:${_u}:rwx" -d -m "u:${_u}:rwx" "$SERVE_ROOT"
      echo "  [OK]    ACL set for '${_u}' on ${SERVE_ROOT}"
    else
      echo "  [WARN]  User '${_u}' not found — skipping"
    fi
  done

  if (( ! SERVE_ROOT_CREATED )); then
    echo ""
    echo "  Existing files keep their old permissions; ${SERVICE_USER} may get 'permission denied' on them."
    read -rp "  Apply the same ACLs recursively to existing content? (can take long on large shares) (y/N): " _rec
    if [[ "${_rec,,}" =~ ^(y|yes)$ ]]; then
      _spec=(-m "u:${SERVICE_USER}:rwX" -d -m "u:${SERVICE_USER}:rwx")
      for _u in $SHARE_USERS; do id "$_u" &>/dev/null && _spec+=(-m "u:${_u}:rwX" -d -m "u:${_u}:rwx"); done
      setfacl -R "${_spec[@]}" "$SERVE_ROOT"
      echo "  [OK]    Recursive ACLs applied"
    fi
  fi
else
  echo "  [WARN]  ACLs not applied — ${SERVICE_USER} may not be able to read ${SERVE_ROOT}."
fi

# ── Config (only if missing) ───────────────────────────────────────────────────
if [[ ! -f "$CONFIG_FILE" ]]; then
  _tmp="$(mktemp)"; TMP_FILES+=("$_tmp")
  {
    cat <<EOF
server:
  port: ${APP_PORT}
  database: "${DB_FILE}"
  cacheDir: "${CACHE_DIR}"
  sources:
    - path: "${SERVE_ROOT}"
      name: "Files"
      config:
        # defaultEnabled: every new user gets this source; set denyByDefault: true
        # and use rules if you want per-user opt-in on a multi-user instance.
        defaultEnabled: true
        denyByDefault: false
        indexingIntervalMinutes: 240
EOF
    if [[ "$FQ_NOAUTH" -eq 1 ]]; then
      cat <<EOF
auth:
  methods:
    noauth: true
EOF
    else
      cat <<EOF
auth:
  adminUsername: ${FQ_ADMIN_USER}
  methods:
    password:
      enabled: true
      minLength: 8
EOF
    fi
  } > "$_tmp"
  install -m 0640 -o "$SERVICE_USER" -g "$SERVICE_USER" "$_tmp" "$CONFIG_FILE"
  rm -f "$_tmp"
  echo "  [OK]    Config written: ${CONFIG_FILE}"
else
  echo "  [OK]    Config present — not modified"
fi

# ── Admin seeding (only when the database does not exist yet) ─────────────────
# The CLI 'set -u' needs an existing database. The server creates the database and
# the admin user on first start when FILEBROWSER_ADMIN_PASSWORD is set — so run it
# once, foreground-less, as the service user, with the password in its environment
# only (never in argv), wait for /health, then stop it. The systemd unit runs
# without that variable afterwards, so UI password changes persist.
if (( NEED_SEED )); then
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  echo "  Seeding admin user via one-off server start..."
  _seed_log="$(mktemp)"; TMP_FILES+=("$_seed_log")
  (
    cd "$CONFIG_DIR"
    export HOME="$CONFIG_DIR" USER="$SERVICE_USER" LOGNAME="$SERVICE_USER"
    export FILEBROWSER_ADMIN_PASSWORD="$FQ_ADMIN_PASS"
    exec setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups -- \
         "$INSTALL_BIN" -c "$CONFIG_FILE"
  ) >"$_seed_log" 2>&1 &
  _seed_pid=$!
  unset FQ_ADMIN_PASS

  _seeded=0
  for (( _i = 0; _i < HEALTH_TIMEOUT; _i++ )); do
    if ! kill -0 "$_seed_pid" 2>/dev/null; then break; fi
    if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:${APP_PORT}/health" 2>/dev/null; then
      _seeded=1; break
    fi
    sleep 1
  done
  kill -TERM "$_seed_pid" 2>/dev/null || true
  wait "$_seed_pid" 2>/dev/null || true

  if (( ! _seeded )) || [[ ! -f "$DB_FILE" ]]; then
    echo "  ERROR: Seeding run did not come up healthy / did not create ${DB_FILE}:" >&2
    sed 's/^/          /' "$_seed_log" >&2
    exit 1
  fi
  rm -f "$_seed_log"
  chown "${SERVICE_USER}:${SERVICE_USER}" "$DB_FILE"; chmod 0640 "$DB_FILE"
  echo "  [OK]    Database created and admin '${FQ_ADMIN_USER}' seeded"
fi

# ── Service registration & start ───────────────────────────────────────────────
echo "  Writing service unit..."
_write_units
if ! _start_and_verify; then
  echo "  ERROR: ${SERVICE_NAME} did not become healthy within ${HEALTH_TIMEOUT}s." >&2
  echo "         Check: systemctl status ${SERVICE_NAME}; journalctl -u ${SERVICE_NAME}" >&2
  _show_journal
  exit 1
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "  [OK]    ${APP} $(_installed_version) is running"
echo "    URL      : http://${CT_IP}:${APP_PORT}/"
echo "    Env      : ${ENV_KIND}, ${OS_LABEL}, ${ARCH}"
echo "    Hardening: $([[ "$NS_HARDENING" -eq 1 ]] && echo 'full' || echo 'basic (no mount namespaces)')"
echo "    Files    : ${SERVE_ROOT}$( (( ! SERVE_ROOT_CREATED )) && echo ' (pre-existing)')"
echo "    Conf     : ${CONFIG_FILE}"
echo "    DB       : ${DB_FILE}"
echo "    Cache    : ${CACHE_DIR}"
echo "    Bin      : ${INSTALL_BIN}"
if [[ "$FQ_NOAUTH" -eq 1 ]]; then
  echo "    Auth     : disabled (no-auth mode)"
else
  echo "    Auth     : ${FQ_ADMIN_USER} / (password set at install; stored in the DB only)"
fi
echo ""
echo "  Update: set APP_VERSION to the new v1.x.y-stable tag, snapshot/backup, re-run this script."
echo ""
