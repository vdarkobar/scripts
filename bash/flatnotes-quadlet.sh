#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID=""                             # empty = auto-assign via pvesh; set e.g. CT_ID=120 to pin
HN="flatnotes"
CPU=2
RAM=1024
DISK=8
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Flatnotes / Podman + Quadlet
APP_PORT=8080
APP_TZ="Europe/Berlin"
APP_FQDN=""                          # e.g. notes.example.com ; blank = local IP mode
FLATNOTES_AUTH_TYPE="password"       # password | none | read_only | totp
FLATNOTES_SESSION_EXPIRY_DAYS=1      # days before login token expires (upstream default 30)
FLATNOTES_PATH_PREFIX=""             # sub-path e.g. /flatnotes ; blank = root
TAGS="flatnotes;podman;quadlet;lxc"

# Images / versions
APP_IMAGE_REPO="docker.io/dullage/flatnotes"
APP_TAG="v5.5.4"                     # pinned default; do not default to :latest
DEBIAN_VERSION=13

# Auto-update policy
# AUTO_UPDATE=0 (default): timer installed but disabled; manual updates via
#   flatnotes-maint.sh update <tag>
# AUTO_UPDATE=1: timer re-pulls the CURRENT PINNED TAG on schedule and restarts
#   only if the image digest changed. :latest is never used.
AUTO_UPDATE=0

# Podman storage backend
# PODMAN_FUSE_OVERLAY=1: lab default so far — fuse=1 on the CT + fuse-overlayfs
#   as mount_program. Proxmox warns that FUSE mounts inside a CT can deadlock
#   when the CT is frozen, which snapshot-mode vzdump/PBS backups do.
# PODMAN_FUSE_OVERLAY=0: native overlayfs in the CT's user namespace (kernel
#   >= 5.11); no fuse=1, no mount_program, no freezer interaction. Verify after
#   install with: podman info --format '{{.Store.GraphDriverName}}' (overlay) and
#   run a snapshot-mode backup under load before adopting lab-wide.
PODMAN_FUSE_OVERLAY=1

# Extra packages to install (space-separated or array)
EXTRA_PACKAGES=(
)

# Behavior
CLEANUP_ON_FAIL=1

# Derived
APP_DIR="/opt/flatnotes"
APP_IMAGE="${APP_IMAGE_REPO}:${APP_TAG}"
APP_ENV_FILE="${APP_DIR}/flatnotes.env"
APP_WEB_PATH="${FLATNOTES_PATH_PREFIX}/"
QUADLET_FILE="/etc/containers/systemd/flatnotes.container"
QUADLET_SERVICE="flatnotes.service"

# ── Custom configs created by this script ─────────────────────────────────────
#   /etc/containers/systemd/flatnotes.container  (Quadlet unit — source of truth)
#   /opt/flatnotes/flatnotes.env                 (container credentials — read by Quadlet, 0600)
#   /opt/flatnotes/.env                          (runtime state — read by maint script)
#   /opt/flatnotes/data/                         (notes, attachments, .flatnotes search index)
#   /usr/local/bin/flatnotes-maint.sh            (maintenance helper)
#   /etc/systemd/system/flatnotes-update.service
#   /etc/systemd/system/flatnotes-update.timer
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/sysctl.d/99-hardening.conf

