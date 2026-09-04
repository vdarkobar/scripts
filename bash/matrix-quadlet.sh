#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID=""                             # empty = auto-assign via pvesh; set e.g. CT_ID=120 to pin
HN="matrix"
CPU=4
RAM=4096
DISK=32                              # media_store grows with uploads + remote media cache (90d retention)
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Matrix / Podman + Quadlet
MATRIX_DOMAIN="example.com"          # Synapse server_name becomes matrix.<domain> — IMMUTABLE after first start
SYNAPSE_PORT=8008                    # Synapse client+federation listener on the CT interface (Network=host, >= 1024)
ELEMENT_PORT=8080                    # Element Web (nginx, non-root) on the CT interface (Network=host, >= 1024)
APP_TZ="Europe/Berlin"
MAX_UPLOAD_SIZE="100M"               # Synapse max_upload_size; match client_max_body_size in NPM.
                                     # 100M = Cloudflare Free/Pro request-body cap; raise only if NPM terminates TLS itself
TAGS="matrix;podman;quadlet;lxc"

# Images / versions
# Synapse: pinned vX.Y.Z from https://github.com/element-hq/synapse/releases
SYNAPSE_IMAGE_REPO="ghcr.io/element-hq/synapse"
SYNAPSE_TAG="v1.160.0"               # pinned; :latest and floating tags are rejected
# Element Web: pinned vX.Y.Z from https://github.com/element-hq/element-web/releases
ELEMENT_IMAGE_REPO="docker.io/vectorim/element-web"
ELEMENT_TAG="v1.12.27"               # pinned; :latest and floating tags are rejected
# PostgreSQL: MAJOR.MINOR only (18.6). "latest" and major-only tags are rejected —
# a major jump (18 → 19) cannot start on the old data directory and needs
# pg_upgrade / dump+restore, which this script does not automate.
POSTGRES_IMAGE_REPO="docker.io/library/postgres"
POSTGRES_TAG="18.6-alpine"           # MAJOR.MINOR like 18.6 (optional -alpine/-trixie suffix)
DEBIAN_VERSION=13

# TURN / VoIP relay (openrelay free tier by default; 500 MB/month relay data)
# For production voice/video, replace TURN_HOST and TURN_SHARED_SECRET with your own coturn.
TURN_HOST="staticauth.openrelay.metered.ca"
TURN_SHARED_SECRET="openrelayprojectsecret"
TURN_USER_LIFETIME_MS=86400000
TURN_ALLOW_GUESTS=0

# Element Web — MapTiler API key (empty = location-sharing map disabled in Element)
MAPTILER_KEY=""

# Auto-update policy
# AUTO_UPDATE=0 (default): timer installed but disabled; manual updates via
#   matrix-maint.sh update <tag> / update-element <tag> / update-postgres <tag>
# AUTO_UPDATE=1: matrix-update.timer re-pulls the CURRENT PINNED TAGS of all
#   three images daily at UPDATE_TIME and restarts only the services whose image
#   ID changed; a failed health check rolls back to the previous images.
#   :latest is never used — a version change is always a deliberate manual step.
AUTO_UPDATE=0
UPDATE_TIME="03:00"                  # local CT time (APP_TZ), HH:MM; timer runs daily

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
APP_DIR="/opt/matrix"
SYNAPSE_IMAGE="${SYNAPSE_IMAGE_REPO}:${SYNAPSE_TAG}"
ELEMENT_IMAGE="${ELEMENT_IMAGE_REPO}:${ELEMENT_TAG}"
POSTGRES_IMAGE="${POSTGRES_IMAGE_REPO}:${POSTGRES_TAG}"
SYNAPSE_FQDN="matrix.${MATRIX_DOMAIN}"
ELEMENT_FQDN="chat.${MATRIX_DOMAIN}"
SYNAPSE_SERVER_NAME="${SYNAPSE_FQDN}" # user IDs are @user:matrix.<domain>; cannot be changed after first start
SYNAPSE_UID=991                      # in-container service user of the Synapse image (start.py drops to it)
SYNAPSE_GID=991
SYNAPSE_DATA_DIR="${APP_DIR}/synapse"
POSTGRES_ENV_FILE="${APP_DIR}/postgres.env"
ELEMENT_CONFIG_FILE="${APP_DIR}/element-config.json"
SYNAPSE_QUADLET_FILE="/etc/containers/systemd/matrix-synapse.container"
SYNAPSE_QUADLET_SERVICE="matrix-synapse.service"
ELEMENT_QUADLET_FILE="/etc/containers/systemd/matrix-element.container"
ELEMENT_QUADLET_SERVICE="matrix-element.service"
POSTGRES_QUADLET_FILE="/etc/containers/systemd/matrix-postgres.container"
POSTGRES_QUADLET_SERVICE="matrix-postgres.service"

# ── Custom configs created by this script ─────────────────────────────────────
#   /etc/containers/systemd/matrix-synapse.container   (Quadlet unit — source of truth)
#   /etc/containers/systemd/matrix-element.container   (Quadlet unit — Element Web, static files)
#   /etc/containers/systemd/matrix-postgres.container  (Quadlet unit — PostgreSQL, loopback only)
#   /opt/matrix/postgres.env                           (POSTGRES_PASSWORD + initdb args — read by Quadlet, 0600)
#   /opt/matrix/element-config.json                    (Element Web config → /app/config.json, 0644)
#   /opt/matrix/.env                                   (runtime state — read by maint script)
#   /opt/matrix/synapse/                               (Synapse /data: homeserver.yaml, signing key,
#                                                       log config, media_store — owned by 991:991)
#   /opt/matrix/synapse/homeserver.yaml                (generated by the image, then patched; 0600)
#   /opt/matrix/postgresdata/                          (PostgreSQL cluster → /var/lib/postgresql)
#   /usr/local/bin/matrix-maint.sh                     (maintenance helper)
#   /etc/systemd/system/matrix-update.service
#   /etc/systemd/system/matrix-update.timer
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/sysctl.d/99-hardening.conf