# ── Config validation ─────────────────────────────────────────────────────────
[[ "$HN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || { echo "  ERROR: HN is not a valid hostname: $HN" >&2; exit 1; }
[[ "$CPU" =~ ^[0-9]+$ ]] && (( CPU >= 1 )) || { echo "  ERROR: CPU must be a positive integer." >&2; exit 1; }
[[ "$RAM" =~ ^[0-9]+$ ]] && (( RAM >= 256 )) || { echo "  ERROR: RAM must be >= 256 MB." >&2; exit 1; }
[[ "$DISK" =~ ^[0-9]+$ ]] && (( DISK >= 1 )) || { echo "  ERROR: DISK must be >= 1 GB." >&2; exit 1; }
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }
[[ "$APP_PORT" =~ ^[0-9]+$ ]] || { echo "  ERROR: APP_PORT must be numeric." >&2; exit 1; }
(( APP_PORT >= 1 && APP_PORT <= 65535 )) || { echo "  ERROR: APP_PORT must be between 1 and 65535." >&2; exit 1; }
[[ "$AUTO_UPDATE" =~ ^[01]$ ]] || { echo "  ERROR: AUTO_UPDATE must be 0 or 1." >&2; exit 1; }
[[ "$PODMAN_FUSE_OVERLAY" =~ ^[01]$ ]] || { echo "  ERROR: PODMAN_FUSE_OVERLAY must be 0 or 1." >&2; exit 1; }
[[ "$CLEANUP_ON_FAIL" =~ ^[01]$ ]] || { echo "  ERROR: CLEANUP_ON_FAIL must be 0 or 1." >&2; exit 1; }
# APP_IMAGE_REPO is interpolated into podman, sed, the Quadlet unit and .env.
[[ "$APP_IMAGE_REPO" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*[A-Za-z0-9]$ ]] || {
  echo "  ERROR: APP_IMAGE_REPO must look like registry/namespace/name (no tag, no spaces)." >&2
  exit 1
}
# Flatnotes publishes v-prefixed semver tags (v5.5.4). Floating tags like v5 or
# v5.5 are mutable and are rejected for the same reason :latest is.
[[ "$APP_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "  ERROR: APP_TAG must be a pinned version like v5.5.4 — ':latest' and floating tags are not permitted." >&2
  exit 1
}
[[ -e "/usr/share/zoneinfo/${APP_TZ}" ]] || { echo "  ERROR: APP_TZ not found in /usr/share/zoneinfo: $APP_TZ" >&2; exit 1; }
[[ "$APP_TZ" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)+$ ]] || { echo "  ERROR: APP_TZ contains invalid characters." >&2; exit 1; }
if [[ -n "$APP_FQDN" ]]; then
  [[ "$APP_FQDN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]] \
    || { echo "  ERROR: APP_FQDN is not a valid hostname: $APP_FQDN" >&2; exit 1; }
fi
[[ "$FLATNOTES_AUTH_TYPE" =~ ^(password|none|read_only|totp)$ ]] || {
  echo "  ERROR: FLATNOTES_AUTH_TYPE must be password, none, read_only, or totp." >&2; exit 1;
}
[[ "$FLATNOTES_SESSION_EXPIRY_DAYS" =~ ^[0-9]+$ ]] && (( FLATNOTES_SESSION_EXPIRY_DAYS >= 1 )) \
  || { echo "  ERROR: FLATNOTES_SESSION_EXPIRY_DAYS must be an integer >= 1 (0 would expire tokens immediately)." >&2; exit 1; }
[[ -z "$FLATNOTES_PATH_PREFIX" || "$FLATNOTES_PATH_PREFIX" =~ ^(/[A-Za-z0-9._~-]+)+$ ]] || {
  echo "  ERROR: FLATNOTES_PATH_PREFIX must be empty or start with / and have no trailing slash (e.g. /flatnotes)." >&2; exit 1;
}
[[ "$TAGS" =~ ^[A-Za-z0-9._-]+(;[A-Za-z0-9._-]+)*$ ]] || { echo "  ERROR: TAGS must be a semicolon-separated list without spaces." >&2; exit 1; }
for pkg in "${EXTRA_PACKAGES[@]}"; do
  [[ "$pkg" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || { echo "  ERROR: Invalid package name in EXTRA_PACKAGES: $pkg" >&2; exit 1; }
done

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

for cmd in pvesh pveam pct pvesm qm curl python3 ip awk grep sed sort paste seq readlink cp chmod dpkg head tr; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

# pveam lists templates for more than one CPU architecture. Selecting only by
# Debian version can pick an ARM64 rootfs on an AMD64 host (or vice versa),
# which creates successfully but fails when LXC executes /sbin/init.
HOST_ARCH="$(dpkg --print-architecture)"
case "$HOST_ARCH" in
  amd64|arm64) ;;
  *) echo "  ERROR: Unsupported Proxmox host architecture: $HOST_ARCH" >&2; exit 1 ;;
esac

# Prompts read from the terminal directly so the script also works when
# piped (curl ... | bash) and stdin is the script body.
if ! exec 8</dev/tty; then
  echo "  ERROR: An interactive terminal is required for confirmation and password prompts." >&2
  exit 1
fi

if [[ -n "$CT_ID" ]]; then
  [[ "$CT_ID" =~ ^[0-9]+$ ]] && (( CT_ID >= 100 && CT_ID <= 999999999 )) \
    || { echo "  ERROR: CT_ID must be an integer >= 100." >&2; exit 1; }
  if pct status "$CT_ID" >/dev/null 2>&1 || qm status "$CT_ID" >/dev/null 2>&1; then
    echo "  ERROR: CT_ID $CT_ID is already in use on this node." >&2
    exit 1
  fi
else
  CT_ID="$(pvesh get /cluster/nextid)"
  [[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }
fi

# Creator scripts are not idempotent: a re-run would create a second CT with the
# same hostname. Refuse if one already exists on this node (e.g. a preserved
# failed install) — destroy it first or change HN.
EXISTING_CT="$(pct list 2>/dev/null | awk -v h="$HN" 'NR>1 && $NF==h {print $1}' | head -n1)"
if [[ -n "$EXISTING_CT" ]]; then
  echo "  ERROR: A CT with hostname '${HN}' already exists on this node (CT ${EXISTING_CT})." >&2
  echo "  Destroy it (pct set ${EXISTING_CT} --protection 0; pct destroy ${EXISTING_CT}) or change HN, then re-run." >&2
  exit 1
fi

# ── Discover available resources ──────────────────────────────────────────────
AVAIL_TMPL_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'vztmpl' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_CT_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^vmbr' | sort | paste -sd, | sed 's/,/, /g' || echo "n/a")"

# ── Show defaults & confirm ───────────────────────────────────────────────────
cat <<EOF2

  Flatnotes Quadlet LXC Creator — Configuration
  ────────────────────────────────────────
  CT ID:             $CT_ID
  Hostname:          $HN
  CPU cores:         $CPU
  RAM (MB):          $RAM
  Disk (GB):         $DISK
  Bridge:            $BRIDGE ($AVAIL_BRIDGES)
  Template storage:  $TEMPLATE_STORAGE ($AVAIL_TMPL_STORES)
  Container storage: $CONTAINER_STORAGE ($AVAIL_CT_STORES)
  Host architecture: $HOST_ARCH
  Debian:            $DEBIAN_VERSION
  App image:         $APP_IMAGE
  App port:          $APP_PORT
  Auth type:         $FLATNOTES_AUTH_TYPE
  Session expiry:    ${FLATNOTES_SESSION_EXPIRY_DAYS} days
  Path prefix:       ${FLATNOTES_PATH_PREFIX:-(none)}
  Timezone:          $APP_TZ
  FQDN:              $([ -n "$APP_FQDN" ] && echo "$APP_FQDN" || echo "(no public FQDN)")
  Listens on:        0.0.0.0:${APP_PORT} inside the CT (Network=host) — reachable from the whole LAN
  Podman storage:    $([ "$PODMAN_FUSE_OVERLAY" -eq 1 ] && echo "fuse-overlayfs (fuse=1)" || echo "native overlay (no FUSE)")
  Tags:              $TAGS
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled (re-pull pinned $APP_TAG)" || echo "disabled (pinned $APP_TAG, manual)")
  Cleanup on fail:   $CLEANUP_ON_FAIL (until first service start; CT preserved after that)
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

if [[ "$FLATNOTES_AUTH_TYPE" == "none" || "$FLATNOTES_AUTH_TYPE" == "read_only" ]]; then
  echo "  WARNING: FLATNOTES_AUTH_TYPE=${FLATNOTES_AUTH_TYPE} — no login required. Port ${APP_PORT} is open to"
  echo "  every host that can reach the CT. Restrict with the PVE firewall (e.g. allow only the NPM CT)."
  echo ""
fi

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/flatnotes-quadlet.sh"
SCRIPT_LOCAL="/root/flatnotes-quadlet.sh"
SCRIPT_SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

read -r -p "  Continue with these settings? [y/N]: " response <&8
case "$response" in
  [yY][eE][sS]|[yY]) ;;
  *)
    echo ""
    echo "  Saving current script to ${SCRIPT_LOCAL} for editing..."
    # Shebang check: when run as 'curl | bash', $0 is the bash binary, not this script.
    if [[ -f "$SCRIPT_SELF" ]] && head -n1 "$SCRIPT_SELF" 2>/dev/null | grep -q '^#!/usr/bin/env bash$' \
      && cp -f -- "$SCRIPT_SELF" "$SCRIPT_LOCAL"; then
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
      exit 1
    fi
    exit 0
    ;;
esac

echo ""

# ── Preflight — environment ───────────────────────────────────────────────────
pvesm status | awk -v s="$TEMPLATE_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Template storage not found: $TEMPLATE_STORAGE" >&2; exit 1; }
pvesh get /storage/"$TEMPLATE_STORAGE" --output-format json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'vztmpl' in d.get('content','')" 2>/dev/null \
  || { echo "  ERROR: Template storage '$TEMPLATE_STORAGE' does not support vztmpl content." >&2; exit 1; }

pvesm status | awk -v s="$CONTAINER_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Container storage not found: $CONTAINER_STORAGE" >&2; exit 1; }
pvesh get /storage/"$CONTAINER_STORAGE" --output-format json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'rootdir' in d.get('content','')" 2>/dev/null \
  || { echo "  ERROR: Container storage '$CONTAINER_STORAGE' does not support rootdir content." >&2; exit 1; }