# ── Config validation ─────────────────────────────────────────────────────────
[[ "$HN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || { echo "  ERROR: HN is not a valid hostname: $HN" >&2; exit 1; }
[[ "$CPU" =~ ^[0-9]+$ ]] && (( CPU >= 1 )) || { echo "  ERROR: CPU must be a positive integer." >&2; exit 1; }
[[ "$RAM" =~ ^[0-9]+$ ]] && (( RAM >= 2048 )) || { echo "  ERROR: RAM must be >= 2048 MB (Synapse + PostgreSQL)." >&2; exit 1; }
[[ "$DISK" =~ ^[0-9]+$ ]] && (( DISK >= 8 )) || { echo "  ERROR: DISK must be >= 8 GB." >&2; exit 1; }
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }
[[ "$SYNAPSE_PORT" =~ ^[0-9]+$ ]] || { echo "  ERROR: SYNAPSE_PORT must be numeric." >&2; exit 1; }
[[ "$ELEMENT_PORT" =~ ^[0-9]+$ ]] || { echo "  ERROR: ELEMENT_PORT must be numeric." >&2; exit 1; }
# Both containers drop privileges before binding (Synapse → 991 via gosu, Element →
# nginx-unprivileged) and share the CT network stack, so ports < 1024 are refused.
(( SYNAPSE_PORT >= 1024 && SYNAPSE_PORT <= 65535 )) || { echo "  ERROR: SYNAPSE_PORT must be between 1024 and 65535 (container binds as non-root)." >&2; exit 1; }
(( ELEMENT_PORT >= 1024 && ELEMENT_PORT <= 65535 )) || { echo "  ERROR: ELEMENT_PORT must be between 1024 and 65535 (container binds as non-root)." >&2; exit 1; }
(( SYNAPSE_PORT != ELEMENT_PORT )) || { echo "  ERROR: SYNAPSE_PORT and ELEMENT_PORT must differ (shared host network)." >&2; exit 1; }
(( SYNAPSE_PORT != 5432 && ELEMENT_PORT != 5432 )) || { echo "  ERROR: port 5432 is reserved for PostgreSQL on the shared host network." >&2; exit 1; }
[[ "$AUTO_UPDATE" =~ ^[01]$ ]] || { echo "  ERROR: AUTO_UPDATE must be 0 or 1." >&2; exit 1; }
[[ "$PODMAN_FUSE_OVERLAY" =~ ^[01]$ ]] || { echo "  ERROR: PODMAN_FUSE_OVERLAY must be 0 or 1." >&2; exit 1; }
[[ "$CLEANUP_ON_FAIL" =~ ^[01]$ ]] || { echo "  ERROR: CLEANUP_ON_FAIL must be 0 or 1." >&2; exit 1; }
# Image repos are interpolated into podman, sed, the Quadlet units and .env.
for v in SYNAPSE_IMAGE_REPO ELEMENT_IMAGE_REPO POSTGRES_IMAGE_REPO; do
  [[ "${!v}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*[A-Za-z0-9]$ ]] || {
    echo "  ERROR: $v must look like registry/namespace/name (no tag, no spaces)." >&2
    exit 1
  }
done
# Synapse: vX.Y.Z (optional rcN). Synapse runs schema deltas on start and they are
# not reversible across every release, so the tag must always be a deliberate choice.
[[ "$SYNAPSE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(rc[0-9]+)?$ ]] || {
  echo "  ERROR: SYNAPSE_TAG must be a pinned version like v1.160.0 — ':latest' and floating tags are not permitted." >&2
  exit 1
}
# Element Web: vX.Y.Z (optional -rc.N).
[[ "$ELEMENT_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] || {
  echo "  ERROR: ELEMENT_TAG must be a pinned version like v1.12.27 — ':latest' and floating tags are not permitted." >&2
  exit 1
}
# PostgreSQL: MAJOR.MINOR (18.6), optional variant suffix. No "latest", no major-only:
# a silent major bump would leave a cluster the new binaries cannot open.
[[ "$POSTGRES_TAG" =~ ^[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || {
  echo "  ERROR: POSTGRES_TAG must be MAJOR.MINOR like 18.6 — 'latest' and major-only tags (18) are not accepted." >&2
  exit 1
}
[[ "$MATRIX_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]] \
  || { echo "  ERROR: MATRIX_DOMAIN is not a valid domain: $MATRIX_DOMAIN" >&2; exit 1; }
[[ "$MAX_UPLOAD_SIZE" =~ ^[0-9]+[KMG]$ ]] || { echo "  ERROR: MAX_UPLOAD_SIZE must look like 200M or 1G." >&2; exit 1; }
[[ "$TURN_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "  ERROR: TURN_HOST contains invalid characters." >&2; exit 1; }
[[ -n "$TURN_SHARED_SECRET" && ! "$TURN_SHARED_SECRET" =~ [\"\'\\] ]] || { echo "  ERROR: TURN_SHARED_SECRET must be non-empty and must not contain quotes or backslashes." >&2; exit 1; }
[[ "$TURN_USER_LIFETIME_MS" =~ ^[0-9]+$ ]] || { echo "  ERROR: TURN_USER_LIFETIME_MS must be numeric." >&2; exit 1; }
[[ "$TURN_ALLOW_GUESTS" =~ ^[01]$ ]] || { echo "  ERROR: TURN_ALLOW_GUESTS must be 0 or 1." >&2; exit 1; }
if [[ -n "$MAPTILER_KEY" && ! "$MAPTILER_KEY" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "  ERROR: MAPTILER_KEY contains invalid characters." >&2
  exit 1
fi
[[ "$UPDATE_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "  ERROR: UPDATE_TIME must be HH:MM (24h), e.g. 03:00." >&2; exit 1; }
[[ -e "/usr/share/zoneinfo/${APP_TZ}" ]] || { echo "  ERROR: APP_TZ not found in /usr/share/zoneinfo: $APP_TZ" >&2; exit 1; }
[[ "$APP_TZ" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)+$ ]] || { echo "  ERROR: APP_TZ contains invalid characters." >&2; exit 1; }
[[ "$TAGS" =~ ^[A-Za-z0-9._-]+(;[A-Za-z0-9._-]+)*$ ]] || { echo "  ERROR: TAGS must be a semicolon-separated list without spaces." >&2; exit 1; }
for pkg in "${EXTRA_PACKAGES[@]}"; do
  [[ "$pkg" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || { echo "  ERROR: Invalid package name in EXTRA_PACKAGES: $pkg" >&2; exit 1; }
done

# ── Trap cleanup ──────────────────────────────────────────────────────────────
# rc is captured before the trap is reset; $LINENO is the failing line at top
# level (BASH_LINENO[0] is 0 outside a function). After CREATED=1, failing
# checks must use `false` rather than `exit 1` so this trap runs cleanup.
trap 'rc=$?;
  trap - ERR
  echo "  ERROR: failed (rc=$rc) near line ${LINENO:-?}" >&2
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

  Matrix Quadlet LXC Creator — Configuration
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
  Synapse image:     $SYNAPSE_IMAGE
  Element image:     $ELEMENT_IMAGE
  PostgreSQL image:  $POSTGRES_IMAGE (127.0.0.1:5432)
  Domain:            $MATRIX_DOMAIN
  Server name:       $SYNAPSE_SERVER_NAME  (user IDs @user:${SYNAPSE_SERVER_NAME} — IMMUTABLE after first start)
  Synapse FQDN:      $SYNAPSE_FQDN -> port $SYNAPSE_PORT
  Element FQDN:      $ELEMENT_FQDN -> port $ELEMENT_PORT
  Listens on:        0.0.0.0:${SYNAPSE_PORT} + 0.0.0.0:${ELEMENT_PORT} inside the CT (Network=host) — reachable from the whole LAN
  Max upload:        $MAX_UPLOAD_SIZE
  TURN host:         $TURN_HOST
  TURN guests:       $([ "$TURN_ALLOW_GUESTS" -eq 1 ] && echo "allowed" || echo "denied")
  MapTiler key:      $([ -n "$MAPTILER_KEY" ] && echo "set" || echo "unset (map feature disabled)")
  Timezone:          $APP_TZ
  Podman storage:    $([ "$PODMAN_FUSE_OVERLAY" -eq 1 ] && echo "fuse-overlayfs (fuse=1)" || echo "native overlay (no FUSE)")
  Tags:              $TAGS
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled — daily at ${UPDATE_TIME} (re-pull ${SYNAPSE_TAG} / ${ELEMENT_TAG} / ${POSTGRES_TAG})" || echo "disabled (${SYNAPSE_TAG} / ${ELEMENT_TAG} / ${POSTGRES_TAG}, manual)")
  Cleanup on fail:   $CLEANUP_ON_FAIL (until first service start; CT preserved after that)
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/matrix-quadlet.sh"
SCRIPT_LOCAL="/root/matrix-quadlet.sh"
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

# ── Generate secrets ──────────────────────────────────────────────────────────
# DB_PASSWORD goes into homeserver.yaml (quoted) and postgres.env (unquoted),
# so it is alphanumeric only. Synapse generates its own macaroon/form/registration
# secrets and signing key during `generate`.
set +o pipefail
DB_PASSWORD="$(head -c 4096 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 40)"
set -o pipefail
[[ ${#DB_PASSWORD} -eq 40 ]] || { echo "  ERROR: Failed to generate secrets." >&2; exit 1; }

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
[[ -n "$CT_IP" ]] || { echo "  ERROR: No IPv4 address acquired via DHCP within timeout." >&2; false; }
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
# python3 is used once below to patch the generated homeserver.yaml (the standard
# template does not guarantee it; unattended-upgrades would pull it in later anyway).
PODMAN_FUSE_PKG=""
[[ "$PODMAN_FUSE_OVERLAY" -eq 1 ]] && PODMAN_FUSE_PKG="fuse-overlayfs"

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y locales curl ca-certificates iproute2 podman tar gzip python3 ${PODMAN_FUSE_PKG}
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
[[ "$CGROUPS_VERSION" == "v2" ]] || { echo "  ERROR: Quadlet requires cgroup v2 inside the CT; podman reports '${CGROUPS_VERSION}'." >&2; false; }
GRAPH_DRIVER="$(pct exec "$CT_ID" -- podman info --format '{{.Store.GraphDriverName}}' 2>/dev/null || echo "?")"
[[ "$GRAPH_DRIVER" == "overlay" ]] || { echo "  ERROR: Podman storage driver is '${GRAPH_DRIVER}', expected overlay." >&2; false; }
echo "  Podman: cgroup ${CGROUPS_VERSION}, storage driver ${GRAPH_DRIVER}$([ "$PODMAN_FUSE_OVERLAY" -eq 1 ] && echo " (fuse-overlayfs)" || echo " (native)")"

# ── Pull images ───────────────────────────────────────────────────────────────
for img in "$POSTGRES_IMAGE" "$SYNAPSE_IMAGE" "$ELEMENT_IMAGE"; do
  echo "  Pulling image: ${img} ..."
  pct exec "$CT_ID" -- bash -lc "
    set -euo pipefail
    podman pull '${img}'
  "
done

# ── Detect container UIDs/GIDs for bind mounts ────────────────────────────────
# PostgreSQL drops to its own service user before touching the mount; the UID
# differs between the Debian (999) and Alpine (70) variants, so read it from
# the image instead of hardcoding. Synapse's start.py drops to UID/GID from the
# environment (991:991 is the image default) — that value is ours to choose and
# is passed explicitly to both `generate` and the Quadlet unit. Element Web is
# nginx-unprivileged and only reads a root-owned 0644 config file.
# --network none: the probes need no network and must not touch Netavark.
POSTGRES_UID="$(pct exec "$CT_ID" -- podman run --rm --network none --entrypoint sh "$POSTGRES_IMAGE" -c 'id -u postgres 2>/dev/null || id -u' 2>/dev/null | tr -d '\r')"
POSTGRES_GID="$(pct exec "$CT_ID" -- podman run --rm --network none --entrypoint sh "$POSTGRES_IMAGE" -c 'id -g postgres 2>/dev/null || id -g' 2>/dev/null | tr -d '\r')"

for v in POSTGRES_UID POSTGRES_GID; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "  ERROR: Failed to detect numeric $v from the PostgreSQL image." >&2; false; }
done
echo "  Bind-mount ownership: postgres=${POSTGRES_UID}:${POSTGRES_GID} synapse=${SYNAPSE_UID}:${SYNAPSE_GID}"

# ── Prepare persistent paths ──────────────────────────────────────────────────
# Matrix stack persistent state (all of it):
#   /opt/matrix/postgresdata/         PostgreSQL cluster (→ /var/lib/postgresql; PG18 puts
#                                     PGDATA at <mount>/18/docker — initdb creates it)
#   /opt/matrix/synapse/              Synapse /data: homeserver.yaml, <server_name>.signing.key,
#                                     <server_name>.log.config, media_store/ (uploads + remote
#                                     media cache) — everything Synapse writes lives here
#   /opt/matrix/element-config.json   Element Web config (script-managed, regenerate by hand)
#   /opt/matrix/postgres.env          PostgreSQL password (must match homeserver.yaml) + initdb args
# Only the top-level mount directories are created here; PostgreSQL initializes
# its own cluster and Synapse creates media_store on first start.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  install -d -m 0755 '${APP_DIR}'
  install -d -m 0750 -o ${POSTGRES_UID} -g ${POSTGRES_GID} '${APP_DIR}/postgresdata'
  install -d -m 0750 -o ${SYNAPSE_UID}  -g ${SYNAPSE_GID}  '${SYNAPSE_DATA_DIR}'
"

# ── Generate Synapse homeserver.yaml ──────────────────────────────────────────
# The image's `generate` mode writes homeserver.yaml, the signing key and the log
# config into /data (as UID:GID) with --open-private-ports, i.e. the listener
# binds all interfaces — required for Network=host. The server_name written here
# is permanent: it is baked into every user ID and event this homeserver signs.
echo "  Generating Synapse configuration for server_name ${SYNAPSE_SERVER_NAME} ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman run --rm --network none \
    -v '${SYNAPSE_DATA_DIR}:/data' \
    -e SYNAPSE_SERVER_NAME='${SYNAPSE_SERVER_NAME}' \
    -e SYNAPSE_REPORT_STATS=no \
    -e UID=${SYNAPSE_UID} \
    -e GID=${SYNAPSE_GID} \
    '${SYNAPSE_IMAGE}' generate
  test -f '${SYNAPSE_DATA_DIR}/homeserver.yaml'
  test -f '${SYNAPSE_DATA_DIR}/${SYNAPSE_SERVER_NAME}.signing.key'
  test -f '${SYNAPSE_DATA_DIR}/${SYNAPSE_SERVER_NAME}.log.config'
"
echo "  homeserver.yaml, signing key and log config generated"

# ── Patch homeserver.yaml ─────────────────────────────────────────────────────
# 1) Remove the generated SQLite database block (PostgreSQL is appended below).
# 2) Move the HTTP listener from 8008 to SYNAPSE_PORT — with Network=host there is
#    no port mapping, the container binds SYNAPSE_PORT directly on the CT.
# Both edits fail loudly if the upstream layout changed; the file keeps its
# 991:991 ownership because python rewrites the existing inode.
echo "  Patching homeserver.yaml ..."
pct exec "$CT_ID" -- python3 - "${SYNAPSE_DATA_DIR}/homeserver.yaml" "${SYNAPSE_PORT}" <<'PYEOF'
import re
import sys

path, port = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()

content, n = re.subn(
    r'\ndatabase:\s*\n\s+name:\s*sqlite3\s*\n\s+args:\s*\n\s+database:\s*/data/homeserver\.db\s*\n',
    '\n',
    content,
)
if n != 1:
    sys.exit("ERROR: SQLite database block not found exactly once in homeserver.yaml — upstream format may have changed.")

content, n = re.subn(r'^([ \t]*- port: )8008$', r'\g<1>' + port, content, flags=re.M)
if n != 1:
    sys.exit("ERROR: listener 'port: 8008' not found exactly once in homeserver.yaml — upstream format may have changed.")

with open(path, 'w') as f:
    f.write(content)
PYEOF

# Build TURN guest flag as yaml literal
TURN_ALLOW_GUESTS_YAML="false"
[[ "$TURN_ALLOW_GUESTS" -eq 1 ]] && TURN_ALLOW_GUESTS_YAML="true"

# Append production configuration. Streamed over stdin so DB_PASSWORD never
# appears in host or CT argv. PostgreSQL is reached on 127.0.0.1 (shared host
# network). Synapse serves both /.well-known/matrix/{server,client} itself
# (serve_server_wellknown + public_baseurl), so the reverse proxy needs no
# custom well-known locations — a plain proxy host for matrix.<domain> is enough.
{
  cat <<EOF2

# ── Production configuration (appended by matrix-quadlet.sh) ─────────────────

database:
  name: psycopg2
  txn_limit: 10000
  args:
    user: synapse
    password: "${DB_PASSWORD}"
    database: synapse
    host: 127.0.0.1
    port: 5432
    cp_min: 5
    cp_max: 10

public_baseurl: "https://${SYNAPSE_FQDN}/"
serve_server_wellknown: true
default_identity_server: "https://vector.im"

suppress_key_server_warning: true
max_upload_size: ${MAX_UPLOAD_SIZE}
enable_registration: true
registration_requires_token: true

presence:
  enabled: true

media_retention:
  remote_media_lifetime: 90d

forgotten_room_retention_period: 7d

turn_uris:
  - "turns:${TURN_HOST}:443?transport=tcp"
  - "turn:${TURN_HOST}:80?transport=udp"
  - "turn:${TURN_HOST}:443?transport=tcp"
turn_shared_secret: "${TURN_SHARED_SECRET}"
turn_user_lifetime: ${TURN_USER_LIFETIME_MS}
turn_allow_guests: ${TURN_ALLOW_GUESTS_YAML}

url_preview_enabled: true
url_preview_ip_range_blacklist:
  - '127.0.0.0/8'
  - '10.0.0.0/8'
  - '172.16.0.0/12'
  - '192.168.0.0/16'
  - '100.64.0.0/10'
  - '192.0.0.0/24'
  - '169.254.0.0/16'
  - '198.51.100.0/24'
  - '203.0.113.0/24'
  - '224.0.0.0/4'
  - '::1/128'
  - 'fe80::/10'
  - 'fc00::/7'
  - '2001:db8::/32'
  - 'ff00::/8'
  - 'fec0::/10'
EOF2
} | pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat >> '${SYNAPSE_DATA_DIR}/homeserver.yaml'
  chown ${SYNAPSE_UID}:${SYNAPSE_GID} '${SYNAPSE_DATA_DIR}/homeserver.yaml'
  chmod 0600 '${SYNAPSE_DATA_DIR}/homeserver.yaml'
"

# Validate patch
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cfg='${SYNAPSE_DATA_DIR}/homeserver.yaml'
  grep -q '^  name: psycopg2'          \"\$cfg\" || { echo '  ERROR: psycopg2 not found in homeserver.yaml' >&2; exit 1; }
  grep -q '^public_baseurl:'           \"\$cfg\" || { echo '  ERROR: public_baseurl not found in homeserver.yaml' >&2; exit 1; }
  grep -q '^turn_shared_secret:'       \"\$cfg\" || { echo '  ERROR: turn_shared_secret not found in homeserver.yaml' >&2; exit 1; }
  grep -q '^  - port: ${SYNAPSE_PORT}\$' \"\$cfg\" || { echo '  ERROR: listener port ${SYNAPSE_PORT} not found in homeserver.yaml' >&2; exit 1; }
  ! grep -q 'name: sqlite3'            \"\$cfg\" || { echo '  ERROR: sqlite3 still present in homeserver.yaml' >&2; exit 1; }
  grep -q '^registration_shared_secret:' \"\$cfg\" || echo '  WARNING: registration_shared_secret not found — register_new_matrix_user -c will not work until one is added' >&2
  echo '  homeserver.yaml validated'
"

# ── Element Web config ────────────────────────────────────────────────────────
# Mounted read-only at /app/config.json. Element talks to Synapse through the
# public base_url (https://matrix.<domain>), so DNS + reverse proxy must exist
# before Element is usable; for LAN-only tests point base_url at
# http://<CT-IP>:SYNAPSE_PORT and restart matrix-element.service.
# The MapTiler key is optional; without it the map_style_url key is omitted and
# Element's location-sharing map stays disabled. Element runs as nginx-unprivileged
# (uid 101) and only needs to read this file — root:root 0644.
MAP_STYLE_JSON=""
if [[ -n "$MAPTILER_KEY" ]]; then
  MAP_STYLE_JSON=",
    \"map_style_url\": \"https://api.maptiler.com/maps/streets/style.json?key=${MAPTILER_KEY}\""
fi

{
  cat <<EOF2
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://${SYNAPSE_FQDN}",
            "server_name": "${SYNAPSE_SERVER_NAME}"
        },
        "m.identity_server": {
            "base_url": "https://vector.im"
        }
    },
    "brand": "Element",
    "integrations_ui_url": "https://scalar.vector.im/",
    "integrations_rest_url": "https://scalar.vector.im/api",
    "integrations_widgets_urls": [
        "https://scalar.vector.im/_matrix/integrations/v1",
        "https://scalar.vector.im/api",
        "https://scalar-staging.vector.im/_matrix/integrations/v1",
        "https://scalar-staging.vector.im/api"
    ],
    "showLabsSettings": true,
    "roomDirectory": {
        "servers": ["${SYNAPSE_SERVER_NAME}", "matrix.org"]
    },
    "enable_presence_by_hs_url": {
        "https://matrix.org": false,
        "https://matrix-client.matrix.org": false
    },
    "features": {}${MAP_STYLE_JSON}
}
EOF2
} | pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > '${ELEMENT_CONFIG_FILE}'
  chmod 0644 '${ELEMENT_CONFIG_FILE}'
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '${ELEMENT_CONFIG_FILE}'
"
echo "  Element config written: ${ELEMENT_CONFIG_FILE}"

# ── Quadlet unit files ────────────────────────────────────────────────────────
# Rootful Quadlet: /etc/containers/systemd/ — no linger, no --user flags needed.
# systemd daemon-reload triggers the Quadlet generator; the three *.service
# units are created as transient units and WantedBy=multi-user.target handles
# boot start.
# Network=host bypasses Netavark NAT issues on Debian LXC. All three containers
# share the CT network stack: PostgreSQL is told to listen on 127.0.0.1 only and
# Synapse reaches it there; Synapse binds SYNAPSE_PORT (patched into its
# listener) and Element binds ELEMENT_PORT (ELEMENT_WEB_PORT) directly on the CT
# interface instead of PublishPort=.
# PostgreSQL carries a HealthCmd and Notify=healthy: systemd only marks it active
# once pg_isready succeeds, so Synapse's Requires=/After= really waits for a
# usable database (Synapse runs its schema deltas at startup and needs the DB
# immediately). TimeoutStartSec must exceed HealthStartPeriod plus initdb.
# Synapse gets a HealthCmd for `podman ps` visibility but NO Notify=healthy:
# schema migrations after a version bump can take minutes and must not be
# killed by a start timeout. Element is static files and does not depend on
# Synapse — it stays up while Synapse restarts or is updated.
# Secrets: POSTGRES_PASSWORD lives in postgres.env (0600) via EnvironmentFile=,
# the DB password Synapse uses is inside homeserver.yaml (0600, 991:991) —
# the unit files contain none and can stay 0644.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  mkdir -p /etc/containers/systemd

  cat > '${POSTGRES_QUADLET_FILE}' <<EOF2
[Unit]
Description=PostgreSQL for Matrix Synapse
After=network-online.target
Wants=network-online.target

[Container]
Image=${POSTGRES_IMAGE}
ContainerName=matrix-postgres
Network=host
Exec=postgres -c listen_addresses=127.0.0.1
Environment=TZ=${APP_TZ}
Environment=POSTGRES_DB=synapse
Environment=POSTGRES_USER=synapse
EnvironmentFile=${POSTGRES_ENV_FILE}
Volume=${APP_DIR}/postgresdata:/var/lib/postgresql
ShmSize=512m
HealthCmd=pg_isready -h 127.0.0.1 -U synapse -d synapse
HealthInterval=10s
HealthTimeout=5s
HealthRetries=5
HealthStartPeriod=30s
Notify=healthy
LogDriver=journald

[Service]
Restart=always
TimeoutStartSec=180
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF2

  cat > '${SYNAPSE_QUADLET_FILE}' <<EOF2
[Unit]
Description=Matrix Synapse homeserver
After=network-online.target ${POSTGRES_QUADLET_SERVICE}
Wants=network-online.target
Requires=${POSTGRES_QUADLET_SERVICE}

[Container]
Image=${SYNAPSE_IMAGE}
ContainerName=matrix-synapse
Network=host
Environment=TZ=${APP_TZ}
Environment=UID=${SYNAPSE_UID}
Environment=GID=${SYNAPSE_GID}
Environment=SYNAPSE_CONFIG_PATH=/data/homeserver.yaml
Volume=${SYNAPSE_DATA_DIR}:/data
Ulimit=nofile=65535:65535
HealthCmd=curl -fsS -o /dev/null http://127.0.0.1:${SYNAPSE_PORT}/health
HealthInterval=30s
HealthTimeout=10s
HealthRetries=3
HealthStartPeriod=60s
LogDriver=journald

[Service]
Restart=always
RestartSec=5
TimeoutStopSec=90

[Install]
WantedBy=multi-user.target
EOF2

  cat > '${ELEMENT_QUADLET_FILE}' <<EOF2
[Unit]
Description=Element Web for Matrix
After=network-online.target
Wants=network-online.target

[Container]
Image=${ELEMENT_IMAGE}
ContainerName=matrix-element
Network=host
Environment=TZ=${APP_TZ}
Environment=ELEMENT_WEB_PORT=${ELEMENT_PORT}
Volume=${ELEMENT_CONFIG_FILE}:/app/config.json:ro
LogDriver=journald

[Service]
Restart=always
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF2

  chmod 0644 '${POSTGRES_QUADLET_FILE}' '${SYNAPSE_QUADLET_FILE}' '${ELEMENT_QUADLET_FILE}'
"

# ── Container credentials file ────────────────────────────────────────────────
# Read by Quadlet via EnvironmentFile= (podman --env-file). Written UNQUOTED —
# podman keeps quotes as part of the value. Streamed over stdin so the
# credential never appears in host or CT argv, and no temp file is created.
# POSTGRES_INITDB_ARGS lives here too: Quadlet word-splits Environment= values
# like systemd, which would drop the collate/ctype flags and give Synapse an
# en_US cluster it refuses to start on. --env-file keeps the line verbatim.
# It is only read once, when initdb creates the cluster.
{
  printf '# PostgreSQL container environment — managed by matrix-quadlet.sh\n'
  printf '# POSTGRES_PASSWORD must match database.args.password in %s/homeserver.yaml\n' "$SYNAPSE_DATA_DIR"
  printf 'POSTGRES_PASSWORD=%s\n' "$DB_PASSWORD"
  printf 'POSTGRES_INITDB_ARGS=--encoding=UTF8 --lc-collate=C --lc-ctype=C\n'
} | pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  umask 077
  cat > '${POSTGRES_ENV_FILE}'
  chmod 0600 '${POSTGRES_ENV_FILE}'
"
unset DB_PASSWORD

# ── Runtime state file ────────────────────────────────────────────────────────
# .env is not read by Quadlet or systemd. It is the maint script's source of
# truth for current image tags and policy flags. Keep it in sync with the
# Quadlet units whenever an image is updated. No secrets live here.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > '${APP_DIR}/.env' <<EOF2
SYNAPSE_IMAGE_REPO=${SYNAPSE_IMAGE_REPO}
SYNAPSE_TAG=${SYNAPSE_TAG}
SYNAPSE_IMAGE=${SYNAPSE_IMAGE}
ELEMENT_IMAGE_REPO=${ELEMENT_IMAGE_REPO}
ELEMENT_TAG=${ELEMENT_TAG}
ELEMENT_IMAGE=${ELEMENT_IMAGE}
POSTGRES_IMAGE_REPO=${POSTGRES_IMAGE_REPO}
POSTGRES_TAG=${POSTGRES_TAG}
POSTGRES_IMAGE=${POSTGRES_IMAGE}
MATRIX_DOMAIN=${MATRIX_DOMAIN}
SYNAPSE_SERVER_NAME=${SYNAPSE_SERVER_NAME}
SYNAPSE_FQDN=${SYNAPSE_FQDN}
ELEMENT_FQDN=${ELEMENT_FQDN}
SYNAPSE_PORT=${SYNAPSE_PORT}
ELEMENT_PORT=${ELEMENT_PORT}
APP_TZ=${APP_TZ}
AUTO_UPDATE=${AUTO_UPDATE}
EOF2
  chmod 0600 '${APP_DIR}/.env'
"

# ── Maintenance script ────────────────────────────────────────────────────────
# update <tag>:          Synapse — guards → pull → sed Image= in Quadlet file →
#   sed .env → daemon-reload → restart → /health check; rollback restores both
#   files, re-tags the previous image ID, daemon-reload, restart. Synapse applies
#   schema deltas at startup; older images cannot always run on a newer schema —
#   the PVE snapshot taken before the update is the real rollback.
# update-element <tag>:  same flow for the Element Web unit (static files, no
#   schema — rollback is always clean).
# update-postgres <tag>: same flow for the PostgreSQL unit, same MAJOR only
#   (minor releases share the data format; a major jump needs pg_upgrade).
#   Synapse is restarted afterwards (Requires= stops it with the DB).
# auto-update:  re-pull ALL THREE current pinned tags; restart only what changed
#   (+ Synapse whenever PostgreSQL changed); rollback re-tags the previous
#   image IDs and restarts. Tags are never changed by the timer.
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/matrix-maint.sh && chmod 0755 /usr/local/bin/matrix-maint.sh' <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR="${APP_DIR:-/opt/matrix}"
SYNAPSE_QUADLET_FILE="/etc/containers/systemd/matrix-synapse.container"
ELEMENT_QUADLET_FILE="/etc/containers/systemd/matrix-element.container"
POSTGRES_QUADLET_FILE="/etc/containers/systemd/matrix-postgres.container"
SYNAPSE_SERVICE="matrix-synapse.service"
ELEMENT_SERVICE="matrix-element.service"
POSTGRES_SERVICE="matrix-postgres.service"
SYNAPSE_CONTAINER="matrix-synapse"
ELEMENT_CONTAINER="matrix-element"
POSTGRES_CONTAINER="matrix-postgres"
ENV_FILE="${APP_DIR}/.env"

need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF2
  Matrix Maintenance (Quadlet)
  ────────────────────────────
  Usage:
    $0 update <tag> [--yes]            # Synapse:    pinned vX.Y.Z, e.g. v1.161.0 — no :latest
    $0 update-element <tag> [--yes]    # Element:    pinned vX.Y.Z, e.g. v1.12.28 — no :latest
    $0 update-postgres <tag> [--yes]   # PostgreSQL: MAJOR.MINOR only, same major (e.g. 18.7-alpine)
    $0 auto-update                     # re-pull all current pinned tags (only if AUTO_UPDATE=1)
    $0 version

  Notes:
    - update pulls the tag, updates the Quadlet unit and .env, restarts the service
    - read https://element-hq.github.io/synapse/latest/upgrade.html before a Synapse
      update; schema deltas run on start and an older image may not start on the
      new schema — restore the PVE snapshot in that case
    - PostgreSQL major upgrades (18 → 19) are NOT automated: dump/restore or
      pg_upgrade manually, then set the new tag
    - :latest and floating tags (v1, 18, 18-alpine) are not permitted
    - auto-update is called by matrix-update.timer; it never changes the tags
    - backup and restore are handled by PBS and PVE snapshots
    - take a PVE snapshot before manual updates: pct snapshot <CT_ID> pre-update-\$(date +%Y%m%d)
EOF2
}

[[ -d "$APP_DIR" ]]               || die "APP_DIR not found: $APP_DIR"
[[ -f "$ENV_FILE" ]]              || die "Missing env file: $ENV_FILE"
[[ -f "$SYNAPSE_QUADLET_FILE" ]]  || die "Missing Quadlet unit: $SYNAPSE_QUADLET_FILE"
[[ -f "$ELEMENT_QUADLET_FILE" ]]  || die "Missing Quadlet unit: $ELEMENT_QUADLET_FILE"
[[ -f "$POSTGRES_QUADLET_FILE" ]] || die "Missing Quadlet unit: $POSTGRES_QUADLET_FILE"

# One maintenance operation at a time — a manual update must not overlap the timer.
LOCK_FILE="/run/lock/matrix-maint.lock"
mkdir -p /run/lock
exec 9>"$LOCK_FILE"
flock -n 9 || die "Another matrix-maint.sh operation is already running."

env_val() {
  awk -F= -v key="$1" '$1==key{print substr($0, length(key)+2)}' "$ENV_FILE" | tail -n1
}

env_flag() {
  local raw
  raw="$(env_val "$1" | tr -d '[:space:]')"
  [[ "$raw" =~ ^[01]$ ]] && printf '%s' "$raw" || printf '0'
}

synapse_port() {
  local port
  port="$(env_val SYNAPSE_PORT | tr -d '[:space:]')"
  [[ "$port" =~ ^[0-9]+$ ]] && printf '%s' "$port" || printf '8008'
}

element_port() {
  local port
  port="$(env_val ELEMENT_PORT | tr -d '[:space:]')"
  [[ "$port" =~ ^[0-9]+$ ]] && printf '%s' "$port" || printf '8080'
}

synapse_image()  { env_val SYNAPSE_IMAGE; }
synapse_repo()   { env_val SYNAPSE_IMAGE_REPO; }
synapse_tag()    { local img; img="$(synapse_image)"; echo "${img##*:}"; }
element_image()  { env_val ELEMENT_IMAGE; }
element_repo()   { env_val ELEMENT_IMAGE_REPO; }
element_tag()    { local img; img="$(element_image)"; echo "${img##*:}"; }
postgres_image() { env_val POSTGRES_IMAGE; }
postgres_repo()  { env_val POSTGRES_IMAGE_REPO; }
postgres_tag()   { local img; img="$(postgres_image)"; echo "${img##*:}"; }

running_image_id() {
  podman inspect --format '{{.Image}}' "$1" 2>/dev/null || true
}

image_id_of() {
  podman image inspect --format '{{.Id}}' "$1" 2>/dev/null || true
}

# /health returns 200 once the listener is up, i.e. after schema deltas and
# startup completed. Long loop: migrations on a big database can take a while.
wait_for_synapse() {
  local port code
  port="$(synapse_port)"
  for i in $(seq 1 90); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${port}/health" 2>/dev/null || echo 000)"
    [[ "$code" == "200" ]] && return 0
    sleep 2
  done
  return 1
}

wait_for_element() {
  local port code
  port="$(element_port)"
  for i in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${port}/" 2>/dev/null || echo 000)"
    [[ "$code" == "200" ]] && return 0
    sleep 2
  done
  return 1
}

wait_for_postgres() {
  for i in $(seq 1 30); do
    if podman exec "$POSTGRES_CONTAINER" pg_isready -h 127.0.0.1 -U synapse -d synapse >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

confirm_or_exit() {
  echo ""
  echo "  IMPORTANT: Take a PVE snapshot before proceeding."
  echo "  Use: pct snapshot <CT_ID> pre-update-$(date +%Y%m%d)"
  echo ""
  read -r -p "  Continue? [y/N]: " confirm
  case "$confirm" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) echo "  Aborted."; return 1 ;;
  esac
}

# update <tag> [--yes] — move Synapse to another pinned version
update_synapse() {
  local new_tag="" skip_confirm=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) skip_confirm=1; shift ;;
      *) new_tag="$1"; shift ;;
    esac
  done

  local old_tag repo old_image new_image old_id tmp_env tmp_quadlet
  [[ -n "$new_tag" ]] || die "Usage: matrix-maint.sh update <tag>"
  [[ "$new_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(rc[0-9]+)?$ ]] \
    || die "Invalid tag: $new_tag — pinned version required (e.g. v1.161.0), ':latest' and floating tags are not permitted."

  old_tag="$(synapse_tag)"
  repo="$(synapse_repo)"
  [[ -n "$repo" ]] || die "Could not read SYNAPSE_IMAGE_REPO from .env"
  old_image="$(synapse_image)"
  new_image="${repo}:${new_tag}"
  # Capture the current image ID before pulling: if new_tag == old_tag, the pull
  # moves the tag and the old ref would otherwise resolve to the NEW image on rollback.
  old_id="$(image_id_of "$old_image")"
  tmp_env="$(mktemp)"
  tmp_quadlet="$(mktemp)"

  echo "  Current Synapse tag: $old_tag"
  echo "  Target  Synapse tag: $new_tag"
  echo "  Upgrade notes:       https://element-hq.github.io/synapse/latest/upgrade.html"

  # Pre-update guard: a Synapse restart runs schema deltas; refuse if the DB is not there.
  wait_for_postgres || die "PostgreSQL is not ready — fix ${POSTGRES_SERVICE} before updating Synapse."

  if [[ "$skip_confirm" -eq 0 ]]; then
    confirm_or_exit || { rm -f "$tmp_env" "$tmp_quadlet"; exit 0; }
  fi

  cp -a "$ENV_FILE"             "$tmp_env"
  cp -a "$SYNAPSE_QUADLET_FILE" "$tmp_quadlet"

  cleanup() { rm -f "$tmp_env" "$tmp_quadlet"; }
  rollback() {
    echo "  !! Synapse update failed — rolling back and restarting ..." >&2
    cp -a "$tmp_env"     "$ENV_FILE"
    cp -a "$tmp_quadlet" "$SYNAPSE_QUADLET_FILE"
    [[ -n "$old_id" ]] && podman tag "$old_id" "$old_image" >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl restart "$SYNAPSE_SERVICE" || true
    rm -f "$tmp_env" "$tmp_quadlet"
    if wait_for_synapse; then
      echo "  Rollback complete — ${old_image} is healthy again." >&2
    else
      echo "  CRITICAL: rollback to ${old_image} did not become healthy (schema may already be migrated). Restore the CT from the PVE snapshot / PBS." >&2
    fi
  }
  trap rollback ERR

  echo "  Pulling target image ..."
  podman pull "$new_image"

  sed -i "s|^Image=.*|Image=${new_image}|" "$SYNAPSE_QUADLET_FILE"
  sed -i \
    -e "s|^SYNAPSE_TAG=.*|SYNAPSE_TAG=$new_tag|" \
    -e "s|^SYNAPSE_IMAGE=.*|SYNAPSE_IMAGE=$new_image|" \
    "$ENV_FILE"

  echo "  Reloading Quadlet and restarting Synapse ..."
  systemctl daemon-reload
  systemctl restart "$SYNAPSE_SERVICE"

  echo "  Waiting for Synapse (schema deltas may take a moment) ..."
  if ! wait_for_synapse; then
    trap - ERR
    rollback
    die "Synapse did not become healthy after update."
  fi

  trap - ERR
  cleanup
  if [[ -n "$old_id" && "$old_id" != "$(image_id_of "$new_image")" ]]; then
    podman rmi "$old_id" >/dev/null 2>&1 || true
  fi
  echo "  OK: Synapse updated to $new_tag"
}

# update-element <tag> [--yes] — move Element Web to another pinned version
update_element() {
  local new_tag="" skip_confirm=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) skip_confirm=1; shift ;;
      *) new_tag="$1"; shift ;;
    esac
  done

  local old_tag repo old_image new_image old_id tmp_env tmp_quadlet
  [[ -n "$new_tag" ]] || die "Usage: matrix-maint.sh update-element <tag>"
  [[ "$new_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] \
    || die "Invalid tag: $new_tag — pinned version required (e.g. v1.12.28), ':latest' and floating tags are not permitted."

  old_tag="$(element_tag)"
  repo="$(element_repo)"
  [[ -n "$repo" ]] || die "Could not read ELEMENT_IMAGE_REPO from .env"
  old_image="$(element_image)"
  new_image="${repo}:${new_tag}"
  old_id="$(image_id_of "$old_image")"
  tmp_env="$(mktemp)"
  tmp_quadlet="$(mktemp)"

  echo "  Current Element tag: $old_tag"
  echo "  Target  Element tag: $new_tag"

  if [[ "$skip_confirm" -eq 0 ]]; then
    confirm_or_exit || { rm -f "$tmp_env" "$tmp_quadlet"; exit 0; }
  fi

  cp -a "$ENV_FILE"             "$tmp_env"
  cp -a "$ELEMENT_QUADLET_FILE" "$tmp_quadlet"

  cleanup() { rm -f "$tmp_env" "$tmp_quadlet"; }
  rollback() {
    echo "  !! Element update failed — rolling back and restarting ..." >&2
    cp -a "$tmp_env"     "$ENV_FILE"
    cp -a "$tmp_quadlet" "$ELEMENT_QUADLET_FILE"
    [[ -n "$old_id" ]] && podman tag "$old_id" "$old_image" >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl restart "$ELEMENT_SERVICE" || true
    rm -f "$tmp_env" "$tmp_quadlet"
    if wait_for_element; then
      echo "  Rollback complete — ${old_image} is healthy again." >&2
    else
      echo "  CRITICAL: rollback to ${old_image} did not become healthy. Check: journalctl -u ${ELEMENT_SERVICE}" >&2
    fi
  }
  trap rollback ERR

  echo "  Pulling target image ..."
  podman pull "$new_image"

  sed -i "s|^Image=.*|Image=${new_image}|" "$ELEMENT_QUADLET_FILE"
  sed -i \
    -e "s|^ELEMENT_TAG=.*|ELEMENT_TAG=$new_tag|" \
    -e "s|^ELEMENT_IMAGE=.*|ELEMENT_IMAGE=$new_image|" \
    "$ENV_FILE"

  echo "  Reloading Quadlet and restarting Element ..."
  systemctl daemon-reload
  systemctl restart "$ELEMENT_SERVICE"

  echo "  Waiting for Element ..."
  if ! wait_for_element; then
    trap - ERR
    rollback
    die "Element did not become healthy after update."
  fi

  trap - ERR
  cleanup
  if [[ -n "$old_id" && "$old_id" != "$(image_id_of "$new_image")" ]]; then
    podman rmi "$old_id" >/dev/null 2>&1 || true
  fi
  echo "  OK: Element updated to $new_tag"
}

# update-postgres <tag> [--yes] — move PostgreSQL to another minor of the SAME major
update_postgres() {
  local new_tag="" skip_confirm=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) skip_confirm=1; shift ;;
      *) new_tag="$1"; shift ;;
    esac
  done

  local old_tag repo old_image new_image old_id tmp_env tmp_quadlet old_major new_major
  [[ -n "$new_tag" ]] || die "Usage: matrix-maint.sh update-postgres <tag>"
  [[ "$new_tag" =~ ^[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] \
    || die "Invalid tag: $new_tag — PostgreSQL needs MAJOR.MINOR like 18.7-alpine ('latest' and major-only tags are not permitted)."

  old_tag="$(postgres_tag)"
  repo="$(postgres_repo)"
  [[ -n "$repo" ]] || die "Could not read POSTGRES_IMAGE_REPO from .env"
  old_image="$(postgres_image)"
  new_image="${repo}:${new_tag}"
  old_major="${old_tag%%.*}"
  new_major="${new_tag%%.*}"
  # Guard: the data directory format changes between majors; the new binaries
  # would refuse to start on the old cluster and rollback would be the only outcome.
  [[ "$old_major" == "$new_major" ]] \
    || die "Major upgrade ${old_major} → ${new_major} is not automated. Dump/restore or pg_upgrade manually, then set the tag."
  old_id="$(image_id_of "$old_image")"
  tmp_env="$(mktemp)"
  tmp_quadlet="$(mktemp)"

  echo "  Current PostgreSQL tag: $old_tag"
  echo "  Target  PostgreSQL tag: $new_tag"

  if [[ "$skip_confirm" -eq 0 ]]; then
    confirm_or_exit || { rm -f "$tmp_env" "$tmp_quadlet"; exit 0; }
  fi

  cp -a "$ENV_FILE"              "$tmp_env"
  cp -a "$POSTGRES_QUADLET_FILE" "$tmp_quadlet"

  cleanup() { rm -f "$tmp_env" "$tmp_quadlet"; }
  rollback() {
    echo "  !! PostgreSQL update failed — rolling back and restarting ..." >&2
    cp -a "$tmp_env"     "$ENV_FILE"
    cp -a "$tmp_quadlet" "$POSTGRES_QUADLET_FILE"
    [[ -n "$old_id" ]] && podman tag "$old_id" "$old_image" >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl restart "$POSTGRES_SERVICE" || true
    systemctl restart "$SYNAPSE_SERVICE" || true
    rm -f "$tmp_env" "$tmp_quadlet"
    if wait_for_postgres && wait_for_synapse; then
      echo "  Rollback complete — ${old_image} is healthy again." >&2
    else
      echo "  CRITICAL: rollback to ${old_image} did not become healthy. Restore the CT from the PVE snapshot / PBS." >&2
    fi
  }
  trap rollback ERR

  echo "  Pulling target image ..."
  podman pull "$new_image"

  sed -i "s|^Image=.*|Image=${new_image}|" "$POSTGRES_QUADLET_FILE"
  sed -i \
    -e "s|^POSTGRES_TAG=.*|POSTGRES_TAG=$new_tag|" \
    -e "s|^POSTGRES_IMAGE=.*|POSTGRES_IMAGE=$new_image|" \
    "$ENV_FILE"

  # Requires= stops Synapse together with PostgreSQL; start it again explicitly.
  echo "  Reloading Quadlet and restarting PostgreSQL + Synapse ..."
  systemctl daemon-reload
  systemctl restart "$POSTGRES_SERVICE"
  systemctl restart "$SYNAPSE_SERVICE"

  echo "  Waiting for PostgreSQL and Synapse ..."
  if ! wait_for_postgres || ! wait_for_synapse; then
    trap - ERR
    rollback
    die "Stack did not become healthy after PostgreSQL update."
  fi

  trap - ERR
  cleanup
  if [[ -n "$old_id" && "$old_id" != "$(image_id_of "$new_image")" ]]; then
    podman rmi "$old_id" >/dev/null 2>&1 || true
  fi
  echo "  OK: PostgreSQL updated to $new_tag"
}

# auto-update — re-pull all three current pinned tags; restart only what changed
auto_update_stack() {
  if [[ "$(env_flag AUTO_UPDATE)" != "1" ]]; then
    echo "  Auto-update disabled in ${ENV_FILE}; nothing to do."
    return 0
  fi

  local pg_image pg_old_id pg_new_id sy_image sy_old_id sy_new_id el_image el_old_id el_new_id
  pg_image="$(postgres_image)"
  sy_image="$(synapse_image)"
  el_image="$(element_image)"
  [[ -n "$pg_image" ]] || die "Could not read POSTGRES_IMAGE from .env"
  [[ -n "$sy_image" ]] || die "Could not read SYNAPSE_IMAGE from .env"
  [[ -n "$el_image" ]] || die "Could not read ELEMENT_IMAGE from .env"
  pg_old_id="$(running_image_id "$POSTGRES_CONTAINER")"
  sy_old_id="$(running_image_id "$SYNAPSE_CONTAINER")"
  el_old_id="$(running_image_id "$ELEMENT_CONTAINER")"

  echo "  Auto-update: re-pulling pinned ${pg_image} ..."
  podman pull "$pg_image"
  pg_new_id="$(image_id_of "$pg_image")"
  [[ -n "$pg_new_id" ]] || die "Could not inspect pulled image ${pg_image}"

  echo "  Auto-update: re-pulling pinned ${sy_image} ..."
  podman pull "$sy_image"
  sy_new_id="$(image_id_of "$sy_image")"
  [[ -n "$sy_new_id" ]] || die "Could not inspect pulled image ${sy_image}"

  echo "  Auto-update: re-pulling pinned ${el_image} ..."
  podman pull "$el_image"
  el_new_id="$(image_id_of "$el_image")"
  [[ -n "$el_new_id" ]] || die "Could not inspect pulled image ${el_image}"

  local pg_changed=0 sy_changed=0 el_changed=0
  [[ -z "$pg_old_id" || "$pg_new_id" != "$pg_old_id" ]] && pg_changed=1
  [[ -z "$sy_old_id" || "$sy_new_id" != "$sy_old_id" ]] && sy_changed=1
  [[ -z "$el_old_id" || "$el_new_id" != "$el_old_id" ]] && el_changed=1

  if [[ "$pg_changed" -eq 0 && "$sy_changed" -eq 0 && "$el_changed" -eq 0 ]]; then
    echo "  OK: all images are already current — no restart needed."
    return 0
  fi

  rollback() {
    echo "  !! Auto-update failed — restoring previous images and restarting ..." >&2
    [[ "$pg_changed" -eq 1 && -n "$pg_old_id" ]] && podman tag "$pg_old_id" "$pg_image" >/dev/null 2>&1 || true
    [[ "$sy_changed" -eq 1 && -n "$sy_old_id" ]] && podman tag "$sy_old_id" "$sy_image" >/dev/null 2>&1 || true
    [[ "$el_changed" -eq 1 && -n "$el_old_id" ]] && podman tag "$el_old_id" "$el_image" >/dev/null 2>&1 || true
    [[ "$pg_changed" -eq 1 ]] && { systemctl restart "$POSTGRES_SERVICE" || true; }
    [[ "$pg_changed" -eq 1 || "$sy_changed" -eq 1 ]] && { systemctl restart "$SYNAPSE_SERVICE" || true; }
    [[ "$el_changed" -eq 1 ]] && { systemctl restart "$ELEMENT_SERVICE" || true; }
    if wait_for_postgres && wait_for_synapse && wait_for_element; then
      echo "  Rollback complete — previous images are healthy again." >&2
    else
      echo "  CRITICAL: rollback did not become healthy (Synapse schema may already be migrated). Restore the CT from the PVE snapshot / PBS." >&2
    fi
  }
  trap rollback ERR

  if [[ "$pg_changed" -eq 1 ]]; then
    echo "  PostgreSQL image changed — restarting ${POSTGRES_SERVICE} ..."
    systemctl restart "$POSTGRES_SERVICE"
  fi
  # Synapse restarts when its own image changed, or after a PostgreSQL restart
  # (Requires= already stopped it, and it must reconnect to the new backend).
  if [[ "$pg_changed" -eq 1 || "$sy_changed" -eq 1 ]]; then
    echo "  Restarting ${SYNAPSE_SERVICE} ..."
    systemctl restart "$SYNAPSE_SERVICE"
  fi
  if [[ "$el_changed" -eq 1 ]]; then
    echo "  Element image changed — restarting ${ELEMENT_SERVICE} ..."
    systemctl restart "$ELEMENT_SERVICE"
  fi

  echo "  Waiting for PostgreSQL, Synapse and Element ..."
  if ! wait_for_postgres || ! wait_for_synapse || ! wait_for_element; then
    trap - ERR
    rollback
    die "Stack did not become healthy after auto-update."
  fi

  trap - ERR
  [[ "$pg_changed" -eq 1 && -n "$pg_old_id" ]] && podman rmi "$pg_old_id" >/dev/null 2>&1 || true
  [[ "$sy_changed" -eq 1 && -n "$sy_old_id" ]] && podman rmi "$sy_old_id" >/dev/null 2>&1 || true
  [[ "$el_changed" -eq 1 && -n "$el_old_id" ]] && podman rmi "$el_old_id" >/dev/null 2>&1 || true
  echo "  OK: Matrix stack refreshed (Synapse changed: ${sy_changed}, Element changed: ${el_changed}, PostgreSQL changed: ${pg_changed})"
}

need_root
cmd="${1:-}"
case "$cmd" in
  update)          shift; update_synapse "$@" ;;
  update-element)  shift; update_element "$@" ;;
  update-postgres) shift; update_postgres "$@" ;;
  auto-update)     auto_update_stack ;;
  version)
    echo "Configured Synapse image:    $(synapse_image)"
    echo "Running Synapse image ID:    $(running_image_id "$SYNAPSE_CONTAINER")"
    echo "Synapse server version:      $(curl -s --max-time 3 "http://127.0.0.1:$(synapse_port)/_synapse/admin/v1/server_version" 2>/dev/null | grep -o '"server_version":"[^"]*"' | cut -d'"' -f4 || echo n/a)"
    echo "Configured Element image:    $(element_image)"
    echo "Running Element image ID:    $(running_image_id "$ELEMENT_CONTAINER")"
    echo "Configured PostgreSQL image: $(postgres_image)"
    echo "Running PostgreSQL image ID: $(running_image_id "$POSTGRES_CONTAINER")"
    echo "PostgreSQL server version:   $(podman exec "$POSTGRES_CONTAINER" psql -U synapse -d synapse -tAc 'show server_version' 2>/dev/null || echo n/a)"
    echo "AUTO_UPDATE=$(env_flag AUTO_UPDATE)"
    ;;
  ""|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
MAINT
echo "  Maintenance script deployed: /usr/local/bin/matrix-maint.sh"

# ── Start via Quadlet ─────────────────────────────────────────────────────────
# daemon-reload triggers the Quadlet generator which produces matrix-synapse.service,
# matrix-element.service and matrix-postgres.service as transient systemd units.
# WantedBy=multi-user.target handles boot restarts. Transient units cannot be
# systemctl-enabled; daemon-reload is sufficient. Starting matrix-synapse.service
# pulls in PostgreSQL via Requires= and waits for its health check (Notify=healthy);
# Element is started alongside and is independent of both.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  systemctl daemon-reload
  systemctl start '${SYNAPSE_QUADLET_SERVICE}' '${ELEMENT_QUADLET_SERVICE}'
"

# ── Disarm destructive cleanup ────────────────────────────────────────────────
CLEANUP_ON_FAIL=0

# ── Verification ──────────────────────────────────────────────────────────────
sleep 3
VERIFY_FAIL=0

for svc in "$POSTGRES_QUADLET_SERVICE" "$SYNAPSE_QUADLET_SERVICE" "$ELEMENT_QUADLET_SERVICE"; do
  if pct exec "$CT_ID" -- systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo "  Quadlet service is active: ${svc}"
  else
    echo "  ERROR: ${svc} is not active" >&2
    echo "  Check: pct exec $CT_ID -- systemctl status ${svc}" >&2
    echo "  Check: pct exec $CT_ID -- journalctl -u ${svc} --no-pager -n 50" >&2
    VERIFY_FAIL=1
  fi
done

RUNNING=0
for i in $(seq 1 60); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc \
    'podman ps --filter name=^matrix-synapse$ --filter name=^matrix-element$ --filter name=^matrix-postgres$ --format "{{.Names}}" 2>/dev/null | wc -l' \
    2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge 3 ]] && break
  sleep 2
done
pct exec "$CT_ID" -- bash -lc 'podman ps' || true

if [[ "$RUNNING" -lt 3 ]]; then
  echo "  ERROR: Expected 3 containers running (matrix-synapse, matrix-element, matrix-postgres), found $RUNNING" >&2
  VERIFY_FAIL=1
else
  echo "  Container count OK ($RUNNING running)"
fi

if pct exec "$CT_ID" -- sh -lc 'podman exec matrix-postgres pg_isready -h 127.0.0.1 -U synapse -d synapse >/dev/null 2>&1' 2>/dev/null; then
  echo "  PostgreSQL accepts connections on 127.0.0.1:5432"
else
  echo "  ERROR: PostgreSQL did not answer pg_isready on 127.0.0.1:5432" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u matrix-postgres.service --no-pager -n 50" >&2
  VERIFY_FAIL=1
fi

# Network=host: PostgreSQL must be bound to loopback only, otherwise the DB is
# reachable by every host on the LAN with only its password in front of it.
EXPOSED_BACKENDS="$(pct exec "$CT_ID" -- sh -lc 'ss -Hltn 2>/dev/null | awk "\$4 ~ /:5432\$/ && \$4 !~ /^127\\.0\\.0\\.1:/ {print \$4}"' 2>/dev/null || true)"
if [[ -z "$EXPOSED_BACKENDS" ]]; then
  echo "  PostgreSQL listens on loopback only"
else
  echo "  ERROR: PostgreSQL bound beyond loopback: ${EXPOSED_BACKENDS}" >&2
  echo "  Check: pct exec $CT_ID -- ss -ltnp" >&2
  VERIFY_FAIL=1
fi

# PG18 layout check: the cluster must be inside the bind mount, not in an
# anonymous podman volume (that is exactly what the old /var/lib/postgresql/data
# mount did on 18-era images).
PG_MAJOR="${POSTGRES_TAG%%.*}"
if pct exec "$CT_ID" -- test -f "${APP_DIR}/postgresdata/${PG_MAJOR}/docker/PG_VERSION" 2>/dev/null; then
  echo "  PostgreSQL cluster lives in ${APP_DIR}/postgresdata/${PG_MAJOR}/docker (bind mount)"
else
  echo "  ERROR: ${APP_DIR}/postgresdata/${PG_MAJOR}/docker/PG_VERSION not found — the cluster is not inside the bind mount" >&2
  echo "  Check: pct exec $CT_ID -- podman exec matrix-postgres sh -c 'echo \$PGDATA'" >&2
  VERIFY_FAIL=1
fi

# Synapse refuses to start on a database whose collation is not "C" (initdb
# must have received POSTGRES_INITDB_ARGS). Query pg_database — the lc_collate
# server variable no longer exists since PostgreSQL 16.
DB_COLLATE="$(pct exec "$CT_ID" -- sh -lc "podman exec matrix-postgres psql -U synapse -d synapse -tAc \"select datcollate from pg_database where datname = current_database()\" 2>/dev/null" 2>/dev/null | tr -d '[:space:]' || true)"
if [[ "$DB_COLLATE" == "C" ]]; then
  echo "  Database collation is C (Synapse requirement)"
else
  echo "  ERROR: synapse database collation is '${DB_COLLATE:-n/a}', expected 'C' — POSTGRES_INITDB_ARGS was not applied at initdb" >&2
  echo "  Check: pct exec $CT_ID -- cat ${POSTGRES_ENV_FILE}" >&2
  VERIFY_FAIL=1
fi

SY_HEALTHY=0
for i in $(seq 1 90); do
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc "curl -s -o /dev/null -w '%{http_code}' --max-time 3 'http://127.0.0.1:${SYNAPSE_PORT}/health' 2>/dev/null" 2>/dev/null || echo 000)"
  case "$HTTP_CODE" in
    200)
      SY_HEALTHY=1
      break
      ;;
  esac
  sleep 2
done

if [[ "$SY_HEALTHY" -eq 1 ]]; then
  echo "  Synapse health check passed (HTTP $HTTP_CODE on port ${SYNAPSE_PORT})"
else
  echo "  ERROR: Synapse /health did not return 200 on port ${SYNAPSE_PORT}" >&2
  echo "  Check: pct exec $CT_ID -- systemctl status matrix-synapse.service" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u matrix-synapse.service --no-pager -n 80" >&2
  VERIFY_FAIL=1
fi

# The signing key response carries the server_name Synapse actually runs with —
# the one baked into every user ID. It must be what was configured.
KEY_SERVER_NAME="$(pct exec "$CT_ID" -- sh -lc "curl -s --max-time 3 'http://127.0.0.1:${SYNAPSE_PORT}/_matrix/key/v2/server' 2>/dev/null | grep -o '\"server_name\":\"[^\"]*\"' | cut -d'\"' -f4" 2>/dev/null || true)"
if [[ "$KEY_SERVER_NAME" == "$SYNAPSE_SERVER_NAME" ]]; then
  echo "  Synapse server_name confirmed: ${KEY_SERVER_NAME}"
else
  echo "  ERROR: Synapse reports server_name '${KEY_SERVER_NAME:-n/a}', expected '${SYNAPSE_SERVER_NAME}'" >&2
  VERIFY_FAIL=1
fi

# Synapse creates its schema on first start; an empty public schema means it came
# up without a working database block (or the deltas failed silently).
TABLE_COUNT="$(pct exec "$CT_ID" -- sh -lc "podman exec matrix-postgres psql -U synapse -d synapse -tAc \"select count(*) from pg_tables where schemaname='public'\" 2>/dev/null" 2>/dev/null | tr -d '[:space:]' || true)"
if [[ "$TABLE_COUNT" =~ ^[0-9]+$ ]] && (( TABLE_COUNT > 0 )); then
  echo "  Database schema created (${TABLE_COUNT} tables in schema public)"
else
  echo "  ERROR: No tables found in the synapse database — schema was not created" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u matrix-synapse.service --no-pager -n 80" >&2
  VERIFY_FAIL=1
fi

EL_HEALTHY=0
for i in $(seq 1 30); do
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc "curl -s -o /dev/null -w '%{http_code}' --max-time 3 'http://127.0.0.1:${ELEMENT_PORT}/' 2>/dev/null" 2>/dev/null || echo 000)"
  case "$HTTP_CODE" in
    200)
      EL_HEALTHY=1
      break
      ;;
  esac
  sleep 2
done

if [[ "$EL_HEALTHY" -eq 1 ]]; then
  echo "  Element health check passed (HTTP $HTTP_CODE on port ${ELEMENT_PORT})"
else
  echo "  ERROR: Element did not return 200 on port ${ELEMENT_PORT}" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u matrix-element.service --no-pager -n 50" >&2
  VERIFY_FAIL=1
fi

if (( VERIFY_FAIL == 1 )); then
  echo "" >&2
  echo "  FATAL: Core verification failed — CT $CT_ID is preserved but the install is incomplete." >&2
  echo "  Inspect the container and fix manually, or destroy and re-run." >&2
  exit 1
fi

# ── Auto-update timer (policy-driven) ─────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > /etc/systemd/system/matrix-update.service <<EOF2
[Unit]
Description=Matrix auto-update maintenance run
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/matrix-maint.sh auto-update
EOF2

  cat > /etc/systemd/system/matrix-update.timer <<EOF2
[Unit]
Description=Matrix auto-update timer

[Timer]
OnCalendar=*-*-* ${UPDATE_TIME}:00
Persistent=true

[Install]
WantedBy=timers.target
EOF2

  systemctl daemon-reload
"
if [[ "$AUTO_UPDATE" -eq 1 ]]; then
  pct exec "$CT_ID" -- bash -lc 'systemctl enable --now matrix-update.timer'
  echo "  Auto-update timer enabled"
else
  pct exec "$CT_ID" -- bash -lc 'systemctl disable --now matrix-update.timer >/dev/null 2>&1 || true'
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
printf '\\n  Matrix Synapse + Element (Podman/Quadlet)\\n'
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
running=\$(podman ps --filter name=^matrix-synapse$ --filter name=^matrix-element$ --filter name=^matrix-postgres$ --format '{{.Names}}' 2>/dev/null | wc -l)
sy_status=\$(systemctl is-active matrix-synapse.service 2>/dev/null); sy_status=\${sy_status:-unknown}
el_status=\$(systemctl is-active matrix-element.service 2>/dev/null); el_status=\${el_status:-unknown}
pg_status=\$(systemctl is-active matrix-postgres.service 2>/dev/null); pg_status=\${pg_status:-unknown}
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
sy_image=\$(awk -F= '/^SYNAPSE_IMAGE=/{print \$2}' /opt/matrix/.env 2>/dev/null | tail -n1)
el_image=\$(awk -F= '/^ELEMENT_IMAGE=/{print \$2}' /opt/matrix/.env 2>/dev/null | tail -n1)
pg_image=\$(awk -F= '/^POSTGRES_IMAGE=/{print \$2}' /opt/matrix/.env 2>/dev/null | tail -n1)
auto=\$(awk -F= '/^AUTO_UPDATE=/{print \$2}' /opt/matrix/.env 2>/dev/null | tail -n1)
server_name=\$(awk -F= '/^SYNAPSE_SERVER_NAME=/{print \$2}' /opt/matrix/.env 2>/dev/null | tail -n1)
sy_fqdn=\$(awk -F= '/^SYNAPSE_FQDN=/{print \$2}' /opt/matrix/.env 2>/dev/null | tail -n1)
el_fqdn=\$(awk -F= '/^ELEMENT_FQDN=/{print \$2}' /opt/matrix/.env 2>/dev/null | tail -n1)
sy_port=\$(awk -F= '/^SYNAPSE_PORT=/{print \$2}' /opt/matrix/.env 2>/dev/null | tail -n1); sy_port=\${sy_port:-8008}
el_port=\$(awk -F= '/^ELEMENT_PORT=/{print \$2}' /opt/matrix/.env 2>/dev/null | tail -n1); el_port=\${el_port:-8080}
printf '  Containers: matrix-synapse + matrix-element + matrix-postgres (%s running)\\n' \"\$running\"
printf '  Services:   synapse (%s) | element (%s) | postgres (%s)\\n' \"\$sy_status\" \"\$el_status\" \"\$pg_status\"
printf '  Server:     %s  (user IDs @user:%s)\\n' \"\${server_name:-n/a}\" \"\${server_name:-n/a}\"
printf '  Synapse:    %s\\n' \"\${sy_image:-n/a}\"
printf '  Element:    %s\\n' \"\${el_image:-n/a}\"
printf '  PostgreSQL: %s (127.0.0.1:5432)\\n' \"\${pg_image:-n/a}\"
printf '  Policy:     %s\\n' \"\$([ \"\$auto\" = '1' ] && echo 'auto-update daily (re-pull current pinned tags)' || echo 'manual updates only')\"
printf '  Data:       /opt/matrix/synapse (homeserver.yaml, media_store)  /opt/matrix/postgresdata\\n'
printf '  Secrets:    /opt/matrix/postgres.env  /opt/matrix/synapse/homeserver.yaml\\n'
printf '  Logs:       journalctl -u matrix-synapse.service -f\\n'
printf '  Maintain:   /usr/local/bin/matrix-maint.sh [update|update-element|update-postgres|auto-update|version]\\n'
printf '  Updates:    systemctl status matrix-update.timer\\n'
printf '  Synapse:    https://%s/  |  http://%s:%s/\\n' \"\${sy_fqdn:-n/a}\" \"\${ip:-n/a}\" \"\$sy_port\"
printf '  Element:    https://%s/  |  http://%s:%s/\\n' \"\${el_fqdn:-n/a}\" \"\${ip:-n/a}\" \"\$el_port\"
printf '\\n'
printf '  Admin:\\n'
printf '    Create user (answer y to the admin prompt):\\n'
printf '      podman exec -it matrix-synapse register_new_matrix_user -c /data/homeserver.yaml http://127.0.0.1:%s\\n' \"\$sy_port\"
printf '    Registration token (needs an admin access token; admin API is LAN-only):\\n'
printf '      curl -H \"Authorization: Bearer <ADMIN_TOKEN>\" -X POST http://%s:%s/_synapse/admin/v1/registration_tokens/new -d '\"'\"'{\"uses_allowed\": 1}'\"'\"'\\n' \"\${ip:-n/a}\" \"\$sy_port\"
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
LINK_STYLE="text-decoration: none; color: #00617f;"
MX_DESC="Public: <a href='https://${ELEMENT_FQDN}/' target='_blank' rel='noopener noreferrer' style='${LINK_STYLE}'>Element Web</a> · <a href='https://${SYNAPSE_FQDN}/' target='_blank' rel='noopener noreferrer' style='${LINK_STYLE}'>Synapse</a>
Local: <a href='http://${CT_IP}:${ELEMENT_PORT}/' target='_blank' rel='noopener noreferrer' style='${LINK_STYLE}'>Element Web</a> · <a href='http://${CT_IP}:${SYNAPSE_PORT}/' target='_blank' rel='noopener noreferrer' style='${LINK_STYLE}'>Synapse</a>
<details><summary>Details</summary>Matrix Synapse + Element Web (Podman/Quadlet) on Debian ${DEBIAN_VERSION} LXC
Server name: ${SYNAPSE_SERVER_NAME} | Synapse: ${SYNAPSE_TAG} | Element: ${ELEMENT_TAG} | PostgreSQL: ${POSTGRES_TAG}
Created by matrix-quadlet.sh</details>"
pct set "$CT_ID" --description "$MX_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "    CT: $CT_ID | IP: ${CT_IP} | Synapse: http://${CT_IP}:${SYNAPSE_PORT}/ | Element: http://${CT_IP}:${ELEMENT_PORT}/"
echo "    Public:      https://${SYNAPSE_FQDN}/ (Synapse)  https://${ELEMENT_FQDN}/ (Element)"
echo "    Server name: ${SYNAPSE_SERVER_NAME}  — user IDs are @user:${SYNAPSE_SERVER_NAME}; this can never be changed"
echo "    Images:      ${SYNAPSE_IMAGE}"
echo "                 ${ELEMENT_IMAGE}"
echo "                 ${POSTGRES_IMAGE} (127.0.0.1:5432)"
echo "    Quadlet:     ${SYNAPSE_QUADLET_FILE}"
echo "                 ${ELEMENT_QUADLET_FILE}"
echo "                 ${POSTGRES_QUADLET_FILE}"
echo "    Config:      ${SYNAPSE_DATA_DIR}/homeserver.yaml  (0600 991:991 — DB password, secrets, TURN)"
echo "                 ${ELEMENT_CONFIG_FILE}"
echo "    Secrets:     ${POSTGRES_ENV_FILE}  (POSTGRES_PASSWORD — must match homeserver.yaml; initdb args)"
echo "    Data:        ${SYNAPSE_DATA_DIR} (signing key, media_store)  ${APP_DIR}/postgresdata (cluster at ${PG_MAJOR}/docker)"
echo "    Policy:      $([ "$AUTO_UPDATE" -eq 1 ] && echo "auto-update daily at ${UPDATE_TIME} (re-pull ${SYNAPSE_TAG} / ${ELEMENT_TAG} / ${POSTGRES_TAG})" || echo "manual updates only (${SYNAPSE_TAG} / ${ELEMENT_TAG} / ${POSTGRES_TAG})")"
echo ""
echo "    pct exec $CT_ID -- systemctl status matrix-synapse.service"
echo "    pct exec $CT_ID -- journalctl -u matrix-synapse.service --no-pager -n 50"
echo "    pct exec $CT_ID -- /usr/local/bin/matrix-maint.sh update <tag>           # Synapse, e.g. v1.161.0 — no :latest"
echo "    pct exec $CT_ID -- /usr/local/bin/matrix-maint.sh update-element <tag>   # Element, e.g. v1.12.28"
echo "    pct exec $CT_ID -- /usr/local/bin/matrix-maint.sh update-postgres <tag>  # same major only, e.g. 18.7-alpine"
echo "    pct exec $CT_ID -- /usr/local/bin/matrix-maint.sh auto-update            # re-pull current tags now (if AUTO_UPDATE=1)"
echo "    pct exec $CT_ID -- /usr/local/bin/matrix-maint.sh version"
echo "    Backup/restore: use PBS or PVE snapshots (take one before every Synapse update — schema deltas are not always reversible)"
echo ""
echo "    First admin user (interactive, answer y to the admin prompt):"
echo "      pct exec $CT_ID -- podman exec -it matrix-synapse register_new_matrix_user -c /data/homeserver.yaml http://127.0.0.1:${SYNAPSE_PORT}"
echo "    Registration is token-gated. Create a token with an admin access token (Element -> Settings -> Help & About -> Access Token):"
echo "      curl -H 'Authorization: Bearer <ADMIN_TOKEN>' -X POST http://${CT_IP}:${SYNAPSE_PORT}/_synapse/admin/v1/registration_tokens/new -d '{\"uses_allowed\": 1}'"
echo ""
echo "    NPM proxy hosts (scheme http, Websockets Support on):"
echo "      ${SYNAPSE_FQDN} -> http://${CT_IP}:${SYNAPSE_PORT}"
echo "        Custom Nginx Configuration:"
echo "          set_real_ip_from 127.0.0.1;          # cloudflared runs natively next to NPM (Network=host)"
echo "          real_ip_header CF-Connecting-IP;      # Synapse takes the LAST X-Forwarded-For entry — NPM appends the real IP"
echo "          client_max_body_size ${MAX_UPLOAD_SIZE};"
echo "          proxy_read_timeout 600s;"
echo "          proxy_send_timeout 600s;"
echo "          location ^~ /_synapse/admin { return 403; }"
echo "      ${ELEMENT_FQDN} -> http://${CT_IP}:${ELEMENT_PORT}"
echo "    Behind Cloudflare Tunnel (published route -> localhost:80): leave the SSL tab EMPTY on both hosts — Force SSL"
echo "    would loop (tunnel delivers plain HTTP to :80). Publish both hostnames in the tunnel; disable Bot Fight Mode"
echo "    or add a WAF skip for /_matrix/* — federation and some clients get challenged otherwise. Uploads are capped"
echo "    at 100 MB by Cloudflare Free/Pro. If NPM terminates TLS itself instead: enable SSL + Force SSL and drop the"
echo "    two real_ip lines."
echo "    Well-known: Synapse serves /.well-known/matrix/server and /client itself — no custom locations needed."
echo "    Federation needs only port 443 (delegation via well-known). Test: https://federationtester.matrix.org/#${SYNAPSE_SERVER_NAME}"
echo "    Element talks to https://${SYNAPSE_FQDN} — DNS + proxy must exist first. For a LAN-only test, set base_url in"
echo "    ${ELEMENT_CONFIG_FILE} to http://${CT_IP}:${SYNAPSE_PORT} and restart matrix-element.service."
echo "    Ports ${SYNAPSE_PORT} and ${ELEMENT_PORT} listen on all CT interfaces (Network=host) — restrict with the PVE firewall if needed."
echo ""
echo "    TURN (VoIP relay): ${TURN_HOST} — openrelay free tier is 500 MB/month; replace TURN_HOST + TURN_SHARED_SECRET"
echo "    in homeserver.yaml with your own coturn for production voice/video, then restart matrix-synapse.service."
if [[ "$PODMAN_FUSE_OVERLAY" -eq 1 ]]; then
  echo "    Backups: fuse=1 + fuse-overlayfs can deadlock under snapshot-mode vzdump/PBS (freezer)."
  echo "             Use stop-mode backups for this CT, or test PODMAN_FUSE_OVERLAY=0."
fi
echo ""