ip link show "$BRIDGE" >/dev/null 2>&1 \
  || { echo "  ERROR: Bridge not found: $BRIDGE" >&2; exit 1; }

# ── Root password ─────────────────────────────────────────────────────────────
PASSWORD=""
while true; do
  read -r -s -p "  Set root password: " PW1 <&8; echo
  if [[ -z "$PW1" ]]; then echo "  Password cannot be blank."; continue; fi
  if [[ "$PW1" == *" "* ]]; then echo "  Password cannot contain spaces."; continue; fi
  if [[ ${#PW1} -lt 8 ]]; then echo "  Password must be at least 8 characters."; continue; fi
  read -r -s -p "  Verify root password: " PW2 <&8; echo
  if [[ "$PW1" == "$PW2" ]]; then PASSWORD="$PW1"; break; fi
  echo "  Passwords do not match. Try again."
done

echo ""

# ── Flatnotes credentials ─────────────────────────────────────────────────────
# Values are written UNQUOTED to flatnotes.env (podman --env-file keeps quotes
# literally, unlike compose). Reject shell/systemd-sensitive characters so the
# value on disk is exactly what the app receives; verification round-trips the
# values through the running container to prove it.
FLATNOTES_USERNAME=""
FLATNOTES_PASSWORD=""
FLATNOTES_TOTP_KEY=""
FLATNOTES_TOTP_MANUAL_KEY=""
SECRET_KEY=""

if [[ "$FLATNOTES_AUTH_TYPE" == "password" || "$FLATNOTES_AUTH_TYPE" == "totp" ]]; then
  while true; do
    read -r -p "  Flatnotes username: " FLATNOTES_USERNAME <&8
    [[ -z "$FLATNOTES_USERNAME" ]] && { echo "  Username cannot be empty."; continue; }
    [[ "$FLATNOTES_USERNAME" =~ [[:space:]] ]] && { echo "  Username cannot contain spaces."; continue; }
    [[ "$FLATNOTES_USERNAME" =~ [\"\'$\`\\#] ]] && { echo '  Username cannot contain quotes, $, backtick, backslash or #'; continue; }
    break
  done
  echo ""
  while true; do
    read -r -s -p "  Flatnotes password: " FN_PW1 <&8; echo
    if [[ -z "$FN_PW1" ]]; then echo "  Password cannot be blank."; continue; fi
    if [[ ${#FN_PW1} -lt 8 ]]; then echo "  Password must be at least 8 characters."; continue; fi
    if [[ "$FN_PW1" =~ [[:cntrl:]] ]]; then echo "  Password cannot contain control characters."; continue; fi
    if [[ "$FN_PW1" =~ ^[[:space:]]|[[:space:]]$ ]]; then echo "  Password cannot start or end with whitespace."; continue; fi
    if [[ "$FN_PW1" =~ [\"\'$\`\\#] ]]; then echo '  Password cannot contain quotes, $, backtick, backslash or #'; continue; fi
    read -r -s -p "  Verify Flatnotes password: " FN_PW2 <&8; echo
    if [[ "$FN_PW1" == "$FN_PW2" ]]; then FLATNOTES_PASSWORD="$FN_PW1"; break; fi
    echo "  Passwords do not match. Try again."
  done
  echo ""

  # FLATNOTES_SECRET_KEY signs session tokens — required for password and totp.
  set +o pipefail
  SECRET_KEY="$(head -c 4096 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 48)"
  set -o pipefail
  [[ ${#SECRET_KEY} -eq 48 ]] || { echo "  ERROR: Failed to generate secret key." >&2; exit 1; }
fi

if [[ "$FLATNOTES_AUTH_TYPE" == "totp" ]]; then
  set +o pipefail
  FLATNOTES_TOTP_KEY="$(head -c 4096 /dev/urandom | tr -dc 'A-Z2-7' | head -c 32)"
  set -o pipefail
  [[ ${#FLATNOTES_TOTP_KEY} -eq 32 ]] || { echo "  ERROR: Failed to generate TOTP key." >&2; exit 1; }
  # Flatnotes base32-encodes FLATNOTES_TOTP_KEY before handing it to pyotp;
  # the encoded form is what an authenticator app expects as the manual entry.
  FLATNOTES_TOTP_MANUAL_KEY="$(printf '%s' "$FLATNOTES_TOTP_KEY" \
    | python3 -c 'import base64,sys; sys.stdout.write(base64.b32encode(sys.stdin.buffer.read()).decode("ascii").rstrip("="))')"
  [[ -n "$FLATNOTES_TOTP_MANUAL_KEY" ]] || { echo "  ERROR: Failed to derive the TOTP authenticator key." >&2; exit 1; }
  echo "  Generated TOTP seed; the authenticator key will be shown in the summary."
  echo ""
fi

# ── Template discovery & download ─────────────────────────────────────────────
pveam update

echo ""
TEMPLATE="$(pveam available -section system \
  | awk -v p="debian-${DEBIAN_VERSION}" -v a="$HOST_ARCH" \
      '$2 ~ ("^" p "-standard_") && $2 ~ ("_" a "\\.tar\\.(zst|gz|xz)$") {print $2}' \
  | sort -V | tail -n1)"
[[ -n "$TEMPLATE" ]] || {
  echo "  ERROR: No Debian ${DEBIAN_VERSION} template for host architecture ${HOST_ARCH} was found via pveam." >&2
  exit 1
}
echo "  Template: $TEMPLATE"

if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk -v v="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" '$1==v{found=1} END{exit(!found)}'; then
  echo "  Template already present: $TEMPLATE"
else
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

# ── Create LXC ────────────────────────────────────────────────────────────────
# Root password is set after start via chpasswd on stdin, keeping it out of
# the host process list (pct create -password exposes it in ps).
CT_FEATURES="nesting=1,keyctl=1"
[[ "$PODMAN_FUSE_OVERLAY" -eq 1 ]] && CT_FEATURES+=",fuse=1"

PCT_OPTIONS=(
  -hostname "$HN"
  -cores "$CPU"
  -memory "$RAM"
  -rootfs "${CONTAINER_STORAGE}:${DISK}"
  -onboot 1
  -ostype debian
  -arch "$HOST_ARCH"
  -unprivileged 1
  -features "$CT_FEATURES"
  -tags "$TAGS"
  -net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,ip6=manual"
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

printf 'root:%s\n' "$PASSWORD" | pct exec "$CT_ID" -- chpasswd
unset PASSWORD PW1 PW2

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
PODMAN_FUSE_PKG=""
[[ "$PODMAN_FUSE_OVERLAY" -eq 1 ]] && PODMAN_FUSE_PKG="fuse-overlayfs"

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y locales curl ca-certificates iproute2 podman tar gzip ${PODMAN_FUSE_PKG}
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

# ── Podman configuration ──────────────────────────────────────────────────────
OVERLAY_OPTIONS=""
if [[ "$PODMAN_FUSE_OVERLAY" -eq 1 ]]; then
  OVERLAY_OPTIONS='
[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"'
fi

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  mkdir -p /etc/containers

  cat > /etc/containers/storage.conf <<EOF2
[storage]
driver = \"overlay\"
runroot = \"/run/containers/storage\"
graphroot = \"/var/lib/containers/storage\"
${OVERLAY_OPTIONS}
EOF2

  cat > /etc/containers/containers.conf <<EOF2
[containers]
log_size_max = 10485760
EOF2
"

pct exec "$CT_ID" -- podman info >/dev/null 2>&1
pct exec "$CT_ID" -- podman --version

# Quadlet requires cgroup v2 and the overlay driver must actually be active
# (a silent fallback to vfs would work but eat disk and be very slow).
CGROUPS_VERSION="$(pct exec "$CT_ID" -- podman info --format '{{.Host.CgroupsVersion}}' 2>/dev/null || echo "?")"
[[ "$CGROUPS_VERSION" == "v2" ]] || { echo "  ERROR: Quadlet requires cgroup v2 inside the CT; podman reports '${CGROUPS_VERSION}'." >&2; exit 1; }
GRAPH_DRIVER="$(pct exec "$CT_ID" -- podman info --format '{{.Store.GraphDriverName}}' 2>/dev/null || echo "?")"
[[ "$GRAPH_DRIVER" == "overlay" ]] || { echo "  ERROR: Podman storage driver is '${GRAPH_DRIVER}', expected overlay." >&2; exit 1; }
echo "  Podman: cgroup ${CGROUPS_VERSION}, storage driver ${GRAPH_DRIVER}$([ "$PODMAN_FUSE_OVERLAY" -eq 1 ] && echo " (fuse-overlayfs)" || echo " (native)")"

# ── Pull image ────────────────────────────────────────────────────────────────
echo "  Pulling Flatnotes image: ${APP_IMAGE} ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman pull '${APP_IMAGE}'
"

# ── Prepare persistent paths ──────────────────────────────────────────────────
# Flatnotes persistent state (all of it):
#   /opt/flatnotes/data/            notes (*.md), attachments, .flatnotes/ search index
# The image entrypoint drops to PUID/PGID (1000:1000) before starting the app,
# so data/ must be owned by 1000:1000 as seen from inside the LXC. The app
# creates .flatnotes/ itself on first start — do not pre-create it.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  install -d -m 0755 '${APP_DIR}'
  install -d -m 0755 -o 1000 -g 1000 '${APP_DIR}/data'
"

# ── Quadlet unit file ─────────────────────────────────────────────────────────
# Rootful Quadlet: /etc/containers/systemd/ — no linger, no --user flags needed.
# systemd daemon-reload triggers the Quadlet generator; flatnotes.service is
# created as a transient unit and WantedBy=multi-user.target handles boot start.
# Network=host bypasses Netavark NAT issues on Debian LXC; FLATNOTES_PORT tells
# the app which port to bind on the CT interface instead of PublishPort=.
# Credentials live in flatnotes.env (0600) via EnvironmentFile=, so this unit
# file contains no secrets and can stay 0644.
PREFIX_LINE=""
[[ -n "$FLATNOTES_PATH_PREFIX" ]] && PREFIX_LINE="Environment=FLATNOTES_PATH_PREFIX=${FLATNOTES_PATH_PREFIX}"

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  mkdir -p /etc/containers/systemd

  cat > '${QUADLET_FILE}' <<EOF2
[Unit]
Description=Flatnotes
After=network-online.target
Wants=network-online.target

[Container]
Image=${APP_IMAGE}
ContainerName=flatnotes
Network=host
Environment=TZ=${APP_TZ}
Environment=PUID=1000
Environment=PGID=1000
Environment=FLATNOTES_PORT=${APP_PORT}
Environment=FLATNOTES_AUTH_TYPE=${FLATNOTES_AUTH_TYPE}
Environment=FLATNOTES_SESSION_EXPIRY_DAYS=${FLATNOTES_SESSION_EXPIRY_DAYS}
${PREFIX_LINE}
EnvironmentFile=${APP_ENV_FILE}
Volume=${APP_DIR}/data:/data
LogDriver=journald

[Service]
Restart=always
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF2

  chmod 0644 '${QUADLET_FILE}'
"

# ── Container credentials file ────────────────────────────────────────────────
# Read by Quadlet via EnvironmentFile= (podman --env-file). Written UNQUOTED —
# podman keeps quotes as part of the value. Streamed over stdin so credentials
# never appear in host or CT argv, and no temp file is created.
{
  printf '# Flatnotes container credentials — managed by flatnotes-quadlet.sh\n'
  if [[ "$FLATNOTES_AUTH_TYPE" == "password" || "$FLATNOTES_AUTH_TYPE" == "totp" ]]; then
    printf 'FLATNOTES_USERNAME=%s\n' "$FLATNOTES_USERNAME"
    printf 'FLATNOTES_PASSWORD=%s\n' "$FLATNOTES_PASSWORD"
    printf 'FLATNOTES_SECRET_KEY=%s\n' "$SECRET_KEY"
  fi
  if [[ "$FLATNOTES_AUTH_TYPE" == "totp" ]]; then
    printf 'FLATNOTES_TOTP_KEY=%s\n' "$FLATNOTES_TOTP_KEY"
  fi
} | pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  umask 077
  cat > '${APP_ENV_FILE}'
  chmod 0600 '${APP_ENV_FILE}'
"
unset SECRET_KEY FLATNOTES_TOTP_KEY FN_PW1 FN_PW2

# ── Runtime state file ────────────────────────────────────────────────────────
# .env is not read by Quadlet or systemd. It is the maint script's source of
# truth for current image tag and policy flags. Keep it in sync with the
# Quadlet unit whenever the image is updated.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > '${APP_DIR}/.env' <<EOF2
APP_IMAGE_REPO=${APP_IMAGE_REPO}
APP_TAG=${APP_TAG}
APP_IMAGE=${APP_IMAGE}
APP_PORT=${APP_PORT}
APP_TZ=${APP_TZ}
APP_FQDN=${APP_FQDN}
FLATNOTES_AUTH_TYPE=${FLATNOTES_AUTH_TYPE}
FLATNOTES_PATH_PREFIX=${FLATNOTES_PATH_PREFIX}
AUTO_UPDATE=${AUTO_UPDATE}
EOF2
  chmod 0600 '${APP_DIR}/.env'
"

# ── Maintenance script ────────────────────────────────────────────────────────
# update <tag>: pull → sed Image= in Quadlet file → sed .env → daemon-reload →
#   restart → health check; rollback restores both files, daemon-reload, restart.
# auto-update:  re-pull the CURRENT PINNED TAG; restart only if the image ID
#   changed; rollback re-tags the previous image ID and restarts.
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/flatnotes-maint.sh && chmod 0755 /usr/local/bin/flatnotes-maint.sh' <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR="${APP_DIR:-/opt/flatnotes}"
QUADLET_FILE="/etc/containers/systemd/flatnotes.container"
SERVICE="flatnotes.service"
CONTAINER="flatnotes"
ENV_FILE="${APP_DIR}/.env"

need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF2
  Flatnotes Maintenance (Quadlet)
  ───────────────────────────────
  Usage:
    $0 update <tag> [--yes]   # e.g. v5.6.0 — pinned version required, no :latest
    $0 auto-update            # re-pull current pinned tag (only if AUTO_UPDATE=1)
    $0 version

  Notes:
    - update pulls the pinned tag, updates the Quadlet unit and .env, restarts the service
    - auto-update is called by flatnotes-update.timer; it never changes the tag
    - :latest and floating tags (v5, v5.5) are not permitted — always specify vX.Y.Z
    - backup and restore are handled by PBS and PVE snapshots
    - take a PVE snapshot before manual updates: pct snapshot <CT_ID> pre-update-\$(date +%Y%m%d)
EOF2
}

[[ -d "$APP_DIR" ]]      || die "APP_DIR not found: $APP_DIR"
[[ -f "$ENV_FILE" ]]     || die "Missing env file: $ENV_FILE"
[[ -f "$QUADLET_FILE" ]] || die "Missing Quadlet unit: $QUADLET_FILE"

# One maintenance operation at a time — a manual update must not overlap the timer.
LOCK_FILE="/run/lock/flatnotes-maint.lock"
mkdir -p /run/lock
exec 9>"$LOCK_FILE"
flock -n 9 || die "Another flatnotes-maint.sh operation is already running."

env_val() {
  awk -F= -v key="$1" '$1==key{print substr($0, length(key)+2)}' "$ENV_FILE" | tail -n1
}

env_flag() {
  local raw
  raw="$(env_val "$1" | tr -d '[:space:]')"
  [[ "$raw" =~ ^[01]$ ]] && printf '%s' "$raw" || printf '0'
}

app_port() {
  local port
  port="$(env_val APP_PORT | tr -d '[:space:]')"
  [[ "$port" =~ ^[0-9]+$ ]] && printf '%s' "$port" || printf '8080'
}

path_prefix() { env_val FLATNOTES_PATH_PREFIX | tr -d '[:space:]'; }
current_image() { env_val APP_IMAGE; }
current_repo()  { env_val APP_IMAGE_REPO; }
current_tag()   { local img; img="$(current_image)"; echo "${img##*:}"; }

running_image_id() {
  podman inspect --format '{{.Image}}' "$CONTAINER" 2>/dev/null || true
}

image_id_of() {
  podman image inspect --format '{{.Id}}' "$1" 2>/dev/null || true
}

wait_for_app() {
  local port prefix code
  port="$(app_port)"
  prefix="$(path_prefix)"
  for i in $(seq 1 45); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${port}${prefix}/health" 2>/dev/null || echo 000)"
    [[ "$code" == "200" ]] && return 0
    sleep 2
  done
  return 1
}

# update <tag> [--yes] — switch to a pinned version
update_app() {
  local new_tag="" skip_confirm=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) skip_confirm=1; shift ;;
      *) new_tag="$1"; shift ;;
    esac
  done

  local old_tag repo old_image new_image old_id tmp_env tmp_quadlet
  [[ -n "$new_tag" ]] || die "Usage: flatnotes-maint.sh update <tag>"
  [[ "$new_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] \
    || die "Invalid tag: $new_tag — pinned version required (e.g. v5.6.0), ':latest' is not permitted."

  old_tag="$(current_tag)"
  repo="$(current_repo)"
  [[ -n "$repo" ]] || die "Could not read APP_IMAGE_REPO from .env"
  old_image="$(current_image)"
  new_image="${repo}:${new_tag}"
  # Capture the current image ID before pulling: if new_tag == old_tag, the pull
  # moves the tag and the old ref would otherwise resolve to the NEW image on rollback.
  old_id="$(image_id_of "$old_image")"
  tmp_env="$(mktemp)"
  tmp_quadlet="$(mktemp)"

  echo "  Current tag: $old_tag"
  echo "  Target  tag: $new_tag"

  if [[ "$skip_confirm" -eq 0 ]]; then
    echo ""
    echo "  IMPORTANT: Take a PVE snapshot before proceeding."
    echo "  Use: pct snapshot <CT_ID> pre-update-$(date +%Y%m%d)"
    echo ""
    read -r -p "  Continue? [y/N]: " confirm
    case "$confirm" in
      [yY][eE][sS]|[yY]) ;;
      *) echo "  Aborted."; rm -f "$tmp_env" "$tmp_quadlet"; exit 0 ;;
    esac
  fi

  cp -a "$ENV_FILE"     "$tmp_env"
  cp -a "$QUADLET_FILE" "$tmp_quadlet"

  cleanup() { rm -f "$tmp_env" "$tmp_quadlet"; }
  rollback() {
    echo "  !! Update failed — rolling back and restarting ..." >&2
    cp -a "$tmp_env"     "$ENV_FILE"
    cp -a "$tmp_quadlet" "$QUADLET_FILE"
    [[ -n "$old_id" ]] && podman tag "$old_id" "$old_image" >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl restart "$SERVICE" || true
    rm -f "$tmp_env" "$tmp_quadlet"
    if wait_for_app; then
      echo "  Rollback complete — ${old_image} is healthy again." >&2
    else
      echo "  CRITICAL: rollback to ${old_image} did not become healthy. Restore the CT from the PVE snapshot / PBS." >&2
    fi
  }
  trap rollback ERR

  echo "  Pulling target image ..."
  podman pull "$new_image"

  sed -i "s|^Image=.*|Image=${new_image}|" "$QUADLET_FILE"
  sed -i \
    -e "s|^APP_TAG=.*|APP_TAG=$new_tag|" \
    -e "s|^APP_IMAGE=.*|APP_IMAGE=$new_image|" \
    "$ENV_FILE"

  echo "  Reloading Quadlet and restarting service ..."
  systemctl daemon-reload
  systemctl restart "$SERVICE"

  echo "  Waiting for Flatnotes ..."
  if ! wait_for_app; then
    trap - ERR
    rollback
    die "Flatnotes did not become healthy after update."
  fi

  trap - ERR
  cleanup
  if [[ -n "$old_id" && "$old_id" != "$(image_id_of "$new_image")" ]]; then
    podman rmi "$old_id" >/dev/null 2>&1 || true
  fi
  echo "  OK: Flatnotes updated to $new_tag"
}

# auto-update — re-pull the current pinned tag; restart only if the image changed
auto_update_app() {
  if [[ "$(env_flag AUTO_UPDATE)" != "1" ]]; then
    echo "  Auto-update disabled in ${ENV_FILE}; nothing to do."
    return 0
  fi

  local image old_id new_id
  image="$(current_image)"
  [[ -n "$image" ]] || die "Could not read APP_IMAGE from .env"
  old_id="$(running_image_id)"

  echo "  Auto-update: re-pulling pinned ${image} ..."
  podman pull "$image"
  new_id="$(image_id_of "$image")"
  [[ -n "$new_id" ]] || die "Could not inspect pulled image ${image}"

  if [[ -n "$old_id" && "$new_id" == "$old_id" ]]; then
    echo "  OK: ${image} is already current — no restart needed."
    return 0
  fi

  rollback() {
    echo "  !! Auto-update failed — restoring previous image and restarting ..." >&2
    [[ -n "$old_id" ]] && podman tag "$old_id" "$image" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE" || true
    if wait_for_app; then
      echo "  Rollback complete — previous image is healthy again." >&2
    else
      echo "  CRITICAL: rollback did not become healthy. Restore the CT from the PVE snapshot / PBS." >&2
    fi
  }
  trap rollback ERR

  echo "  Image changed — restarting service ..."
  systemctl restart "$SERVICE"

  echo "  Waiting for Flatnotes ..."
  if ! wait_for_app; then
    trap - ERR
    rollback
    die "Flatnotes did not become healthy after auto-update."
  fi

  trap - ERR
  [[ -n "$old_id" ]] && podman rmi "$old_id" >/dev/null 2>&1 || true
  echo "  OK: Flatnotes refreshed on ${image}"
}

need_root
cmd="${1:-}"
case "$cmd" in
  update)      shift; update_app "$@" ;;
  auto-update) auto_update_app ;;
  version)
    echo "Configured image: $(current_image)"
    echo "Running image ID: $(running_image_id)"
    echo "AUTO_UPDATE=$(env_flag AUTO_UPDATE)"
    ;;
  ""|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
MAINT
echo "  Maintenance script deployed: /usr/local/bin/flatnotes-maint.sh"

# ── Start via Quadlet ─────────────────────────────────────────────────────────
# daemon-reload triggers the Quadlet generator which produces flatnotes.service
# as a transient systemd unit. WantedBy=multi-user.target handles boot restarts.
# Transient units cannot be systemctl-enabled; daemon-reload is sufficient.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  systemctl daemon-reload
  systemctl start '${QUADLET_SERVICE}'
"

# ── Disarm destructive cleanup ────────────────────────────────────────────────
CLEANUP_ON_FAIL=0

# ── Verification ──────────────────────────────────────────────────────────────
sleep 3
VERIFY_FAIL=0

if pct exec "$CT_ID" -- systemctl is-active --quiet "${QUADLET_SERVICE}" 2>/dev/null; then
  echo "  Quadlet service is active: ${QUADLET_SERVICE}"
else
  echo "  ERROR: ${QUADLET_SERVICE} is not active" >&2
  echo "  Check: pct exec $CT_ID -- systemctl status flatnotes.service" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u flatnotes.service --no-pager -n 50" >&2
  VERIFY_FAIL=1
fi

RUNNING=0
for i in $(seq 1 60); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc \
    'podman ps --filter name=^flatnotes$ --format "{{.Names}}" 2>/dev/null | wc -l' \
    2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge 1 ]] && break
  sleep 2
done
pct exec "$CT_ID" -- bash -lc 'podman ps' || true

if [[ "$RUNNING" -lt 1 ]]; then
  echo "  ERROR: Expected 1 container running, found $RUNNING" >&2
  VERIFY_FAIL=1
else
  echo "  Container count OK ($RUNNING running)"
fi

# Credential round-trip: prove the values the container actually received are
# byte-identical to what was configured (guards against env-file parsing
# surprises). Expected values are streamed over stdin, never passed as argv.
if [[ "$RUNNING" -ge 1 && ( "$FLATNOTES_AUTH_TYPE" == "password" || "$FLATNOTES_AUTH_TYPE" == "totp" ) ]]; then
  if printf '%s\n%s\n' "$FLATNOTES_USERNAME" "$FLATNOTES_PASSWORD" | pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    IFS= read -r want_user
    IFS= read -r want_pass
    have_user="$(podman exec flatnotes sh -c "printf %s \"\$FLATNOTES_USERNAME\"")"
    have_pass="$(podman exec flatnotes sh -c "printf %s \"\$FLATNOTES_PASSWORD\"")"
    [[ "$want_user" == "$have_user" ]] || { echo "  FLATNOTES_USERNAME inside the container does not match the configured value" >&2; exit 1; }
    [[ "$want_pass" == "$have_pass" ]] || { echo "  FLATNOTES_PASSWORD inside the container does not match the configured value" >&2; exit 1; }
  '; then
    echo "  Credential round-trip OK (env file parsed as written)"
  else
    echo "  ERROR: Credentials inside the container differ from the configured values" >&2
    echo "  Check: pct exec $CT_ID -- cat ${APP_ENV_FILE}" >&2
    VERIFY_FAIL=1
  fi
fi
unset FLATNOTES_PASSWORD

FN_HEALTHY=0
for i in $(seq 1 90); do
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc "curl -s -o /dev/null -w '%{http_code}' --max-time 3 'http://127.0.0.1:${APP_PORT}${FLATNOTES_PATH_PREFIX}/health' 2>/dev/null" 2>/dev/null || echo 000)"
  case "$HTTP_CODE" in
    200)
      FN_HEALTHY=1
      break
      ;;
  esac
  sleep 2
done

if [[ "$FN_HEALTHY" -eq 1 ]]; then
  echo "  Flatnotes health check passed (HTTP $HTTP_CODE)"
else
  echo "  ERROR: Flatnotes /health did not return 200 on port ${APP_PORT}" >&2
  echo "  Check: pct exec $CT_ID -- systemctl status flatnotes.service" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u flatnotes.service --no-pager -n 80" >&2
  VERIFY_FAIL=1
fi

if (( VERIFY_FAIL == 1 )); then
  echo "" >&2
  echo "  FATAL: Core verification failed — CT $CT_ID is preserved but the install is incomplete." >&2
  echo "  Inspect the container and fix manually, or destroy and re-run." >&2
  exit 1
fi

# ── Auto-update timer (policy-driven) ─────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/flatnotes-update.service <<EOF2
[Unit]
Description=Flatnotes auto-update maintenance run
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/flatnotes-maint.sh auto-update
EOF2

  cat > /etc/systemd/system/flatnotes-update.timer <<EOF2
[Unit]
Description=Flatnotes auto-update timer

[Timer]
OnCalendar=*-*-01 05:30:00
OnCalendar=*-*-15 05:30:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF2

  systemctl daemon-reload
'
if [[ "$AUTO_UPDATE" -eq 1 ]]; then
  pct exec "$CT_ID" -- bash -lc 'systemctl enable --now flatnotes-update.timer'
  echo "  Auto-update timer enabled"
else
  pct exec "$CT_ID" -- bash -lc 'systemctl disable --now flatnotes-update.timer >/dev/null 2>&1 || true'
  echo "  Auto-update timer installed but disabled"
fi

# ── Unattended upgrades ───────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y unattended-upgrades
  distro_codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  cat > /etc/apt/apt.conf.d/52unattended-$(hostname).conf <<EOF2
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
EOF2

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF2
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF2

  systemctl enable --now unattended-upgrades
'

# ── Extra packages ────────────────────────────────────────────────────────────
if [[ "${#EXTRA_PACKAGES[@]}" -gt 0 ]]; then
  pct exec "$CT_ID" -- bash -lc "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y ${EXTRA_PACKAGES[*]}
  "
fi

# ── Sysctl hardening ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/sysctl.d/99-hardening.conf <<EOF2
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
EOF2
  if ! sysctl --system >/dev/null 2>&1; then
    echo "  WARNING: sysctl --system reported errors — some keys may be read-only in this unprivileged CT:" >&2
    sysctl --system 2>&1 | grep -i "error\|permission" >&2 || true
  fi
'

# ── Cleanup packages ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y man-db manpages 2>/dev/null || true
  apt-get -y autoremove
  apt-get -y clean
'

# ── MOTD (dynamic drop-ins) ───────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  > /etc/motd
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
  rm -f /etc/update-motd.d/*

  cat > /etc/update-motd.d/00-header <<'MOTD'
#!/bin/sh
printf '\\n  Flatnotes (Podman/Quadlet)\\n'
printf '  ────────────────────────────────────\\n'
MOTD

  cat > /etc/update-motd.d/10-sysinfo <<'MOTD'
#!/bin/sh
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '  Hostname:  %s\\n' \"\$(hostname)\"
printf '  IP:        %s\\n' \"\${ip:-n/a}\"
printf '  Uptime:    %s\\n' \"\$(uptime -p 2>/dev/null || uptime)\"
printf '  Disk:      %s\\n' \"\$(df -h / | awk 'NR==2{printf \"%s/%s (%s used)\", \$3, \$2, \$5}')\"
MOTD

  cat > /etc/update-motd.d/30-app <<'MOTD'
#!/bin/sh
running=\$(podman ps --filter name=^flatnotes$ --format '{{.Names}}' 2>/dev/null | wc -l)
svc_status=\$(systemctl is-active flatnotes.service 2>/dev/null); svc_status=\${svc_status:-unknown}
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
image=\$(awk -F= '/^APP_IMAGE=/{print \$2}' /opt/flatnotes/.env 2>/dev/null | tail -n1)
auth=\$(awk -F= '/^FLATNOTES_AUTH_TYPE=/{print \$2}' /opt/flatnotes/.env 2>/dev/null | tail -n1)
auto=\$(awk -F= '/^AUTO_UPDATE=/{print \$2}' /opt/flatnotes/.env 2>/dev/null | tail -n1)
fqdn=\$(awk -F= '/^APP_FQDN=/{print \$2}' /opt/flatnotes/.env 2>/dev/null | tail -n1)
port=\$(awk -F= '/^APP_PORT=/{print \$2}' /opt/flatnotes/.env 2>/dev/null | tail -n1)
prefix=\$(awk -F= '/^FLATNOTES_PATH_PREFIX=/{print \$2}' /opt/flatnotes/.env 2>/dev/null | tail -n1)
port=\${port:-8080}
printf '  Container: flatnotes (%s running)\\n' \"\$running\"
printf '  Service:   flatnotes.service (%s)\\n' \"\$svc_status\"
printf '  Image:     %s\\n' \"\${image:-n/a}\"
printf '  Auth:      %s\\n' \"\${auth:-n/a}\"
printf '  Policy:    %s\\n' \"\$([ \"\$auto\" = '1' ] && echo 'auto-update (re-pull pinned tag)' || echo 'pinned (manual)')\"
printf '  Data:      /opt/flatnotes/data\\n'
printf '  Creds:     /opt/flatnotes/flatnotes.env\\n'
printf '  Logs:      journalctl -u flatnotes.service -f\\n'
printf '  Maintain:  /usr/local/bin/flatnotes-maint.sh [update|auto-update|version]\\n'
printf '  Updates:   systemctl status flatnotes-update.timer\\n'
if [ -n \"\$fqdn\" ]; then
  printf '  Web UI:    https://%s%s/\\n' \"\$fqdn\" \"\$prefix\"
fi
printf '  Web UI:    http://%s:%s%s/\\n' \"\${ip:-n/a}\" \"\$port\" \"\$prefix\"
MOTD

  cat > /etc/update-motd.d/99-footer <<'MOTD'
#!/bin/sh
printf '  ────────────────────────────────────\\n\\n'
MOTD

  chmod +x /etc/update-motd.d/*
"

pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Proxmox UI description ────────────────────────────────────────────────────
FN_DESC_LINK="http://${CT_IP}:${APP_PORT}${APP_WEB_PATH}"
if [[ -n "$APP_FQDN" ]]; then
  FN_DESC_LINK="https://${APP_FQDN}${APP_WEB_PATH}"
fi
FN_DESC="<a href='${FN_DESC_LINK}' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Flatnotes</a>
<details><summary>Details</summary>Flatnotes (Podman/Quadlet) on Debian ${DEBIAN_VERSION} LXC
Auth: ${FLATNOTES_AUTH_TYPE} | Tag: ${APP_TAG}
Created by flatnotes-quadlet.sh</details>"
pct set "$CT_ID" --description "$FN_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "    CT: $CT_ID | IP: ${CT_IP} | Web UI: http://${CT_IP}:${APP_PORT}${APP_WEB_PATH}"
if [[ -n "$APP_FQDN" ]]; then
  echo "    Public:  https://${APP_FQDN}${APP_WEB_PATH}"
fi
echo "    Image:   ${APP_IMAGE}"
echo "    Auth:    ${FLATNOTES_AUTH_TYPE}$([ -n "$FLATNOTES_USERNAME" ] && echo " (user: ${FLATNOTES_USERNAME})")"
echo "    Quadlet: ${QUADLET_FILE}"
echo "    Creds:   ${APP_ENV_FILE}"
echo "    Data:    ${APP_DIR}/data"
echo "    Policy:  $([ "$AUTO_UPDATE" -eq 1 ] && echo "auto-update (re-pull pinned ${APP_TAG})" || echo "pinned (manual)")"
if [[ "$FLATNOTES_AUTH_TYPE" == "totp" ]]; then
  echo ""
  echo "    !! TOTP setup required — add this key to your authenticator app:"
  echo "       Authenticator key: ${FLATNOTES_TOTP_MANUAL_KEY}"
  echo "       QR code + key as printed by Flatnotes:"
  echo "       pct exec $CT_ID -- journalctl -u flatnotes.service -o cat --no-pager -n 60"
fi
echo ""
echo "    pct exec $CT_ID -- systemctl status flatnotes.service"
echo "    pct exec $CT_ID -- journalctl -u flatnotes.service --no-pager -n 50"
echo "    pct exec $CT_ID -- /usr/local/bin/flatnotes-maint.sh update <tag>  # e.g. v5.6.0 — no :latest"
echo "    pct exec $CT_ID -- /usr/local/bin/flatnotes-maint.sh auto-update   # re-pull pinned tag (if AUTO_UPDATE=1)"
echo "    pct exec $CT_ID -- /usr/local/bin/flatnotes-maint.sh version"
echo "    Backup/restore: use PBS or PVE snapshots"
echo ""
echo "    NPM reverse proxy: http | ${CT_IP}:${APP_PORT} (no websockets needed)"
echo "    Port ${APP_PORT} listens on all CT interfaces (Network=host) — restrict with the PVE firewall if needed."
if [[ "$FLATNOTES_AUTH_TYPE" == "none" || "$FLATNOTES_AUTH_TYPE" == "read_only" ]]; then
  echo "    WARNING: auth=${FLATNOTES_AUTH_TYPE} — anyone reaching port ${APP_PORT} can $([ "$FLATNOTES_AUTH_TYPE" = none ] && echo 'read and edit' || echo 'read') your notes."
fi
if [[ "$PODMAN_FUSE_OVERLAY" -eq 1 ]]; then
  echo "    Backups: fuse=1 + fuse-overlayfs can deadlock under snapshot-mode vzdump/PBS (freezer)."
  echo "             Use stop-mode backups for this CT, or test PODMAN_FUSE_OVERLAY=0."
fi
echo "    To change credentials: edit ${APP_ENV_FILE} then systemctl restart flatnotes.service"
echo ""
