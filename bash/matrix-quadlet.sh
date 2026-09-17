#!/usr/bin/env bash
set -Eeo pipefail
umask 022
export LC_ALL=C

# Fresh-install creator; run on the Proxmox host. Edit the top Config block.
# Lab baseline: Tier 1 pinned Quadlet images, host networking, PBS/PVE recovery.
# Revision: 2026-09-17 — common contract 1.0.0; canonical hardening v1.2.0.
# One reusable verifier gates initial, final, manual and post-update checks.
# PostgreSQL verification fix: validate PGDATA owner UID and mode 0700; its group may be root.
# Standalone creator: no separate hardening file/download is required.
# Input fix: NPM subnet entries produce a host-address hint without a traceback.
# Resolver permissions fix: provisioning uses 022; credential writes retain 077.
# UFW check fix: use ufw6-* chain names for IPv6 setup and startup verification.
# No in-CT data archives or restore engine. See the final summary before exposure.
# Upstream behavior reviewed against:
# https://element-hq.github.io/synapse/latest/upgrade.html
# https://manpages.debian.org/trixie/podman/quadlet.5.en.html
# https://manpages.debian.org/trixie/ufw/ufw.8.en.html
# https://github.com/element-hq/element-call/blob/main/docs/self_hosting.md
# Provisioning uses 022; credential writes use 077 locally.

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID=""                             # empty = next free cluster ID
HN="matrix"
CPU=4
RAM=4096
DISK=32                              # database, media and Podman images; monitor free space
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"
DEBIAN_VERSION=13
MATRIX_DOMAIN="example.com"          # REQUIRED: replace; server identity is matrix.<domain>
SYNAPSE_PORT=8008
ELEMENT_PORT=8080
# BEGIN COMMON: TIMEZONE INPUTS
# COMMON TIMEZONE INPUTS
SERVER_TIMEZONE="${SERVER_TIMEZONE-Europe/Berlin}"
PRESERVE_EXISTING_TIMEZONE="${PRESERVE_EXISTING_TIMEZONE-0}"
APP_TZ=""
# END COMMON: TIMEZONE INPUTS
MAX_UPLOAD_SIZE="90M"                # headroom below a 100 MB upstream request cap; also configure NPM
TAGS="matrix;podman;quadlet;lxc"

# Source addresses seen by this CT. Use the NPM CT's address, not Cloudflare's.
# Selected NPM/client host addresses: bare IPs, IPv4 /32 or IPv6 /128. Whole subnets are rejected.
# Use the NPM host IP without its LAN subnet mask (e.g. /24 is not a host rule).
# Empty arrays prompt after confirmation, before pct create.
# Enter at BOTH prompts allows any source on these two ports; UFW stays enabled.
# UFW permits the chosen hosts, or any source when both arrays remain empty.
# Manage Matrix through pct enter/exec and loopback; public HTTPS is for clients.
# Example: BACKEND_ALLOWED_IPV4=("192.168.1.20/32")
BACKEND_ALLOWED_IPV4=()
BACKEND_ALLOWED_IPV6=()

# Human-readable versions are resolved to immutable image IDs. Quadlets run with
# Pull=never; a partial pull or moved upstream tag cannot change a restart.
SYNAPSE_IMAGE_REPO="ghcr.io/element-hq/synapse"
SYNAPSE_TAG="v1.160.0"
ELEMENT_IMAGE_REPO="docker.io/vectorim/element-web"
ELEMENT_TAG="v1.12.27"
POSTGRES_IMAGE_REPO="docker.io/library/postgres"
POSTGRES_TAG="18.6-alpine"            # only major 18; minor updates keep the same variant

# TURN relays legacy Matrix calls. Use the exact listeners configured on eturnal
# or coturn; these examples use 3478 TCP/UDP and 5349 TLS. TLS needs a valid cert.
# external: use your own URIs and secret (prompted if empty).
# disabled: no legacy TURN relay. openrelay: explicit public test service opt-in.
TURN_MODE="disabled"
TURN_URIS=(
  "turn:turn.${MATRIX_DOMAIN}:3478?transport=udp"
  "turn:turn.${MATRIX_DOMAIN}:3478?transport=tcp"
  "turns:turn.${MATRIX_DOMAIN}:5349?transport=tcp"
)
TURN_SHARED_SECRET=""                # blank = concealed interactive prompt; never printed
TURN_USER_LIFETIME_MS=86400000
TURN_ALLOW_GUESTS=0

# Modern Element Call additionally requires a separately operated LiveKit SFU
# and MatrixRTC authorization service. Set both URLs to integrate that backend.
# Empty URLs explicitly mean MatrixRTC is NOT configured; TURN alone is not enough.
# Example: https://matrix-rtc.your-domain.tld/livekit/jwt
MATRIX_RTC_AUTH_URL=""
MATRIX_RTC_HEALTH_URL=""              # public HTTPS health endpoint, e.g. above URL + /healthz
MAPTILER_KEY=""

# Automatic refresh is opt-in and re-pulls current pinned tags component by component.
# It relies on your external PBS/PVE recovery policy; it does not verify/create backups.
AUTO_UPDATE=0
UPDATE_TIME="03:00"
INITIAL_WAIT_SECONDS=180              # fresh install: fail early on a crash loop
UPDATE_WAIT_SECONDS=1800             # upgrades: allow long migrations; never auto-downgrade
PODMAN_FUSE_OVERLAY=1                 # lab default; use stop-mode PBS backups with FUSE
# Native overlay (=0) still needs validation under snapshot-mode backup with I/O.
EXTRA_PACKAGES=()
CLEANUP_ON_FAIL=0                     # opt-in 1: ordinary early failure only; signals preserve CT
SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/matrix-quadlet.sh"
SCRIPT_LOCAL="/root/matrix-quadlet.sh"

# Shared hardening: final port lists inventory/reject external listeners only;
# they do not create UFW rules or prove health. Empty = inventory-only.
HARDENING_PROFILE="${HARDENING_PROFILE-lxc}"              # Debian 13 service LXC; no VPS/VM profile
HARDENING_RP_FILTER="${HARDENING_RP_FILTER-1}"              # 1=strict; 2=loose for asymmetric paths
HARDENING_KEEP_SSH="${HARDENING_KEEP_SSH-0}"               # 0=remove SSH; manage with pct enter/exec
HARDENING_REMOVE_POSTFIX="${HARDENING_REMOVE_POSTFIX-1}"         # 1=remove Postfix; 0=keep intentional mail service
HARDENING_JOURNAL_DAYS="${HARDENING_JOURNAL_DAYS-14}"
HARDENING_JOURNAL_MAX_MB="${HARDENING_JOURNAL_MAX_MB-256}"
HARDENING_JOURNAL_RUNTIME_MB="${HARDENING_JOURNAL_RUNTIME_MB-64}"
HARDENING_UPDATE_MAX_AGE_HOURS="${HARDENING_UPDATE_MAX_AGE_HOURS-72}"
HARDENING_TCP_PORTS="${HARDENING_TCP_PORTS-auto}"           # Creator-only auto = finalized Synapse + Element ports
HARDENING_UDP_PORTS="${HARDENING_UDP_PORTS-68 546}"          # DHCPv4/v6 can listen even with ip6=manual
# If retaining SSH/mail, explicitly account for their external listeners in a
# custom TCP list and separately review UFW access; no SSH/mail rule is added.

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
#   /opt/matrix/postgres.env                           (separate admin/app bootstrap credentials — 0600)
#   /opt/matrix/element-config.json                    (Element Web config → /app/config.json, 0644)
#   /opt/matrix/.env                                   (runtime state — read by maint script)
#   /opt/matrix/synapse/                               (Synapse /data: homeserver.yaml, signing key,
#                                                       log config, media_store — owned by 991:991)
#   /opt/matrix/synapse/homeserver.yaml                (generated by the image, then patched; 0600)
#   /opt/matrix/postgresdata/                          (PostgreSQL cluster → /var/lib/postgresql)
#   /usr/local/bin/matrix-maint.sh                     (maintenance helper)
#   /etc/systemd/system/matrix-update.service
#   /etc/systemd/system/matrix-update.timer
#   /etc/update-motd.d/00-header, 10-sysinfo, 30-app, 99-footer
#   /etc/default/ufw, /etc/ufw/ufw.conf                 (in-CT firewall policy/boot enable)
#   /etc/ufw/user.rules, /etc/ufw/user6.rules            (UFW-managed selected HTTP rules)
#   /usr/local/sbin/matrix-ufw-check                    (read-only service-start guard)
#   /opt/matrix/firewall-policy.json                   (selected HTTP access policy; no secrets)
#   /usr/local/sbin/matrix-verify                       (read-only application verifier)
#   /etc/apt/apt.conf.d/99-lab-hardening
#   /etc/needrestart/conf.d/99-lab-hardening.conf
#   /etc/systemd/journald.conf.d/99-lab-hardening.conf
#   /etc/systemd/system/apt-daily{,-upgrade}.service.d/90-lab-readiness.conf
#   /etc/systemd/system/lab-hardening-check.{service,timer}
#   /usr/local/sbin/lab-{apt-wait-online,hardening-check}
#   /etc/update-motd.d/25-lab-hardening
#   /var/lib/lab-hardening/                            (policy, status, locks, refresh stamp)
#   /var/backups/lab-hardening/<run>/                  (managed configuration backups)
#   /etc/sysctl.d/99-hardening.conf
#   /etc/localtime; existing /etc/timezone             (common set mode only)
#   /usr/local/sbin/lab-timezone, lab-postfix-check
#   /etc/systemd/system/ssh.{service,socket}            (common removal masks)
#   /etc/systemd/system/postfix*.{service,socket,path}   (common removal masks)
#   /opt/matrix/postgres-init.sh                       (DB role initialization; no secrets)
#   /opt/matrix/install-policy.json                    (expected non-secret app policy)
#   /run/matrix-install-bootstrap.json                 (temporary initial-check allowance)
#   /etc/containers/{storage,containers}.conf
#   /etc/locale.gen, /etc/default/locale, /etc/motd, /root/.bashrc
#   /run/lock/{matrix-creator,matrix-maint}.lock         (host/guest respectively)

# BEGIN COMMON: CREATOR TRAPS
# COMMON CREATOR TRAPS
INSTALL_STAGE="configuration"
CREATED=0
trap 'rc=$? err_line=$LINENO;
  trap - ERR INT TERM HUP
  if (( BASH_SUBSHELL > 0 )); then exit "$rc"; fi
  printf "  ERROR: stage=%s rc=%s line=%s\n" "$INSTALL_STAGE" "$rc" "$err_line" >&2
  printf "  Command text and arguments are omitted. External data is never removed by cleanup.\n" >&2
  if [[ $rc != 129 && $rc != 130 && $rc != 143 && ${CLEANUP_ON_FAIL:-0} == 1 && ${CREATED:-0} == 1 ]]; then
    if pct stop "$CT_ID" >/dev/null 2>&1; then
      pct destroy "$CT_ID" >/dev/null 2>&1 || printf "  CT cleanup failed; inspect the preserved state.\n" >&2
    else
      printf "  CT stop failed; no destruction attempted.\n" >&2
    fi
  else
    printf "  CT state is preserved for inspection.\n" >&2
  fi
  exit "$rc"
' ERR
trap 'rc=130; err_line=$LINENO;
  trap - ERR INT TERM HUP
  if (( BASH_SUBSHELL > 0 )); then exit "$rc"; fi
  printf "  Interrupted: stage=%s rc=%s line=%s\n" "$INSTALL_STAGE" "$rc" "$err_line" >&2
  printf "  CT and external data are preserved for inspection.\n" >&2
  exit "$rc"
' INT
trap 'rc=143; err_line=$LINENO;
  trap - ERR INT TERM HUP
  if (( BASH_SUBSHELL > 0 )); then exit "$rc"; fi
  printf "  Interrupted: stage=%s rc=%s line=%s\n" "$INSTALL_STAGE" "$rc" "$err_line" >&2
  printf "  CT and external data are preserved for inspection.\n" >&2
  exit "$rc"
' TERM
trap 'rc=129; err_line=$LINENO;
  trap - ERR INT TERM HUP
  if (( BASH_SUBSHELL > 0 )); then exit "$rc"; fi
  printf "  Interrupted: stage=%s rc=%s line=%s\n" "$INSTALL_STAGE" "$rc" "$err_line" >&2
  printf "  CT and external data are preserved for inspection.\n" >&2
  exit "$rc"
' HUP
# END COMMON: CREATOR TRAPS

# BEGIN COMMON: TIMEZONE VALIDATION
# COMMON TIMEZONE VALIDATION
[[ $PRESERVE_EXISTING_TIMEZONE =~ ^[01]$ ]] || {
  echo 'ERROR: PRESERVE_EXISTING_TIMEZONE must be exactly 0 or 1.' >&2
  exit 1
}
TIMEZONE_ACTION=preserved
TIMEZONE_LABEL='preserve existing guest timezone'
if [[ $PRESERVE_EXISTING_TIMEZONE == 0 ]]; then
  [[ $SERVER_TIMEZONE =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || {
    echo 'ERROR: SERVER_TIMEZONE must be a nonempty IANA timezone name.' >&2
    exit 1
  }
  TIMEZONE_ACTION=set
  TIMEZONE_LABEL=$SERVER_TIMEZONE
fi
# END COMMON: TIMEZONE VALIDATION

# ── Preflight — root & commands ───────────────────────────────────────────────
INSTALL_STAGE="preflight"
[[ $EUID == 0 && -d /etc/pve ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pveversion sha256sum pvesh pveam pct pvesm qm curl python3 ip awk grep sed sort paste seq readlink cp chmod dpkg head tail tr mktemp mv flock rm sleep id cat bash install sync; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

pveversion >/dev/null

[[ "$HN" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "ERROR: Invalid HN." >&2; exit 1; }
# Serialize creators so another invocation cannot race ID/hostname selection.
exec 7>/run/lock/matrix-creator.lock
flock -n 7 || { echo "ERROR: Another Matrix creator is running." >&2; exit 1; }


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
[[ -t 8 ]] || { echo "ERROR: Prompt input is not a terminal." >&2; exit 1; }

if [[ -n "$CT_ID" ]]; then
  [[ "$CT_ID" =~ ^[1-9][0-9]{2,8}$ ]] && (( CT_ID >= 100 && CT_ID <= 999999999 )) \
    || { echo "  ERROR: CT_ID must be an integer >= 100." >&2; exit 1; }
  if pct status "$CT_ID" >/dev/null 2>&1 || qm status "$CT_ID" >/dev/null 2>&1; then
    echo "  ERROR: CT_ID $CT_ID is already in use on this node." >&2
    exit 1
  fi
else
  CT_ID="$(pvesh get /cluster/nextid)"
  [[ $CT_ID =~ ^[1-9][0-9]{2,8}$ ]] && (( CT_ID >= 100 )) || { echo "ERROR: Invalid allocated CT ID." >&2; exit 1; }
fi

# Creator scripts are not idempotent: a re-run would create a second CT with the
# same hostname. Refuse if one already exists on this node (e.g. a preserved
# failed install). Preserve it and select a fresh hostname/ID.
EXISTING_CT="$(pct list 2>/dev/null | awk -v h="$HN" 'NR>1 && $NF==h {print $1}' | head -n1)"
if [[ -n "$EXISTING_CT" ]]; then
  echo "  ERROR: A CT with hostname '${HN}' already exists on this node (CT ${EXISTING_CT})." >&2
  echo "  Preserve that CT for diagnosis. Choose a new, unused HN and CT_ID for a fresh install." >&2
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
  Backend ports:     ${SYNAPSE_PORT}, ${ELEMENT_PORT} — selected hosts, or Enter twice for any source
  NPM IPv4:          ${BACKEND_ALLOWED_IPV4[*]:-(prompt if neither family configured)}
  NPM IPv6:          ${BACKEND_ALLOWED_IPV6[*]:-(none)}
  Max upload:        $MAX_UPLOAD_SIZE
  TURN mode:         $TURN_MODE
  TURN URIs:         $([[ $TURN_MODE == disabled ]] && echo disabled || echo "${TURN_URIS[*]}")
  MatrixRTC:         ${MATRIX_RTC_AUTH_URL:-NOT configured — external LiveKit + authorization backend required}
  TURN guests:       $([ "$TURN_ALLOW_GUESTS" -eq 1 ] && echo "allowed" || echo "denied")
  MapTiler key:      $([ -n "$MAPTILER_KEY" ] && echo "set" || echo "unset (map feature disabled)")
  Timezone plan:     $TIMEZONE_LABEL (validated inside the guest)
  Podman storage:    $([ "$PODMAN_FUSE_OVERLAY" -eq 1 ] && echo "fuse-overlayfs (fuse=1)" || echo "native overlay (no FUSE)")
  Tags:              $TAGS
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled — daily at ${UPDATE_TIME} (re-pull ${SYNAPSE_TAG} / ${ELEMENT_TAG} / ${POSTGRES_TAG})" || echo "disabled (${SYNAPSE_TAG} / ${ELEMENT_TAG} / ${POSTGRES_TAG}, manual)")
  Cleanup on fail:   $CLEANUP_ON_FAIL (opt-in only before persistent app startup)
  Interruptions:     INT/TERM/HUP always preserve CT and external data
  Update recovery:   PBS/PVE checkpoint managed on the host; no in-CT archives
  Initial health:    ${INITIAL_WAIT_SECONDS}s; crash loops fail earlier
  Migration wait:    ${UPDATE_WAIT_SECONDS}s; timeout never downgrades a migrated database
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

response=""
read -r -p "  Continue with these settings? [y/N]: " response <&8
case "$response" in
  [yY][eE][sS]|[yY]) ;;
  *)
    echo ""
    echo "  Keeping an editable script copy..."
    if [[ -f "$SCRIPT_SELF" ]] && head -n 1 "$SCRIPT_SELF" | grep -q '^#!/usr/bin/env bash$'; then
      # The running local file is already the correct editable copy. In particular,
      # never cp a file onto itself and then fetch a replacement over user edits.
      echo "  Edit: nano $SCRIPT_SELF"
      echo "  Run:  bash $SCRIPT_SELF"
    else
      [[ ! -e $SCRIPT_LOCAL ]] || SCRIPT_LOCAL="/root/matrix-quadlet-downloaded.$$.sh"
      DOWNLOAD_TEMP=$(mktemp /root/matrix-download.XXXXXX)
      if curl -fLsS --retry 3 --connect-timeout 10 --max-time 120 "$SCRIPT_URL" -o "$DOWNLOAD_TEMP" \
        && head -n 1 "$DOWNLOAD_TEMP" | grep -q '^#!/usr/bin/env bash$' \
        && bash -n "$DOWNLOAD_TEMP"; then
        chmod 0700 "$DOWNLOAD_TEMP"
        mv -T "$DOWNLOAD_TEMP" "$SCRIPT_LOCAL"
        echo "  Downloaded a separate upstream copy; it may differ from the piped script."
        echo "  Edit: nano $SCRIPT_LOCAL"
      else
        rm -f -- "$DOWNLOAD_TEMP"
        echo "  ERROR: Could not save a validated upstream copy. Existing files were preserved." >&2
        exit 1
      fi
    fi
    exit 0
    ;;
esac

echo ""

# ── Config validation ─────────────────────────────────────────────────────────
[[ "$HN" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "ERROR: HN must be a lowercase hostname." >&2; exit 1; }
for number in CPU RAM DISK SYNAPSE_PORT ELEMENT_PORT UPDATE_WAIT_SECONDS INITIAL_WAIT_SECONDS TURN_USER_LIFETIME_MS; do
  [[ ${!number} =~ ^[1-9][0-9]{0,9}$ ]] || { echo "ERROR: $number must be a positive decimal integer." >&2; exit 1; }
done
(( CPU >= 1 && RAM >= 2048 && DISK >= 16 )) || { echo "ERROR: CPU >= 1, RAM >= 2048 MB, DISK >= 16 GB required." >&2; exit 1; }
[[ $DEBIAN_VERSION == 13 ]] || { echo "ERROR: This installer targets Debian 13 only." >&2; exit 1; }
(( UPDATE_WAIT_SECONDS >= 30 && UPDATE_WAIT_SECONDS <= 86400 )) || { echo "ERROR: UPDATE_WAIT_SECONDS must be 30..86400." >&2; exit 1; }
for port in SYNAPSE_PORT ELEMENT_PORT; do
  (( ${!port} >= 1024 && ${!port} <= 65535 && ${!port} != 5432 )) || { echo "ERROR: Invalid/reserved $port." >&2; exit 1; }
done
(( SYNAPSE_PORT != ELEMENT_PORT )) || { echo "ERROR: Service ports must differ." >&2; exit 1; }
for flag in AUTO_UPDATE PODMAN_FUSE_OVERLAY CLEANUP_ON_FAIL TURN_ALLOW_GUESTS; do
  [[ ${!flag} =~ ^[01]$ ]] || { echo "ERROR: $flag must be 0 or 1." >&2; exit 1; }
done
for repo in SYNAPSE_IMAGE_REPO ELEMENT_IMAGE_REPO POSTGRES_IMAGE_REPO; do
  [[ ${!repo} =~ ^[a-z0-9][a-z0-9._/-]*[a-z0-9]$ ]] || { echo "ERROR: Invalid $repo." >&2; exit 1; }
done
[[ $SYNAPSE_TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: Synapse requires pinned vX.Y.Z." >&2; exit 1; }
[[ $ELEMENT_TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: Element requires pinned vX.Y.Z." >&2; exit 1; }
[[ $POSTGRES_TAG =~ ^18\.[0-9]+(-[a-z0-9.]+)?$ ]] || { echo "ERROR: Only PostgreSQL 18.MINOR[-variant] is supported by this data layout." >&2; exit 1; }
[[ $MAX_UPLOAD_SIZE =~ ^[1-9][0-9]*[KMG]$ ]] || { echo "ERROR: Invalid upload size." >&2; exit 1; }
[[ $UPDATE_TIME =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "ERROR: UPDATE_TIME must be HH:MM." >&2; exit 1; }
[[ $TAGS =~ ^[a-z0-9._-]+(;[a-z0-9._-]+)*$ ]] || { echo "ERROR: Invalid tags." >&2; exit 1; }
[[ -z $MAPTILER_KEY || $MAPTILER_KEY =~ ^[A-Za-z0-9_-]+$ ]] || { echo "ERROR: Invalid MapTiler key." >&2; exit 1; }
for pkg in "${EXTRA_PACKAGES[@]}"; do
  [[ $pkg =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || { echo "ERROR: Invalid extra package name." >&2; exit 1; }
done
for name in BRIDGE TEMPLATE_STORAGE CONTAINER_STORAGE; do
  [[ ${!name} =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { echo "ERROR: Invalid $name." >&2; exit 1; }
done
(( INITIAL_WAIT_SECONDS >= 30 && INITIAL_WAIT_SECONDS <= 86400 )) || { echo "ERROR: INITIAL_WAIT_SECONDS must be 30..86400." >&2; exit 1; }
case $TURN_MODE in
  external) (( ${#TURN_URIS[@]} > 0 )) || { echo "ERROR: External TURN needs TURN_URIS." >&2; exit 1; } ;;
  disabled) TURN_URIS=(); TURN_SHARED_SECRET="" ;;
  openrelay)
    TURN_URIS=("turn:staticauth.openrelay.metered.ca:80?transport=udp" "turn:staticauth.openrelay.metered.ca:443?transport=tcp" "turns:staticauth.openrelay.metered.ca:443?transport=tcp")
    TURN_SHARED_SECRET=openrelayprojectsecret
    # Public test relay; check current provider terms and availability before use.
    ;;
  *) echo "ERROR: TURN_MODE must be external, disabled or openrelay." >&2; exit 1 ;;
esac

# ── Backend source addresses ─────────────────────────────────────────────────
if (( ${#BACKEND_ALLOWED_IPV4[@]} + ${#BACKEND_ALLOWED_IPV6[@]} == 0 )); then
  echo "  UFW: Enter at both prompts allows any source on TCP $SYNAPSE_PORT and $ELEMENT_PORT."
  read -r -p "  Allowed NPM/client IPv4 hosts (bare IP or /32; Enter for none): " -a BACKEND_ALLOWED_IPV4 <&8
  read -r -p "  Allowed NPM/client IPv6 hosts (bare IP or /128; Enter for none): " -a BACKEND_ALLOWED_IPV6 <&8
fi
if ! python3 - "$MATRIX_DOMAIN" "$SYNAPSE_FQDN" "$MATRIX_RTC_AUTH_URL" "$MATRIX_RTC_HEALTH_URL" \
  "${#BACKEND_ALLOWED_IPV4[@]}" "${#BACKEND_ALLOWED_IPV6[@]}" \
  "${BACKEND_ALLOWED_IPV4[@]}" "${BACKEND_ALLOWED_IPV6[@]}" "${TURN_URIS[@]}" <<'PREFLIGHT'
import ipaddress, re, sys, urllib.parse
domain, server, rtc, health = sys.argv[1:5]
def valid_domain(value):
    return (len(value) <= 253 and value == value.lower() and len(value.split(".")) > 1
            and all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", x) for x in value.split(".")))
if not valid_domain(domain) or not valid_domain(server):
    raise SystemExit("ERROR: Use a valid lowercase domain; labels <= 63 characters.")
if any(domain == x or domain.endswith("." + x) for x in ("example.com", "example.net", "example.org", "invalid", "test", "localhost")):
    raise SystemExit("ERROR: Replace MATRIX_DOMAIN with your real domain before creating an immutable identity.")
v4, v6 = map(int, sys.argv[5:7]); values = sys.argv[7:]
if v4 == 0 and v6: raise SystemExit("ERROR: Restricted mode needs an IPv4 source: Synapse listens on IPv4. Leave BOTH arrays empty for any-source mode.")
for i, value in enumerate(values[:v4+v6]):
    field = "BACKEND_ALLOWED_IPV4" if i < v4 else "BACKEND_ALLOWED_IPV6"
    try:
        host = ipaddress.ip_interface(value)
    except ValueError:
        raise SystemExit(f"ERROR: {field}: invalid NPM address {value!r}. Use a bare IP, IPv4 /32 or IPv6 /128.")
    if host.version != (4 if i < v4 else 6):
        raise SystemExit(f"ERROR: {field}: address {value!r} belongs in the other IP-family array.")
    if host.network.prefixlen != host.max_prefixlen:
        raise SystemExit(f"ERROR: {field}: {value!r} specifies a subnet. To allow only this NPM host, use {host.ip} or {host.ip}/{host.max_prefixlen}.")
    if host.ip.is_multicast or host.ip.is_unspecified or host.ip.is_loopback:
        raise SystemExit(f"ERROR: {field}: use NPM's reachable host IP, not a multicast/unspecified/loopback address: {value}")
for uri in values[v4+v6:]:
    m = re.fullmatch(r"(turn|turns):(\[[0-9a-fA-F:]+\]|[a-zA-Z0-9.-]+):([1-9][0-9]{0,4})\?transport=(udp|tcp)", uri)
    if not m or int(m[3]) > 65535: raise SystemExit("ERROR: TURN URI needs explicit host, port and transport: " + uri)
    if m[2].startswith("["): ipaddress.IPv6Address(m[2][1:-1])
    elif not valid_domain(m[2].lower()):
        ipaddress.IPv4Address(m[2])
    if m[1] == "turns" and m[4] != "tcp": raise SystemExit("ERROR: Use turns with TCP for WebRTC clients.")
if bool(rtc) != bool(health): raise SystemExit("ERROR: Set both MATRIX_RTC_AUTH_URL and MATRIX_RTC_HEALTH_URL, or neither.")
for value in (rtc, health):
    if not value: continue
    parsed = urllib.parse.urlsplit(value)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
            or parsed.query or parsed.fragment or re.search(r"[\s\x00-\x1f\x7f]", value)
            or not re.fullmatch(r"https://[A-Za-z0-9.:-]+(?:/[A-Za-z0-9._~/-]*)?", value)):
        raise SystemExit("ERROR: MatrixRTC URLs must be plain public HTTPS URLs without credentials or query/fragment.")
    if not valid_domain(parsed.hostname): raise SystemExit("ERROR: MatrixRTC requires a DNS hostname and valid TLS.")
PREFLIGHT
then
  # Expected configuration errors occur before CT creation; show the validator's
  # message and stop without dumping the entire heredoc through the ERR trap.
  exit 1
fi


# Final listener lists: auto is a creator convenience, never passed to the block.
[[ $HARDENING_KEEP_SSH != 1 || $HARDENING_TCP_PORTS != auto ]] || {
  echo 'ERROR: Keeping SSH requires an explicit complete TCP list or empty inventory-only mode.' >&2
  exit 1
}
[[ $HARDENING_REMOVE_POSTFIX != 0 || $HARDENING_TCP_PORTS != auto ]] || {
  echo 'ERROR: Keeping Postfix requires an explicit complete TCP list or empty inventory-only mode.' >&2
  exit 1
}
FINALIZED_APP_TCP_PORTS="$SYNAPSE_PORT $ELEMENT_PORT"
# BEGIN COMMON: TCP RESOLUTION
# COMMON TCP RESOLUTION
[[ $HARDENING_TCP_PORTS != auto ]] || HARDENING_TCP_PORTS=$FINALIZED_APP_TCP_PORTS
# END COMMON: TCP RESOLUTION

[[ $HARDENING_PROFILE == lxc ]] || { echo "ERROR: This creator requires HARDENING_PROFILE=lxc." >&2; exit 1; }
[[ $HARDENING_RP_FILTER =~ ^[12]$ ]] || { echo "ERROR: HARDENING_RP_FILTER must be 1 or 2." >&2; exit 1; }
for flag in HARDENING_KEEP_SSH HARDENING_REMOVE_POSTFIX; do
  [[ ${!flag} =~ ^[01]$ ]] || { echo "ERROR: $flag must be 0 or 1." >&2; exit 1; }
done
for number in HARDENING_JOURNAL_DAYS HARDENING_JOURNAL_MAX_MB HARDENING_JOURNAL_RUNTIME_MB HARDENING_UPDATE_MAX_AGE_HOURS; do
  [[ ${!number} =~ ^[1-9][0-9]{0,3}$ ]] || { echo "ERROR: $number must be 1..9999." >&2; exit 1; }
done
for list in "$HARDENING_TCP_PORTS" "$HARDENING_UDP_PORTS"; do
  [[ $list != *$'\n'* && $list != *$'\r'* && $list != *$'\t'* && $list != *[!0-9\ ]* ]] || {
    echo 'ERROR: Hardening port lists must be one line of space-separated decimal ports.' >&2
    exit 1
  }
done
for port in $HARDENING_TCP_PORTS $HARDENING_UDP_PORTS; do
  [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )) || { echo "ERROR: Hardening port lists require integers 1..65535." >&2; exit 1; }
done
FIREWALL_ACCESS="selected NPM/client hosts only"
if (( ${#BACKEND_ALLOWED_IPV4[@]} + ${#BACKEND_ALLOWED_IPV6[@]} == 0 )); then
  FIREWALL_ACCESS="any source on the two HTTP ports"
fi
echo "  Selected UFW access: $FIREWALL_ACCESS"

# ── Preflight — environment ───────────────────────────────────────────────────
pvesm status | awk -v s="$TEMPLATE_STORAGE" '$1==s && $3=="active"{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Template storage not found: $TEMPLATE_STORAGE" >&2; exit 1; }
pvesh get /storage/"$TEMPLATE_STORAGE" --output-format json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'vztmpl' in d.get('content','')" 2>/dev/null \
  || { echo "  ERROR: Template storage '$TEMPLATE_STORAGE' does not support vztmpl content." >&2; exit 1; }

pvesm status | awk -v s="$CONTAINER_STORAGE" '$1==s && $3=="active"{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Container storage not found: $CONTAINER_STORAGE" >&2; exit 1; }
pvesh get /storage/"$CONTAINER_STORAGE" --output-format json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'rootdir' in d.get('content','')" 2>/dev/null \
  || { echo "  ERROR: Container storage '$CONTAINER_STORAGE' does not support rootdir content." >&2; exit 1; }

ip link show "$BRIDGE" >/dev/null 2>&1 \
  || { echo "  ERROR: Bridge not found: $BRIDGE" >&2; exit 1; }

# Verify the external MatrixRTC authorization health endpoint before creating a CT.
if [[ -n $MATRIX_RTC_AUTH_URL ]]; then
  curl -fLsS --connect-timeout 10 --max-time 30 --proto '=https' --proto-redir '=https' \
    "$MATRIX_RTC_HEALTH_URL" -o /dev/null \
    || { echo "ERROR: External MatrixRTC authorization health endpoint is unavailable." >&2; exit 1; }
fi
if [[ $TURN_MODE == external && -z $TURN_SHARED_SECRET ]]; then
  read -r -s -p "  eturnal/coturn shared secret (must match the TURN server): " TURN_SHARED_SECRET <&8
  echo
fi
if [[ $TURN_MODE != disabled ]]; then
  printf '%s' "$TURN_SHARED_SECRET" | python3 -c 'import sys; s=sys.stdin.read(); sys.exit(0 if 16 <= len(s) <= 512 and all(ord(c) >= 32 and ord(c) != 127 for c in s) else "ERROR: TURN secret must have 16..512 characters with no control characters.")'
fi

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

# ── Generate independent bootstrap and application secrets ────────────────────
DB_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
PG_ADMIN_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
[[ ${#DB_PASSWORD} == 64 && ${#PG_ADMIN_PASSWORD} == 64 ]] || { echo "ERROR: Secret generation failed." >&2; exit 1; }

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

INSTALL_STAGE="create LXC"
# ── Create LXC ────────────────────────────────────────────────────────────────
# Root password is set after start via chpasswd on stdin, keeping it out of
# the host process list (pct create -password exposes it in ps).
# nesting=1 is required for Debian 13 template boot; keyctl=1 supports Podman.
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
  -net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,ip6=manual,firewall=0"
)

pct create "$CT_ID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" "${PCT_OPTIONS[@]}"
CREATED=1
pct config "$CT_ID" | grep -qx 'unprivileged: 1'

# ── Start & wait for IPv4 ─────────────────────────────────────────────────────
pct start "$CT_ID"
CT_IP=""
for i in $(seq 1 60); do
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

INSTALL_STAGE="OS bootstrap"
# ── OS update ─────────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -s -- "$HOST_ARCH" <<'OS_BOOTSTRAP'
  set -euo pipefail
  . /etc/os-release
  [[ $EUID == 0 && $ID == debian && $VERSION_ID == 13 && -d /run/systemd/system ]]
  [[ $(systemd-detect-virt --container) == lxc ]]
  [[ $(dpkg --print-architecture) == "$1" ]]
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  export LANG=C.UTF-8
  export LC_ALL=C.UTF-8
  apt-get -o DPkg::Lock::Timeout=120 -o APT::Update::Error-Mode=any update -qq
  apt-get -o Dpkg::Options::="--force-confold" -y dist-upgrade
  apt-get clean
OS_BOOTSTRAP

# ── Base packages, locale, timezone ───────────────────────────────────────────
# python3 is used once below to patch the generated homeserver.yaml (the standard
# template does not guarantee it; unattended-upgrades would pull it in later anyway).
PODMAN_FUSE_PKG=""
[[ "$PODMAN_FUSE_OVERLAY" -eq 1 ]] && PODMAN_FUSE_PKG="fuse-overlayfs"

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  apt-get -o DPkg::Lock::Timeout=120 -o APT::Update::Error-Mode=any update -qq
  apt-get install -y tzdata locales curl ca-certificates iproute2 podman tar gzip python3 python3-yaml util-linux ufw iptables ${PODMAN_FUSE_PKG}
  sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
"

# ── Early guest timezone helper; plan only ────────────────────────────────────
INSTALL_STAGE="guest timezone validation"
pct exec "$CT_ID" -- bash -s <<'EARLY_TIMEZONE_GUEST'
set -euo pipefail
umask 022
target=/usr/local/sbin/lab-timezone
[[ ! -L $target && ( ! -e $target || -f $target ) ]] || {
  echo 'ERROR: Refusing a symlink/nonregular timezone helper destination.' >&2
  exit 1
}
install -d -m 0755 /usr/local/sbin
temporary=$(mktemp /usr/local/sbin/.lab-timezone.XXXXXX)
trap 'rm -f -- "$temporary"' EXIT
cat > "$temporary" <<'EARLY_TIMEZONE_HELPER'
#!/usr/bin/python3
"""LXC timezone policy, adapted from debian-hardening.sh v1.0.3.

Only apply writes timezone files; plan/check are read-only. No timedated,
clock, RTC, NTP, SSH, or access-recovery operations are performed.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from zoneinfo import ZoneInfo

ZONES = Path('/usr/share/zoneinfo')
LOCALTIME = Path('/etc/localtime')
TIMEZONE = Path('/etc/timezone')


def guest_guard():
    if os.geteuid() != 0 or shutil.which('pveversion') or Path('/etc/pve').exists():
        raise ValueError('Timezone operations require root inside the selected Debian 13 LXC.')
    release = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines()
                   if '=' in line and not line.startswith('#'))
    if release.get('ID', '').strip('"') != 'debian' or release.get('VERSION_ID', '').strip('"') != '13':
        raise ValueError('Timezone policy requires Debian 13.')
    result = subprocess.run(['systemd-detect-virt', '--container'], text=True,
                            capture_output=True, timeout=10)
    if result.returncode or result.stdout.strip() != 'lxc':
        raise ValueError('Timezone policy refuses environments other than LXC.')


def zone_path(name):
    # Same name grammar as the native source; validate against guest tzdata.
    if not re.fullmatch(r'[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+)*', name):
        raise ValueError('Invalid SERVER_TIMEZONE; use an installed IANA timezone name.')
    if name.split('/')[0] in ('posix', 'right', 'localtime', 'posixrules'):
        raise ValueError('SERVER_TIMEZONE must identify an IANA zone, not a special tzdata tree.')
    path = ZONES / name
    try:
        path.resolve(strict=True).relative_to(ZONES.resolve(strict=True))
        with path.open('rb') as stream:
            ZoneInfo.from_file(stream, key=name)
    except (OSError, ValueError) as exc:
        raise ValueError('Timezone is unavailable or invalid in this guest: ' + name) from exc
    return path


def effective_timezone():
    if not LOCALTIME.exists() and not LOCALTIME.is_symlink():
        zone_path('UTC')
        return 'UTC'  # localtime(5): absent /etc/localtime means UTC.
    if LOCALTIME.is_symlink():
        # Keep the selected alias, rather than resolving US/Eastern to another name.
        link = Path(os.path.normpath(LOCALTIME.parent / os.readlink(LOCALTIME)))
        try:
            name = str(link.relative_to(ZONES))
        except ValueError as exc:
            raise ValueError('/etc/localtime does not link into the guest zoneinfo tree.') from exc
        zone_path(name)
        return name
    if LOCALTIME.is_file() and TIMEZONE.is_file() and not TIMEZONE.is_symlink():
        name = TIMEZONE.read_text().strip()
        if LOCALTIME.read_bytes() == zone_path(name).read_bytes():
            return name
    raise ValueError('Cannot identify the guest timezone from /etc/localtime and /etc/timezone.')


def fingerprint(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return {'kind': 'absent'}
    if stat.S_ISLNK(info.st_mode):
        return {'kind': 'symlink', 'target': os.readlink(path)}
    if stat.S_ISREG(info.st_mode):
        return {'kind': 'file', 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    raise ValueError('Unsupported timezone file type: ' + str(path))


def fingerprints():
    return {str(path): fingerprint(path) for path in (LOCALTIME, TIMEZONE)}


def plan(preserve, requested):
    if preserve not in ('0', '1'):
        raise ValueError('PRESERVE_EXISTING_TIMEZONE must be exactly 0 or 1.')
    if preserve == '0':
        zone_path(requested)
        if TIMEZONE.is_symlink() or (TIMEZONE.exists() and not TIMEZONE.is_file()):
            raise ValueError('Refusing to replace a non-regular /etc/timezone.')
    before = effective_timezone()
    return {'preserve': preserve == '1', 'requested': None if preserve == '1' else requested,
            'before': before, 'effective': before if preserve == '1' else requested,
            'files_before': fingerprints()}


def verify(setting):
    actual = effective_timezone()
    if actual != setting['effective']:
        raise ValueError('Guest timezone drift: expected ' + setting['effective'] + ', found ' + actual)
    expected_files = setting.get('files', setting['files_before'])
    if fingerprints() != expected_files:
        raise ValueError('Guest timezone files changed; review /etc/localtime and /etc/timezone.')
    return actual


def apply(setting, backup):
    if fingerprints() != setting['files_before'] or effective_timezone() != setting['before']:
        raise ValueError('Guest timezone changed after validation; refusing to overwrite it.')
    if not setting['preserve']:
        target = zone_path(setting['requested'])
        saved = Path(backup) / 'timezone'
        saved.mkdir(mode=0o700, parents=True, exist_ok=False)
        (saved / 'before.json').write_text(json.dumps(setting, indent=2) + '\n')
        for path in (LOCALTIME, TIMEZONE):
            if path.exists() or path.is_symlink():
                shutil.copy2(path, saved / path.name, follow_symlinks=False)
        # Atomic per-file replacement; no automatic undo of a later failure.
        if setting['before'] != setting['requested']:
            with tempfile.TemporaryDirectory(prefix='.lab-timezone-', dir=LOCALTIME.parent) as tmp:
                replacement = Path(tmp) / 'localtime'
                replacement.symlink_to(target)
                os.replace(replacement, LOCALTIME)
        # Debian uses /etc/localtime. Keep an existing legacy file consistent;
        # do not introduce /etc/timezone when the template does not maintain it.
        desired = setting['requested'] + '\n'
        if TIMEZONE.exists() and TIMEZONE.read_text() != desired:
            with tempfile.TemporaryDirectory(prefix='.lab-timezone-', dir=TIMEZONE.parent) as tmp:
                replacement = Path(tmp) / 'timezone'
                replacement.write_text(desired)
                replacement.chmod(0o644)
                os.replace(replacement, TIMEZONE)
    final = {**setting, 'files': fingerprints()}
    if setting['preserve'] and final['files'] != setting['files_before']:
        raise ValueError('Preserve mode detected a timezone-file change.')
    verify(final)
    return final


def main():
    guest_guard()
    if len(sys.argv) == 4 and sys.argv[1] == 'plan':
        print(json.dumps(plan(sys.argv[2], sys.argv[3])))
    elif len(sys.argv) == 4 and sys.argv[1] == 'apply':
        setting = json.loads(Path(sys.argv[2]).read_text())
        print(json.dumps(apply(setting, sys.argv[3])))
    elif len(sys.argv) == 3 and sys.argv[1] == 'check':
        policy = json.loads(Path(sys.argv[2]).read_text())
        print(verify(policy['timezone']))
    else:
        raise ValueError('Invalid timezone helper arguments.')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print('ERROR: LXC timezone: ' + str(exc), file=sys.stderr)
        raise SystemExit(1)
EARLY_TIMEZONE_HELPER
chown root:root "$temporary"
chmod 0755 "$temporary"
mv -T "$temporary" "$target"
EARLY_TIMEZONE_GUEST
# BEGIN COMMON: EARLY TIMEZONE PLAN
# COMMON EARLY TIMEZONE PLAN
INSTALL_STAGE="guest timezone validation"
TIMEZONE_PLAN=$(pct exec "$CT_ID" -- /usr/local/sbin/lab-timezone plan "$PRESERVE_EXISTING_TIMEZONE" "$SERVER_TIMEZONE")
APP_TZ=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["effective"])' "$TIMEZONE_PLAN")
printf '  Guest timezone plan: %s (%s during shared hardening).\n' "$APP_TZ" "$TIMEZONE_ACTION"
# END COMMON: EARLY TIMEZONE PLAN

# Explicit bootstrap allowance for --initial only; removed before late hardening.
printf '%s\n' "$TIMEZONE_PLAN" | pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  umask 077
  test ! -e /run/matrix-install-bootstrap.json
  test ! -L /run/matrix-install-bootstrap.json
  cat > /run/matrix-install-bootstrap.json
'

INSTALL_STAGE="UFW setup"
# ── UFW inside the CT ─────────────────────────────────────────────────────────
# Fresh CT only: preserve UFW rule files; add only the selected application rules.
# Network=host means these HTTP listeners use this CT's INPUT chain, without
# published-port NAT bypasses. Outbound federation, DNS and updates remain allowed.
# UFW's standard loopback, established-reply, DHCP and ICMP handling is retained.
pct exec "$CT_ID" -- bash -s -- "$SYNAPSE_PORT" "$ELEMENT_PORT" \
  "${BACKEND_ALLOWED_IPV4[@]}" "${BACKEND_ALLOWED_IPV6[@]}" <<'UFWSETUP'
set -euo pipefail
export LC_ALL=C
synapse_port=$1; element_port=$2; shift 2
# Netfilter must be usable inside this unprivileged CT; no privileged fallback.
iptables -w 5 -S INPUT >/dev/null
ip6tables -w 5 -S INPUT >/dev/null
sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
grep -qx 'IPV6=yes' /etc/default/ufw
# This creator owns /etc/sysctl.d/99-hardening.conf. Avoid a second sysctl writer
# during ufw-init, including attempts to change host-owned/read-only LXC keys.
grep -q '^IPT_SYSCTL=' /etc/default/ufw
sed -i 's|^IPT_SYSCTL=.*|IPT_SYSCTL=|' /etc/default/ufw
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed
ufw logging off
if (( $# == 0 )); then
  ufw allow in proto tcp to any port "$synapse_port"
  ufw allow in proto tcp to any port "$element_port"
fi
for source in "$@"; do
  ufw allow in proto tcp from "$source" to any port "$synapse_port"
  ufw allow in proto tcp from "$source" to any port "$element_port"
done
ufw --force enable
systemctl enable ufw.service
systemctl restart ufw.service
# Verify each specific allow reached the active IPv4/IPv6 rules, not only disk.
for source in "$@"; do
  tool=iptables; prefix=ufw
  if [[ $source == *:* ]]; then tool=ip6tables; prefix=ufw6; fi
  for port in "$synapse_port" "$element_port"; do
    "$tool" -w 5 -C "${prefix}-user-input" -s "$source" -p tcp -m tcp --dport "$port" -j ACCEPT
  done
done
if (( $# == 0 )); then
  for tool in iptables ip6tables; do
    prefix=ufw; [[ $tool != ip6tables ]] || prefix=ufw6
    for port in "$synapse_port" "$element_port"; do
      "$tool" -w 5 -C "${prefix}-user-input" -p tcp -m tcp --dport "$port" -j ACCEPT
    done
  done
fi
ufw status verbose
UFWSETUP

# Store the selected policy without executing it as shell code.
python3 - "$SYNAPSE_PORT" "$ELEMENT_PORT" "${BACKEND_ALLOWED_IPV4[@]}" "${BACKEND_ALLOWED_IPV6[@]}" <<'FWPOLICY' | pct exec "$CT_ID" -- bash -c 'set -euo pipefail; install -d -m 0755 /opt/matrix; cat > /opt/matrix/firewall-policy.json; chmod 0644 /opt/matrix/firewall-policy.json'
import ipaddress, json, sys
print(json.dumps({'ports': list(map(int, sys.argv[1:3])),
                  'sources': [str(ipaddress.ip_network(s)) for s in sys.argv[3:]]}))
FWPOLICY

tmp="$(mktemp)"
cat > "$tmp" <<'UFWCHECK'
#!/usr/bin/python3
"""Read-only Matrix UFW guard: exact host access and reachable INPUT policy."""
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

os.environ['PATH'] = '/usr/sbin:/usr/bin:/sbin:/bin'
os.environ['LC_ALL'] = 'C'


def require(ok, label):
    if not ok:
        raise RuntimeError(label)


def run(args):
    p = subprocess.run(args, text=True, capture_output=True, timeout=20)
    require(p.returncode == 0, 'Cannot read required UFW/netfilter state')
    return p.stdout.strip()


def normalize(words):
    words = list(words)
    for token in ('-s', '-d'):
        if token in words:
            i = words.index(token) + 1
            words[i] = str(ipaddress.ip_network(words[i], strict=True))
    return tuple(words)


def table_check(text, family, prefix, ports, sources):
    chains, policies = {}, {}
    for line in text.splitlines():
        words = shlex.split(line)
        require(bool(words), 'Empty filter rule')
        if words[0] == '-P' and len(words) == 3:
            policies[words[1]] = words[2]
            chains.setdefault(words[1], [])
        elif words[0] == '-N' and len(words) == 2:
            chains.setdefault(words[1], [])
        elif words[0] == '-A' and len(words) >= 4:
            chains.setdefault(words[1], []).append(normalize(words))
        else:
            raise RuntimeError('Unrecognized filter-table declaration')
    require(policies == {'INPUT': 'DROP', 'FORWARD': 'DROP', 'OUTPUT': 'ACCEPT'},
            'Effective filter defaults differ from deny-in/deny-routed/allow-out')
    hooks = [prefix + '-' + suffix for suffix in
             ('before-logging-input', 'before-input', 'after-input',
              'after-logging-input', 'reject-input', 'track-input')]
    require(chains.get('INPUT') == [('-A', 'INPUT', '-j', hook) for hook in hooks],
            'INPUT must contain only the ordered UFW hooks')
    user = prefix + '-user-input'
    networks = [s for s in sources if s.version == family] if sources else [None]
    expected = set()
    for source in networks:
        for port in ports:
            rule = ['-A', user] + (['-s', str(source)] if source else [])
            expected.add(tuple(rule + ['-p', 'tcp', '-m', 'tcp', '--dport', str(port), '-j', 'ACCEPT']))
    actual = chains.get(user)
    require(actual is not None and len(actual) == len(expected) and set(actual) == expected,
            'Selected host/port rules differ or contain extra rules')
    require(('-A', prefix + '-before-input', '-j', user) in chains.get(prefix + '-before-input', []),
            'UFW before-input does not reach the selected user policy')

    # Conservatively examine paths for new, non-loopback TCP. Standard DHCP,
    # ICMP, established replies and local loopback are separate control traffic.
    # Follow declared chains before classifying terminal targets: UFW uses its
    # own ufw[-6]-skip-to-policy and not-local chains as normal control flow.
    seen = set()
    def walk(chain, stack=()):
        require(chain not in stack, 'Cyclic reachable INPUT chain')
        require(chain in chains, 'Missing reachable INPUT chain')
        if chain in seen:
            return
        seen.add(chain)
        for rule in chains[chain]:
            def value(option):
                return rule[rule.index(option) + 1] if option in rule else None
            # Negation prevents these exclusions; ambiguous rules fail closed.
            if '!' not in rule:
                if value('-p') not in (None, 'tcp', '6', 'all', '0'):
                    continue
                if value('-i') == 'lo':
                    continue
                states = value('--ctstate') or value('--state')
                if states and 'NEW' not in states.split(','):
                    continue
            jump = value('-j') or value('-g')
            require(jump is not None, 'Reachable INPUT rule has no reviewed target')
            if jump in chains:
                walk(jump, stack + (chain,))
            elif jump == 'ACCEPT':
                require(chain == user and rule in expected,
                        'Reachable TCP acceptance bypasses selected host/port policy')
            elif jump not in ('DROP', 'REJECT', 'RETURN', 'LOG', 'NFLOG'):
                raise RuntimeError('Unrecognized reachable INPUT target; review custom filtering')
    walk('INPUT')


def main():
    require(os.geteuid() == 0 and len(sys.argv) == 1, 'Run Matrix UFW guard as root without arguments')
    for filename, expected in [('/etc/ufw/ufw.conf', {'ENABLED': 'yes'}),
            ('/etc/default/ufw', {'IPV6': 'yes', 'DEFAULT_INPUT_POLICY': 'DROP',
                                 'DEFAULT_FORWARD_POLICY': 'DROP', 'DEFAULT_OUTPUT_POLICY': 'ACCEPT'})]:
        content = Path(filename).read_text()
        for key, value in expected.items():
            found = re.findall(r'^' + key + r'=(.*)$', content, re.M)
            require(len(found) == 1 and found[0].strip('"\'') == value,
                    'Persistent UFW defaults/enablement differ')
    require('Status: active' in run(['ufw', 'status']).splitlines(), 'UFW is inactive')
    run(['systemctl', 'is-enabled', '--quiet', 'ufw.service'])
    policy_path = Path('/opt/matrix/firewall-policy.json')
    st = policy_path.lstat()
    require(policy_path.is_file() and not policy_path.is_symlink() and st.st_uid == 0
            and not st.st_mode & 0o022, 'Unsafe firewall policy file')
    policy = json.loads(policy_path.read_text())
    ports = policy['ports']
    require(len(ports) == 2 and all(type(p) is int and 1024 <= p <= 65535 and p != 5432 for p in ports)
            and len(set(ports)) == 2, 'Invalid Matrix firewall ports')
    sources = [ipaddress.ip_network(s, strict=True) for s in policy['sources']]
    require(all(s.prefixlen == s.max_prefixlen and not
                (s.network_address.is_multicast or s.network_address.is_unspecified or s.network_address.is_loopback)
                for s in sources), 'Matrix restrictions require reachable host addresses')
    require(not sources or any(s.version == 4 for s in sources), 'Restricted Synapse needs an IPv4 source')
    for family, tool, prefix in [(4, 'iptables', 'ufw'), (6, 'ip6tables', 'ufw6')]:
        table_check(run([tool, '-w', '5', '-S']), family, prefix, ports, sources)


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        detail = str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__
        print('ERROR: Matrix UFW: ' + detail, file=sys.stderr)
        raise SystemExit(1)
UFWCHECK
pct push "$CT_ID" "$tmp" /usr/local/sbin/matrix-ufw-check --perms 0755
rm -f "$tmp"
if ! pct exec "$CT_ID" -- /usr/local/sbin/matrix-ufw-check; then
  echo "  ERROR: UFW did not establish IPv4/IPv6 filtering inside CT $CT_ID." >&2
  echo "  Inspect: pct exec $CT_ID -- ufw status verbose" >&2
  false
fi

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

INSTALL_STAGE="image compatibility"
# ── Pull images ───────────────────────────────────────────────────────────────
for img in "$POSTGRES_IMAGE" "$SYNAPSE_IMAGE" "$ELEMENT_IMAGE"; do
  echo "  Pulling image: ${img} ..."
  pct exec "$CT_ID" -- bash -lc "
    set -euo pipefail
    podman pull '${img}'
  "
done

# Resolve the pulled images once. Every generated service uses its content ID.
for component in SYNAPSE ELEMENT POSTGRES; do
  reference_var="${component}_IMAGE"
  resolved=$(pct exec "$CT_ID" -- podman image inspect --format '{{.Id}}' "${!reference_var}")
  resolved=${resolved#sha256:}
  [[ $resolved =~ ^[a-f0-9]{64}$ ]] || { echo "ERROR: Invalid resolved image ID for $component." >&2; false; }
  printf -v "${component}_IMAGE_ID" 'sha256:%s' "$resolved"
done

INSTALL_STAGE="image compatibility"
# ── Detect container UIDs/GIDs for bind mounts ────────────────────────────────
# PostgreSQL drops to its own service user before touching the mount; the UID
# differs between the Debian (999) and Alpine (70) variants, so read it from
# the image instead of hardcoding. Synapse's start.py drops to UID/GID from the
# environment (991:991 is the image default) — that value is ours to choose and
# is passed explicitly to both `generate` and the Quadlet unit. Element Web is
# nginx-unprivileged and only reads a root-owned 0644 config file.
# --network none: the probes need no network and must not touch Netavark.
POSTGRES_UID="$(pct exec "$CT_ID" -- podman run --rm --network none --entrypoint sh "$POSTGRES_IMAGE_ID" -c 'id -u postgres 2>/dev/null || id -u' 2>/dev/null | tr -d '\r')"
POSTGRES_GID="$(pct exec "$CT_ID" -- podman run --rm --network none --entrypoint sh "$POSTGRES_IMAGE_ID" -c 'id -g postgres 2>/dev/null || id -g' 2>/dev/null | tr -d '\r')"

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
#   /opt/matrix/postgres.env          bootstrap/admin + application initialization credentials
# Create the mount roots and empty media directory; PostgreSQL initializes its own cluster.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  install -d -m 0755 '${APP_DIR}'
  install -d -m 0750 -o ${POSTGRES_UID} -g ${POSTGRES_GID} '${APP_DIR}/postgresdata'
  install -d -m 0750 -o ${SYNAPSE_UID}  -g ${SYNAPSE_GID}  '${SYNAPSE_DATA_DIR}' '${SYNAPSE_DATA_DIR}/media_store'
"

INSTALL_STAGE="application configuration"
# ── Generate Synapse homeserver.yaml ──────────────────────────────────────────
# The image's `generate` mode renders the log config before dropping privileges;
# it can remain root-owned and must be readable by UID:GID 991:991. Homeserver
# config and signing key are generated as UID:GID with --open-private-ports; the listener
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
    '${SYNAPSE_IMAGE_ID}' generate
  test -f '${SYNAPSE_DATA_DIR}/homeserver.yaml'
  test -f '${SYNAPSE_DATA_DIR}/${SYNAPSE_SERVER_NAME}.signing.key'
  test -f '${SYNAPSE_DATA_DIR}/${SYNAPSE_SERVER_NAME}.log.config'
"
echo "  homeserver.yaml, signing key and log config generated"

# ── Generate structured Synapse configuration ────────────────────────────────
# NUL-delimited stdin keeps secrets out of argv; PyYAML quotes values safely.
printf '%s\0' "$SYNAPSE_SERVER_NAME" "$SYNAPSE_PORT" "$DB_PASSWORD" "$MAX_UPLOAD_SIZE" \
  "$TURN_MODE" "$TURN_SHARED_SECRET" "$TURN_USER_LIFETIME_MS" "$TURN_ALLOW_GUESTS" \
  "$MATRIX_RTC_AUTH_URL" "${TURN_URIS[@]}" | \
  pct exec "$CT_ID" -- python3 -c "$(cat <<'PYCONFIG'
import os, pathlib, sys, tempfile, yaml
values = sys.stdin.buffer.read().decode().split("\0")
if values.pop() != "": raise SystemExit("Truncated config input")
server, port, password, upload, mode, secret, lifetime, guests, rtc = values[:9]
uris = values[9:]
path = pathlib.Path("/opt/matrix/synapse/homeserver.yaml")
class UniqueLoader(yaml.SafeLoader):
    pass
def unique_mapping(loader, node, deep=False):
    result = {}
    for k, v in node.value:
        key = loader.construct_object(k, deep=deep)
        if key in result: raise ValueError("Duplicate YAML key: " + str(key))
        result[key] = loader.construct_object(v, deep=deep)
    return result
UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)
config = yaml.load(path.read_text(), Loader=UniqueLoader)
if config.get("server_name") != server or not config.get("registration_shared_secret"):
    raise SystemExit("Generated identity/shared registration secret missing or unexpected")
config.update({
    "listeners": [{"port": int(port), "tls": False, "type": "http", "x_forwarded": True,
                   "bind_addresses": ["0.0.0.0"],
                   "resources": [{"names": ["client", "federation"], "compress": False}]}],
    "database": {"name": "psycopg2", "txn_limit": 10000,
                 "args": {"user": "synapse", "password": password, "database": "synapse",
                          "host": "127.0.0.1", "port": 5432, "cp_min": 5, "cp_max": 10}},
    "public_baseurl": "https://" + server + "/", "serve_server_wellknown": True,
    "max_upload_size": upload, "enable_registration": True, "registration_requires_token": True,
    "presence": {"enabled": True}, "media_retention": {"remote_media_lifetime": "90d"},
    "forgotten_room_retention_period": "7d",
    "turn_uris": uris, "turn_allow_guests": guests == "1",
    "turn_user_lifetime": int(lifetime),
    "url_preview_enabled": True,
    "url_preview_ip_range_blacklist": ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
        "100.64.0.0/10", "192.0.0.0/24", "169.254.0.0/16", "192.88.99.0/24", "198.18.0.0/15",
        "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "::1/128",
        "fe80::/10", "fc00::/7", "2001:db8::/32", "ff00::/8", "fec0::/10"]})
if mode != "disabled": config["turn_shared_secret"] = secret
else: config.pop("turn_shared_secret", None)
if rtc:
    # Element Call's documented Synapse prerequisites, plus discovery for older clients.
    config["experimental_features"] = {"msc3266_enabled": True, "msc4143_enabled": True, "msc4222_enabled": True}
    config["max_event_delay_duration"] = "24h"
    config["rc_message"] = {"per_second": 0.5, "burst_count": 30}
    config["rc_delayed_event_mgmt"] = {"per_second": 1, "burst_count": 20}
    config["matrix_rtc"] = {"transports": [{"type": "livekit", "livekit_service_url": rtc}]}
    config["extra_well_known_client_content"] = {"org.matrix.msc4143.rtc_foci": [
        {"type": "livekit", "livekit_service_url": rtc}]}
fd, temp = tempfile.mkstemp(dir=path.parent)
try:
    with os.fdopen(fd, "w") as f:
        yaml.safe_dump(config, f, sort_keys=False); f.flush(); os.fsync(f.fileno())
    os.chown(temp, 991, 991); os.chmod(temp, 0o600); os.replace(temp, path)
finally:
    if os.path.exists(temp): os.unlink(temp)
PYCONFIG
)"

# Use the installed image's real parser. This reads configuration without
# starting Synapse or running database migrations, and must succeed before start.
pct exec "$CT_ID" -- podman run --rm --pull=never --network none --user 991:991 \
  -v "$SYNAPSE_DATA_DIR:/data:ro" --entrypoint python "$SYNAPSE_IMAGE_ID" \
  -m synapse.config -c /data/homeserver.yaml
echo "  Synapse configuration parsed successfully"

# ── Element Web config ────────────────────────────────────────────────────────
# Mounted read-only at /app/config.json. Element talks to Synapse through the
# public base_url (https://matrix.<domain>), so DNS + reverse proxy must exist
# before Element is usable. Use public HTTPS with split DNS for LAN clients;
# direct backend access follows the selected UFW source policy.
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
# MatrixTag=${POSTGRES_TAG}
# MatrixImage=${POSTGRES_IMAGE}
Image=${POSTGRES_IMAGE_ID}
Pull=never
ContainerName=matrix-postgres
Network=host
Exec=postgres -c listen_addresses=127.0.0.1
Environment=TZ=${APP_TZ}
Environment=POSTGRES_DB=postgres
Environment=POSTGRES_USER=postgres
Environment=PGDATA=/var/lib/postgresql/18/docker
EnvironmentFile=${POSTGRES_ENV_FILE}
Volume=${APP_DIR}/postgresdata:/var/lib/postgresql
Volume=${APP_DIR}/postgres-init.sh:/docker-entrypoint-initdb.d/10-synapse.sh:ro
StopTimeout=110
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
TimeoutStartSec=600
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF2

  cat > '${SYNAPSE_QUADLET_FILE}' <<EOF2
[Unit]
Description=Matrix Synapse homeserver
After=network-online.target ufw.service ${POSTGRES_QUADLET_SERVICE}
Wants=network-online.target
Requires=ufw.service ${POSTGRES_QUADLET_SERVICE}

[Container]
# MatrixTag=${SYNAPSE_TAG}
# MatrixImage=${SYNAPSE_IMAGE}
Image=${SYNAPSE_IMAGE_ID}
Pull=never
ContainerName=matrix-synapse
Network=host
Environment=TZ=${APP_TZ}
Environment=UID=${SYNAPSE_UID}
Environment=GID=${SYNAPSE_GID}
Environment=SYNAPSE_CONFIG_PATH=/data/homeserver.yaml
Volume=${SYNAPSE_DATA_DIR}:/data
StopTimeout=80
Ulimit=nofile=65535:65535
HealthCmd=curl -fsS -o /dev/null http://127.0.0.1:${SYNAPSE_PORT}/health
HealthInterval=30s
HealthTimeout=10s
HealthRetries=3
HealthStartPeriod=60s
LogDriver=journald

[Service]
ExecStartPre=/usr/local/sbin/matrix-ufw-check
Restart=always
RestartSec=5
TimeoutStopSec=90

[Install]
WantedBy=multi-user.target
EOF2

  cat > '${ELEMENT_QUADLET_FILE}' <<EOF2
[Unit]
Description=Element Web for Matrix
After=network-online.target ufw.service
Wants=network-online.target
Requires=ufw.service

[Container]
# MatrixTag=${ELEMENT_TAG}
# MatrixImage=${ELEMENT_IMAGE}
Image=${ELEMENT_IMAGE_ID}
Pull=never
ContainerName=matrix-element
Network=host
Environment=TZ=${APP_TZ}
Environment=ELEMENT_WEB_PORT=${ELEMENT_PORT}
Volume=${ELEMENT_CONFIG_FILE}:/app/config.json:ro
StopTimeout=20
LogDriver=journald

[Service]
ExecStartPre=/usr/local/sbin/matrix-ufw-check
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
  printf '# Separate bootstrap superuser; Synapse uses its own restricted database role.\n'
  printf 'POSTGRES_PASSWORD=%s\n' "$PG_ADMIN_PASSWORD"
  printf 'SYNAPSE_DB_PASSWORD=%s\n' "$DB_PASSWORD"
  printf 'POSTGRES_INITDB_ARGS=--encoding=UTF8 --lc-collate=C --lc-ctype=C --auth-host=scram-sha-256 --auth-local=trust\n'
  printf 'POSTGRES_HOST_AUTH_METHOD=scram-sha-256\n'
} | pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  umask 077
  cat > '${POSTGRES_ENV_FILE}'
  chmod 0600 '${POSTGRES_ENV_FILE}'
"
# Initialization script contains no credentials; only validated hex enters SQL.
pct exec "$CT_ID" -- bash -c 'cat > /opt/matrix/postgres-init.sh; chmod 0755 /opt/matrix/postgres-init.sh' <<'PGINIT'
#!/usr/bin/env bash
set -Eeuo pipefail
: "${SYNAPSE_DB_PASSWORD:?Missing application bootstrap password}"
[[ $SYNAPSE_DB_PASSWORD =~ ^[a-f0-9]{64}$ ]] || { echo "Invalid application bootstrap secret format." >&2; exit 1; }
# The generated secret is hex only. Stream SQL on stdin; no password in psql argv.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<SQL
CREATE ROLE synapse LOGIN PASSWORD '${SYNAPSE_DB_PASSWORD}' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE DATABASE synapse OWNER synapse ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;
REVOKE ALL ON DATABASE synapse FROM PUBLIC;
SQL
PGINIT


# ── Expected application policy ───────────────────────────────────────────────
python3 - "$APP_TZ" "$SYNAPSE_SERVER_NAME" "$SYNAPSE_PORT" "$ELEMENT_PORT" \
  "$TURN_MODE" "$TURN_USER_LIFETIME_MS" "$TURN_ALLOW_GUESTS" "$MATRIX_RTC_AUTH_URL" \
  "$MATRIX_RTC_HEALTH_URL" "$MAX_UPLOAD_SIZE" "${TURN_URIS[@]}" <<'APP_POLICY' | pct exec "$CT_ID" -- bash -c 'set -euo pipefail; umask 022; cat > /opt/matrix/install-policy.json; chmod 0644 /opt/matrix/install-policy.json'
import json, sys
zone, server, sy, el, turn, lifetime, guests, rtc, health, upload = sys.argv[1:11]
print(json.dumps({'timezone': zone, 'server_name': server, 'synapse_port': int(sy),
    'element_port': int(el), 'turn_mode': turn, 'turn_lifetime': int(lifetime),
    'turn_guests': guests == '1', 'rtc_auth': rtc, 'rtc_health': health,
    'max_upload_size': upload, 'turn_uris': sys.argv[11:]}))
APP_POLICY

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
SYNAPSE_IMAGE_ID=${SYNAPSE_IMAGE_ID}
ELEMENT_IMAGE_REPO=${ELEMENT_IMAGE_REPO}
ELEMENT_TAG=${ELEMENT_TAG}
ELEMENT_IMAGE=${ELEMENT_IMAGE}
ELEMENT_IMAGE_ID=${ELEMENT_IMAGE_ID}
POSTGRES_IMAGE_REPO=${POSTGRES_IMAGE_REPO}
POSTGRES_TAG=${POSTGRES_TAG}
POSTGRES_IMAGE=${POSTGRES_IMAGE}
POSTGRES_IMAGE_ID=${POSTGRES_IMAGE_ID}
MATRIX_DOMAIN=${MATRIX_DOMAIN}
SYNAPSE_SERVER_NAME=${SYNAPSE_SERVER_NAME}
SYNAPSE_FQDN=${SYNAPSE_FQDN}
ELEMENT_FQDN=${ELEMENT_FQDN}
SYNAPSE_PORT=${SYNAPSE_PORT}
ELEMENT_PORT=${ELEMENT_PORT}
APP_TZ=${APP_TZ}
AUTO_UPDATE=${AUTO_UPDATE}
UPDATE_TIME=${UPDATE_TIME}
INITIAL_WAIT_SECONDS=${INITIAL_WAIT_SECONDS}
UPDATE_WAIT_SECONDS=${UPDATE_WAIT_SECONDS}
PODMAN_FUSE_OVERLAY=${PODMAN_FUSE_OVERLAY}
TURN_MODE=${TURN_MODE}
MATRIX_RTC_AUTH_URL=${MATRIX_RTC_AUTH_URL}
MATRIX_RTC_HEALTH_URL=${MATRIX_RTC_HEALTH_URL}
EOF2
  chmod 0600 '${APP_DIR}/.env'
"

# ── Final verification helper ─────────────────────────────────────────────────
# Reads configuration/runtime state; no updates, restarts or report-file writes.
tmp=$(mktemp)
cat > "$tmp" <<'MATRIX_VERIFY'
#!/usr/bin/python3
"""Read-only Matrix checks. No repairs, package/image changes or report writes."""
import ipaddress
from datetime import datetime
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
import urllib.request
import yaml
from zoneinfo import ZoneInfo

os.environ['PATH'] = '/usr/sbin:/usr/bin:/sbin:/bin'
os.environ['LC_ALL'] = 'C'
errors = []

def require(ok, label):
    if not ok:
        raise RuntimeError(label)

def run(args, label, data=None, acceptable=(0,)):
    p = subprocess.run(args, input=data, text=True, capture_output=True, timeout=30)
    # Never print argv/environment or raw stderr: either may contain credentials.
    require(p.returncode in acceptable, f'{label}: command failed (rc={p.returncode})')
    return p.stdout.strip()

def state_file(path):
    result = {}
    for line in Path(path).read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        k, v = line.split('=', 1)
        require(re.fullmatch(r'[A-Z][A-Z0-9_]*', k) and k not in result, 'Malformed/duplicate configuration key')
        result[k] = v
    return result

def http(port, path):
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(f'http://127.0.0.1:{port}{path}', timeout=5) as response:
        require(response.status == 200, 'Unexpected HTTP status')
        return response.read()

def check_firewall():
    run(['/usr/local/sbin/matrix-ufw-check'], 'UFW boot guard')
    policy = json.loads(Path('/opt/matrix/firewall-policy.json').read_text())
    require(policy['ports'] == [sy_port, el_port], 'Firewall/application ports differ')

def service_counts():
    result = {}
    for container in ('matrix-postgres', 'matrix-synapse', 'matrix-element'):
        value = run(['systemctl', 'show', container + '.service', '-p', 'NRestarts', '--value'], 'Service restart count')
        require(value.isdigit(), 'Missing service restart count')
        result[container] = value
    return result

def wait_ready():
    restart_counts.update(service_counts())
    require(not initial or all(v == '0' for v in restart_counts.values()), 'Unexpected initial service restart')
    deadline = time.monotonic() + wait_seconds
    while True:
        require(service_counts() == restart_counts, 'Service restarted while waiting for readiness')
        ready = True
        for container in restart_counts:
            status = run(['systemctl', 'show', container + '.service', '-p', 'ActiveState', '--value'], 'Service startup state')
            require(status not in ('failed', 'inactive', 'deactivating'), 'Service failed/stopped before readiness')
            ready = ready and status == 'active'
        try:
            run(['podman', 'exec', 'matrix-postgres', 'pg_isready', '-h', '127.0.0.1', '-U', 'synapse', '-d', 'synapse'], 'Database startup readiness')
            http(sy_port, '/health')
            http(el_port, '/')
            if ready:
                return
        except Exception:
            pass
        require(time.monotonic() < deadline, 'Application readiness budget expired; services left for inspection')
        time.sleep(2)

def check_synapse_generated_files():
    # `generate` renders log.config before dropping privileges. It can remain
    # root-owned; the signing key is generated by Synapse as UID 991.
    # Verify access without rewriting either file or exposing its contents.
    for suffix, label, owners in [('.signing.key', 'Synapse signing key', (991,)),
                                   ('.log.config', 'Synapse log configuration', (0, 991))]:
        filename = state['SYNAPSE_SERVER_NAME'] + suffix
        path = Path('/opt/matrix/synapse') / filename
        try:
            info = path.lstat()
        except FileNotFoundError:
            raise RuntimeError(label + ': missing file') from None
        require(stat.S_ISREG(info.st_mode) and info.st_size > 0,
                label + ': expected nonempty regular file')
        require(info.st_uid in owners,
                f'{label}: uid={info.st_uid}, gid={info.st_gid}; expected uid in {owners}')
        require(info.st_mode & 0o022 == 0,
                f'{label}: unsafe group/other write permissions (mode={info.st_mode & 0o7777:04o})')
        run(['podman', 'exec', '--user', '991:991', 'matrix-synapse', 'python', '-c',
             'import os,sys; assert (os.getuid(),os.getgid()) == (991,991); '
             'f=open(sys.argv[1],"rb"); sys.exit(0 if f.read(1) else 1)',
             '/data/' + filename], label + ': runtime readability as 991:991')

def check_identity():
    for name, key, mounts in [
        ('synapse', 'SYNAPSE', {'/data': ('/opt/matrix/synapse', True)}),
        ('element', 'ELEMENT', {'/app/config.json': ('/opt/matrix/element-config.json', False)}),
        ('postgres', 'POSTGRES', {'/var/lib/postgresql': ('/opt/matrix/postgresdata', True),
                               '/docker-entrypoint-initdb.d/10-synapse.sh': ('/opt/matrix/postgres-init.sh', False)})]:
        container = 'matrix-' + name
        unit = Path('/etc/containers/systemd/' + container + '.container').read_text()
        ids = re.findall(r'^Image=(sha256:[a-f0-9]{64})$', unit, re.M)
        require(len(ids) == 1 and ids[0] == state[key + '_IMAGE_ID'], container + ': image metadata mismatch')
        require(re.findall(r'^Pull=(.*)$', unit, re.M) == ['never'], container + ': Pull policy')
        require(re.findall(r'^Network=(.*)$', unit, re.M) == ['host'], container + ': Quadlet host network')
        require(re.findall(r'^# MatrixTag=(.*)$', unit, re.M) == [state[key + '_TAG']], container + ': tag metadata')
        require(re.findall(r'^# MatrixImage=(.*)$', unit, re.M) == [state[key + '_IMAGE']], container + ': reference metadata')
        require(state[key + '_IMAGE'] == state[key + '_IMAGE_REPO'] + ':' + state[key + '_TAG'], container + ': repository metadata')
        info = json.loads(run(['podman', 'inspect', container], container + ' inspection'))[0]
        require(info['State']['Running'] and 'sha256:' + info['Image'].removeprefix('sha256:') == ids[0], container + ': running image/identity')
        require(info['HostConfig']['NetworkMode'] == 'host', container + ': host network')
        actual = {m['Destination']: (m['Source'], m['RW']) for m in info['Mounts']}
        require(len(actual) == len(info['Mounts']) and actual == mounts, container + ': unexpected/duplicate persistent mount')
        for destination, value in mounts.items():
            require(actual.get(destination) == value, container + ': persistent mount ' + destination)
        run(['systemctl', 'is-active', '--quiet', container + '.service'], container + ' active')
        before = run(['systemctl', 'show', container + '.service', '-p', 'NRestarts', '--value'], container + ' restarts')
        require(before.isdigit(), container + ': missing restart counter')
        require(restart_counts.get(container) == before and (not initial or before == '0'), container + ': restart count changed')
        process_rows = run(['podman', 'top', container, 'hpid'], container + ' process membership').splitlines()
        require(process_rows and process_rows[0].strip().upper() == 'HPID', 'Unexpected process inventory format')
        process_ids = {int(row.strip()) for row in process_rows[1:] if row.strip().isdigit()}
        require(len(process_ids) == len(process_rows) - 1 and info['State']['Pid'] in process_ids, container + ': process inventory')
        container_pids[container] = process_ids
        status = Path('/proc/' + str(info['State']['Pid']) + '/status').read_text()
        uid = int(re.search(r'^Uid:\s+(\d+)', status, re.M)[1])
        if name == 'synapse':
            require(uid == 991, 'Synapse main process UID must be 991')
            gid = int(re.search(r'^Gid:\s+(\d+)', status, re.M)[1])
            require(gid == 991, 'Synapse main process GID must be 991')
            for item in ('UID=991', 'GID=991', 'SYNAPSE_CONFIG_PATH=/data/homeserver.yaml'):
                require(item in info['Config']['Env'], 'Synapse runtime identity/configuration environment')
        elif name == 'postgres':
            expected_uid = int(run(['podman', 'exec', container, 'id', '-u', 'postgres'], 'PostgreSQL UID'))
            require(uid == expected_uid and uid != 0, 'PostgreSQL main process UID')
            require('PGDATA=/var/lib/postgresql/18/docker' in info['Config']['Env'], 'PostgreSQL runtime data directory')
            cluster = Path('/opt/matrix/postgresdata/18/docker')
            require((cluster / 'PG_VERSION').read_text().strip() == '18', 'PostgreSQL persistent major')
            # The selected official entrypoint uses `chown postgres` (UID only)
            # and chmod 00700. PGDATA can therefore be postgres:root; owner-only
            # access makes its group irrelevant. Never chown it to satisfy a check.
            cluster_info = cluster.stat()
            require(cluster_info.st_uid == expected_uid,
                    f'PostgreSQL cluster ownership: uid={cluster_info.st_uid}, gid={cluster_info.st_gid}; expected uid={expected_uid}')
            cluster_mode = cluster_info.st_mode & 0o7777
            require(cluster_mode == 0o700,
                    f'PostgreSQL cluster permissions: mode={cluster_mode:04o}; expected 0700')
        else:
            require(uid != 0, 'Element main process must remain unprivileged')
    for path in ['/opt/matrix/synapse', '/opt/matrix/synapse/media_store']:
        st = Path(path).stat()
        require((st.st_uid, st.st_gid) == (991, 991), 'Synapse data ownership')
    for path in ['/opt/matrix/synapse/homeserver.yaml', '/opt/matrix/postgres.env']:
        require(Path(path).stat().st_mode & 0o777 == 0o600, 'Credential file mode: ' + path)
    check_synapse_generated_files()
    require(Path('/opt/matrix/element-config.json').stat().st_uid == 0 and
            Path('/opt/matrix/element-config.json').stat().st_mode & 0o777 == 0o644, 'Element read-only config ownership/mode')

def check_http():
    http(sy_port, '/health')
    key = json.loads(http(sy_port, '/_matrix/key/v2/server'))
    require(key['server_name'] == state['SYNAPSE_SERVER_NAME'], 'Synapse server identity')
    versions = json.loads(http(sy_port, '/_matrix/client/versions'))
    require(bool(versions['versions']), 'Matrix client versions response')
    require(json.loads(http(el_port, '/config.json')) == json.loads(Path('/opt/matrix/element-config.json').read_text()), 'Element served configuration')
    index = run(['podman', 'exec', 'matrix-element', 'cat', '/app/index.html'], 'Element image index')
    require(http(el_port, '/').decode().strip() == index, 'Element index differs from running image')
    discovery = json.loads(http(sy_port, '/.well-known/matrix/client'))
    require(discovery['m.homeserver']['base_url'].rstrip('/') == 'https://' + state['SYNAPSE_FQDN'], 'Client discovery base URL')
    server = json.loads(http(sy_port, '/.well-known/matrix/server'))
    require(server['m.server'] == state['SYNAPSE_FQDN'] + ':443', 'Federation discovery')
    if app_policy['rtc_auth']:
        require(discovery.get('org.matrix.msc4143.rtc_foci') ==
                [{'type': 'livekit', 'livekit_service_url': app_policy['rtc_auth']}], 'MatrixRTC discovery')

def check_database():
    run(['podman', 'exec', 'matrix-postgres', 'pg_isready', '-h', '127.0.0.1', '-U', 'synapse', '-d', 'synapse'], 'Database readiness')
    password = config['database']['args']['password']
    env = state_file('/opt/matrix/postgres.env')
    require(password == env['SYNAPSE_DB_PASSWORD'], 'Synapse/database credential match')
    for name in ['POSTGRES_PASSWORD', 'SYNAPSE_DB_PASSWORD', 'POSTGRES_INITDB_ARGS']:
        got = run(['podman', 'exec', 'matrix-postgres', 'printenv', name], name + ' round trip')
        require(got == env[name], name + ' round trip differs')
    sql = "SELECT current_user = 'synapse' AND (SELECT count(*) > 0 FROM information_schema.tables WHERE table_schema='public');"
    output = run(['podman', 'exec', '-i', 'matrix-postgres', 'bash', '-c',
        'IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql -X -w -v ON_ERROR_STOP=1 -h 127.0.0.1 -U synapse -d synapse -tAc "$1"', 'verify', sql], 'Authenticated application-role query/migrations', password + '\n')
    require(output == 't', 'Application-role schema/migration query')
    bad = subprocess.run(['podman', 'exec', '-e', 'PGPASSWORD=deliberately-wrong', 'matrix-postgres', 'psql', '-X', '-w', '-h', '127.0.0.1', '-U', 'synapse', '-d', 'synapse', '-tAc', 'SELECT 1'], capture_output=True, text=True, timeout=15)
    require(bad.returncode != 0 and 'password authentication failed' in bad.stderr, 'Wrong password must fail specifically with authentication rejection')
    queries = [
        "SELECT rolcanlogin AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication AND NOT rolbypassrls FROM pg_roles WHERE rolname='synapse'",
        "SELECT pg_get_userbyid(datdba)='synapse' AND datcollate='C' AND datctype='C' FROM pg_database WHERE datname='synapse'",
        "SELECT count(*)=0 FROM pg_hba_file_rules WHERE error IS NOT NULL OR (type LIKE 'host%' AND auth_method <> 'scram-sha-256')"]
    for label, query in zip(['Application role restrictions', 'Database owner/locale', 'SCRAM host policy'], queries):
        require(run(['podman', 'exec', 'matrix-postgres', 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres', '-tAc', query], label) == 't', label)

def check_sockets():
    sockets = run(['ss', '-H', '-lntp'], 'TCP socket/process inventory')
    ports = {}
    for line in sockets.splitlines():
        endpoint = line.split()[3]
        address, port = endpoint.rsplit(':', 1)
        address = address.split('%', 1)[0].strip('[]')
        ports.setdefault(int(port), []).append(address)
        owner = {5432: 'matrix-postgres', sy_port: 'matrix-synapse', el_port: 'matrix-element'}.get(int(port))
        if owner:
            pids = {int(p) for p in re.findall(r'pid=(\d+)', line)}
            require(pids and pids <= container_pids.get(owner, set()), 'Application socket belongs to unexpected/unidentified process')
    require(ports.get(5432) == ['127.0.0.1'], 'PostgreSQL must listen on IPv4 loopback only')
    require(ports.get(sy_port) == ['0.0.0.0'], 'Synapse wildcard IPv4 listener differs from configured bind')
    require(ports.get(el_port) and all(a in ('0.0.0.0', '::', '*') for a in ports[el_port]), 'Element wildcard listener missing/changed')

def check_configuration():
    require(app_policy['server_name'] == state['SYNAPSE_SERVER_NAME'] == config['server_name'], 'Immutable Matrix identity differs')
    require([app_policy['synapse_port'], app_policy['element_port']] == [sy_port, el_port], 'Recorded Matrix ports differ')
    require(config['listeners'] == [{'port': sy_port, 'tls': False, 'type': 'http', 'x_forwarded': True,
        'bind_addresses': ['0.0.0.0'], 'resources': [{'names': ['client', 'federation'], 'compress': False}]}], 'Synapse bind/resource/proxy-header contract')
    require(config['database']['name'] == 'psycopg2', 'Synapse database driver')
    for key, expected in {'user': 'synapse', 'database': 'synapse', 'host': '127.0.0.1', 'port': 5432}.items():
        require(config['database']['args'][key] == expected, 'Synapse database endpoint/role contract')
    require(config['media_store_path'] == '/data/media_store', 'Synapse media must remain in persistent data mount')
    require(config['public_baseurl'] == 'https://' + state['SYNAPSE_FQDN'] + '/' and
            config['serve_server_wellknown'] is True, 'Public URL/discovery configuration')
    require(config['enable_registration'] is True and config['registration_requires_token'] is True
            and bool(config['registration_shared_secret']), 'Token-protected registration configuration')
    require(config['max_upload_size'] == app_policy['max_upload_size'], 'Upload size configuration')
    require(config['turn_uris'] == app_policy['turn_uris'] and config['turn_allow_guests'] == app_policy['turn_guests']
            and config['turn_user_lifetime'] == app_policy['turn_lifetime'], 'TURN configuration')
    require(bool(config.get('turn_shared_secret')) == (app_policy['turn_mode'] != 'disabled'), 'TURN secret presence')
    if app_policy['rtc_auth']:
        require(config['matrix_rtc']['transports'] == [{'type': 'livekit', 'livekit_service_url': app_policy['rtc_auth']}], 'RTC transport configuration')
        require(all(config['experimental_features'].get(k) is True for k in ('msc3266_enabled', 'msc4143_enabled', 'msc4222_enabled'))
                and config['max_event_delay_duration'] == '24h', 'RTC delayed-event prerequisites')
    element = json.loads(Path('/opt/matrix/element-config.json').read_text())
    require(element['default_server_config']['m.homeserver'] == {
        'base_url': 'https://' + state['SYNAPSE_FQDN'], 'server_name': state['SYNAPSE_SERVER_NAME']}, 'Element homeserver configuration')
    # Check the live mounted file privately, including registration/TURN secrets.
    mounted = run(['podman', 'exec', '--user', '991:991', 'matrix-synapse', 'cat', '/data/homeserver.yaml'], 'Synapse mounted configuration')
    require(yaml.safe_load(mounted) == config, 'Synapse runtime configuration delivery')

def check_timezone():
    zone = state['APP_TZ']
    require(zone == app_policy['timezone'], 'Application timezone policy differs')
    ZoneInfo(zone)
    policy_path = Path('/var/lib/lab-hardening/policy.json')
    if policy_path.exists():
        policy = json.loads(policy_path.read_text())
        require(policy['version'] == '1.2.0' and policy['profile'] == 'lxc', 'Hardening version/profile differs')
        require(policy['timezone']['effective'] == zone, 'Final hardening/application timezone mismatch')
        require(run(['/usr/local/sbin/lab-timezone', 'check', str(policy_path)], 'Guest timezone check') == zone, 'Guest timezone mismatch')
    else:
        marker = Path('/run/matrix-install-bootstrap.json')
        require(initial and marker.is_file() and not marker.is_symlink(), 'Final hardening policy is missing')
        st = marker.stat()
        require(st.st_uid == 0 and st.st_mode & 0o777 == 0o600, 'Unsafe initial verification marker')
        plan = json.loads(marker.read_text())
        require(plan['effective'] == zone, 'Bootstrap timezone mismatch')
        actual = json.loads(run(['/usr/local/sbin/lab-timezone', 'plan', '1' if plan['preserve'] else '0',
                                plan['requested'] or ''], 'Bootstrap timezone recheck'))
        require(actual == plan, 'Bootstrap guest timezone plan changed')
    for container in ('matrix-synapse', 'matrix-element', 'matrix-postgres'):
        unit = Path('/etc/containers/systemd/' + container + '.container').read_text()
        require(re.findall(r'^Environment=TZ=(.*)$', unit, re.M) == [zone], 'Quadlet timezone delivery')
        info = json.loads(run(['podman', 'inspect', container], 'Timezone container inspection'))[0]
        require([v for v in info['Config']['Env'] if v.startswith('TZ=')] == ['TZ=' + zone], 'Running container timezone environment')
        require(run(['podman', 'exec', container, 'printenv', 'TZ'], 'Runtime timezone delivery') == zone, 'Runtime TZ differs')
    # Synapse's Python local-time mechanism is checked at fixed winter/summer
    # epochs. Element is static web content; browser display uses client time.
    # PostgreSQL SQL/log timezone is separate and is not rewritten for uniformity.
    for stamp in (1768435200, 1784073600):
        expected = datetime.fromtimestamp(stamp, ZoneInfo(zone)).strftime('%Y-%m-%dT%H:%M:%S%z')
        actual = run(['podman', 'exec', 'matrix-synapse', 'python', '-c',
            'import time,sys; print(time.strftime("%Y-%m-%dT%H:%M:%S%z",time.localtime(int(sys.argv[1]))))', str(stamp)], 'Synapse local-time behavior')
        require(actual == expected, 'Synapse timezone use differs from planned guest zone')

if os.geteuid() != 0 or sys.argv[1:] not in ([], ['--initial']):
    raise SystemExit('Usage: matrix-verify [--initial] as root inside the Matrix CT')
initial = sys.argv[1:] == ['--initial']
try:
    for path in ['/opt/matrix/.env', '/opt/matrix/install-policy.json', '/opt/matrix/firewall-policy.json']:
        p = Path(path)
        require(p.is_file() and not p.is_symlink() and p.stat().st_uid == 0 and not p.stat().st_mode & 0o022, 'Unsafe application policy/state file')
    state = state_file('/opt/matrix/.env')
    sy_port, el_port = int(state['SYNAPSE_PORT']), int(state['ELEMENT_PORT'])
    require(1024 <= sy_port <= 65535 and 1024 <= el_port <= 65535 and len({sy_port, el_port, 5432}) == 3, 'Invalid service ports')
    for key in ['INITIAL_WAIT_SECONDS', 'UPDATE_WAIT_SECONDS']:
        require(re.fullmatch(r'[1-9][0-9]{1,4}', state[key]) and 30 <= int(state[key]) <= 86400, 'Invalid readiness budget')
    wait_seconds = int(state['INITIAL_WAIT_SECONDS' if initial else 'UPDATE_WAIT_SECONDS'])
    require(state['AUTO_UPDATE'] in ('0', '1') and re.fullmatch(r'(?:[01][0-9]|2[0-3]):[0-5][0-9]', state['UPDATE_TIME']), 'Invalid image timer policy')
    app_policy = json.loads(Path('/opt/matrix/install-policy.json').read_text())
    config = yaml.safe_load(Path('/opt/matrix/synapse/homeserver.yaml').read_text())
except Exception:
    raise SystemExit('FAIL: Matrix configuration is missing or malformed; no changes made.')
restart_counts = {}
container_pids = {}
for label, check in [('UFW effective sources', check_firewall), ('Bounded readiness and initial restart policy', wait_ready), ('Services, images, mounts and ownership', check_identity), ('Application configuration and discovery settings', check_configuration), ('Application HTTP contracts', check_http), ('Database authentication and privileges', check_database), ('Listener bindings and process ownership', check_sockets), ('Guest/application timezone policy and delivery', check_timezone)]:
    try:
        check()
        print('PASS: ' + label)
    except Exception as exc:
        # RuntimeError messages above are deliberately secret-free; other
        # exceptions might embed configuration or request contents.
        detail = str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__
        errors.append(label)
        print('FAIL: ' + label + ': ' + detail)
if restart_counts:
    time.sleep(3)
    for container, before in restart_counts.items():
        try:
            after = run(['systemctl', 'show', container + '.service', '-p', 'NRestarts', '--value'], container + ' restart stability')
            require(before == after, container + ': restarted during verification')
            run(['systemctl', 'is-active', '--quiet', container + '.service'], container + ' remains active')
        except Exception:
            errors.append(container + ' stability')
            print('FAIL: ' + container + ' did not stay active with stable restart count')
print('Matrix verification: ' + ('FAIL' if errors else 'PASS'))
sys.exit(1 if errors else 0)
MATRIX_VERIFY
pct push "$CT_ID" "$tmp" /usr/local/sbin/matrix-verify --perms 0755
rm -f "$tmp"

INSTALL_STAGE="maintenance setup"
# ── Maintenance helper ────────────────────────────────────────────────────────
tmp="$(mktemp)"
cat > "$tmp" <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail
umask 077
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

APP_DIR=/opt/matrix
ENV_FILE=$APP_DIR/.env
UNIT_DIR=/etc/containers/systemd
LOCK=/run/lock/matrix-maint.lock
# Persistent state: postgresdata/, synapse/ (configuration, keys, media),
# postgres.env, postgres-init.sh and element-config.json. Updates never replace it.
# PBS/PVE owns backup and restore. Only a temporary copy of TWO control files is
# used to unwind a failed switch; no data archive, restore command or boot barrier.
# One component per operation: each atomic Quadlet is the runtime source of truth.
# A reboot between its write and the descriptive .env write can only boot the
# complete old or complete target unit. The next update reconciles .env metadata.
WORK=""
SWITCHED=0
START_ATTEMPTED=0
APP_STOPPED=0
COMPONENT=""

die() { printf '  ERROR: %s\n' "$*" >&2; exit 1; }
image_id() {
  local value
  value=$(podman image inspect --format '{{.Id}}' "$1") || return 1
  value=${value#sha256:}
  [[ $value =~ ^[a-f0-9]{64}$ ]] || return 1
  printf 'sha256:%s\n' "$value"
}
read_state() {
  local line key value
  declare -A seen=()
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
    [[ $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || die "Malformed state line in $ENV_FILE."
    key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
    [[ ! ${seen[$key]+yes} ]] || die "Duplicate state key: $key"
    seen[$key]=1
    case $key in
      SYNAPSE_IMAGE_REPO|SYNAPSE_TAG|SYNAPSE_IMAGE|SYNAPSE_IMAGE_ID|ELEMENT_IMAGE_REPO|ELEMENT_TAG|ELEMENT_IMAGE|ELEMENT_IMAGE_ID|POSTGRES_IMAGE_REPO|POSTGRES_TAG|POSTGRES_IMAGE|POSTGRES_IMAGE_ID|SYNAPSE_PORT|ELEMENT_PORT|UPDATE_WAIT_SECONDS|INITIAL_WAIT_SECONDS|AUTO_UPDATE|PODMAN_FUSE_OVERLAY)
        [[ $value =~ ^[A-Za-z0-9_./:+-]+$ ]] || die "Invalid value for $key. Use unquoted KEY=value."
        printf -v "$key" '%s' "$value"
        ;;
      *) ;;  # preserve other configuration keys without executing or interpreting them
    esac
  done < "$ENV_FILE"
  for key in SYNAPSE_PORT ELEMENT_PORT UPDATE_WAIT_SECONDS INITIAL_WAIT_SECONDS AUTO_UPDATE PODMAN_FUSE_OVERLAY; do
    [[ ${seen[$key]+yes} ]] || die "Missing state key: $key"
  done
  [[ $SYNAPSE_PORT =~ ^[1-9][0-9]{3,4}$ && $ELEMENT_PORT =~ ^[1-9][0-9]{3,4}$ ]] || die "Invalid HTTP ports."
  (( SYNAPSE_PORT >= 1024 && ELEMENT_PORT >= 1024 && SYNAPSE_PORT <= 65535 && ELEMENT_PORT <= 65535 && SYNAPSE_PORT != ELEMENT_PORT && SYNAPSE_PORT != 5432 && ELEMENT_PORT != 5432 )) || die "Invalid HTTP ports."
  for key in UPDATE_WAIT_SECONDS INITIAL_WAIT_SECONDS; do
    [[ ${!key} =~ ^[1-9][0-9]{1,4}$ ]] && (( ${!key} >= 30 && ${!key} <= 86400 )) || die "Invalid verification wait."
  done
  [[ $AUTO_UPDATE =~ ^[01]$ && $PODMAN_FUSE_OVERLAY =~ ^[01]$ ]] || die "Invalid policy flag."
}
unit_value() {
  local prefix=$1 file=$2
  awk -v p="$prefix" 'index($0,p)==1 {value=substr($0,length(p)+1); n++} END {if(n!=1) exit 1; print value}' "$file"
}
valid_tag() {
  case $1 in
    SYNAPSE|ELEMENT) [[ $2 =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ;;
    POSTGRES) [[ $2 =~ ^18\.[0-9]+(-[a-z0-9.]+)?$ ]] ;;
    *) return 1 ;;
  esac
}
write_env() {
  local component=$1 tag=$2 reference=$3 id=$4 temp
  temp=$(mktemp "${ENV_FILE}.XXXXXX") || return 1
  if ! awk -v c="$component" -v t="$tag" -v r="$reference" -v id="$id" '
    index($0,c "_TAG=")==1 {print c "_TAG=" t; next}
    index($0,c "_IMAGE=")==1 {print c "_IMAGE=" r; next}
    index($0,c "_IMAGE_ID=")==1 {print c "_IMAGE_ID=" id; next}
    {print}
  ' "$ENV_FILE" > "$temp" || ! chmod 0600 "$temp" || ! mv -fT "$temp" "$ENV_FILE"; then
    rm -f -- "$temp"
    return 1
  fi
}
write_unit() {
  local tag=$1 reference=$2 id=$3 old_tag=$4 old_reference=$5 old_id=$6 temp
  temp=$(mktemp "${UNIT}.XXXXXX") || return 1
  if ! sed -e "s|^# MatrixTag=.*|# MatrixTag=$tag|" \
      -e "s|^# MatrixImage=.*|# MatrixImage=$reference|" \
      -e "s|^Image=.*|Image=$id|" \
      -e '/^# PreviousTag=/d; /^# PreviousImage=/d; /^# PreviousImageID=/d' "$UNIT" > "$temp"; then
    rm -f -- "$temp"; return 1
  fi
  if [[ $COMPONENT == ELEMENT ]]; then
    if ! printf '# PreviousTag=%s\n# PreviousImage=%s\n# PreviousImageID=%s\n' "$old_tag" "$old_reference" "$old_id" >> "$temp"; then
      rm -f -- "$temp"; return 1
    fi
  fi
  if ! chmod 0644 "$temp" || ! mv -fT "$temp" "$UNIT"; then
    rm -f -- "$temp"; return 1
  fi
}
wait_for_component() {
  local name=$1 timeout=$2 start=$SECONDS restarts state code port initial_restarts
  initial_restarts=$(systemctl show "matrix-$name.service" -p NRestarts --value) || return 1
  while (( SECONDS - start < timeout )); do
    state=$(systemctl show "matrix-$name.service" -p ActiveState --value) || return 1
    restarts=$(systemctl show "matrix-$name.service" -p NRestarts --value) || return 1
    [[ $state != failed && $state != inactive && ${restarts:-0} == "${initial_restarts:-0}" ]] || return 1
    if [[ $name == postgres ]]; then
      if [[ $state == active ]] && podman exec matrix-postgres pg_isready -h 127.0.0.1 -U synapse -d synapse >/dev/null 2>&1; then return 0; fi
    else
      port=$ELEMENT_PORT; [[ $name != synapse ]] || port=$SYNAPSE_PORT
      local path=/; [[ $name != synapse ]] || path=/health
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$port$path") || code=000
      if [[ $state == active && $code == 200 ]]; then return 0; fi
    fi
    sleep 2
  done
  return 1
}
copy_control_file() {
  local source=$1 destination=$2 temp
  temp=$(mktemp "${destination}.XXXXXX") || return 1
  if ! cp --preserve=mode,ownership "$source" "$temp" || ! mv -fT "$temp" "$destination"; then
    rm -f -- "$temp"
    return 1
  fi
}
finish() {
  local rc=$? restored=1
  trap - EXIT ERR INT TERM HUP
  set +e
  if (( rc != 0 && SWITCHED )); then
    if [[ $COMPONENT == ELEMENT ]] || (( START_ATTEMPTED == 0 )); then
      # Element is static; before a stateful target start, only control files changed.
      copy_control_file "$WORK/old.container" "$UNIT" || restored=0
      copy_control_file "$WORK/old.env" "$ENV_FILE" || restored=0
      systemctl daemon-reload || restored=0
      if (( restored )); then
        if [[ $COMPONENT == ELEMENT ]]; then
          systemctl restart "$SERVICE" && wait_for_component element 120 || restored=0
        elif (( APP_STOPPED )); then
          systemctl start matrix-synapse.service && wait_for_component synapse "$UPDATE_WAIT_SECONDS" || restored=0
        fi
      fi
      if (( restored )); then
        printf '  Previous %s configuration/image restored; persistent data was untouched.\n' "$COMPONENT" >&2
      else
        printf '  CRITICAL: Could not confirm recovery. Inspect %s and %s.\n' "$UNIT" "$WORK" >&2
      fi
    else
      printf '  Target %s image is retained. No automatic database/image downgrade.\n' "$COMPONENT" >&2
      printf '  Synapse may still be migrating. Inspect journalctl -u matrix-synapse.service -u matrix-postgres.service.\n' >&2
      printf '  Recovery is through the matching PBS/PVE checkpoint if required.\n' >&2
    fi
  elif (( rc != 0 && APP_STOPPED )); then
    systemctl start matrix-synapse.service || printf '  Could not resume Synapse; inspect its journal.\n' >&2
  fi
  if [[ -n $WORK ]]; then
    if (( restored )); then rm -rf -- "$WORK"; else printf '  Temporary control files retained: %s\n' "$WORK" >&2; fi
  fi
  exit "$rc"
}
trap finish EXIT
trap 'printf "  Maintenance failed near line %s.\n" "$LINENO" >&2' ERR
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

update_component() {
  local component=$1 requested=${2:-} repo_key repo old_tag old_image old_id actual target new_id key configured
  local old_variant new_variant old_version new_version target_image use_previous=0 previous_id=""
  COMPONENT=$component; UNIT="$UNIT_DIR/matrix-${component,,}.container"
  SERVICE="matrix-${component,,}.service"
  SWITCHED=0; START_ATTEMPTED=0; APP_STOPPED=0
  repo_key=${component}_IMAGE_REPO; repo=${!repo_key}
  [[ $repo =~ ^[a-z0-9][a-z0-9._/-]*[a-z0-9]$ ]] || die "Invalid $repo_key."
  for key in "${component}_TAG" "${component}_IMAGE" "${component}_IMAGE_ID"; do
    unit_value "$key=" "$ENV_FILE" >/dev/null || die "Missing or duplicate state key: $key"
  done
  old_tag=$(unit_value '# MatrixTag=' "$UNIT") || die "Missing unit version metadata."
  old_image=$(unit_value '# MatrixImage=' "$UNIT") || die "Missing unit image metadata."
  old_id=$(unit_value 'Image=' "$UNIT") || die "Missing unit image ID."
  valid_tag "$component" "$old_tag" || die "Invalid configured tag."
  [[ $old_image == "$repo:$old_tag" && $old_id =~ ^sha256:[a-f0-9]{64}$ ]] || die "Unit metadata is inconsistent."
  [[ $(unit_value 'Pull=' "$UNIT") == never ]] || die "Unit must use Pull=never."
  target=${requested:-$old_tag}
  if [[ $component == ELEMENT ]]; then
    if [[ $target == previous ]]; then
      use_previous=1
      target=$(unit_value '# PreviousTag=' "$UNIT") || die "No previous Element version recorded yet."
      previous_id=$(unit_value '# PreviousImageID=' "$UNIT") || die "Previous Element image ID is missing."
      [[ $previous_id =~ ^sha256:[a-f0-9]{64}$ ]] || die "Invalid previous Element ID."
      [[ $(unit_value '# PreviousImage=' "$UNIT") == "$repo:$target" ]] || die "Previous Element metadata is inconsistent."
    fi
  fi
  valid_tag "$component" "$target" || die "Use a pinned release tag; PostgreSQL must remain 18.MINOR[-variant]."
  if [[ $component == POSTGRES ]]; then
    old_variant=""; new_variant=""
    [[ $old_tag != *-* ]] || old_variant=${old_tag#*-}
    [[ $target != *-* ]] || new_variant=${target#*-}
    [[ $old_variant == "$new_variant" ]] || die "PostgreSQL variant changes require a separate migration."
  fi
  if [[ $component != ELEMENT ]]; then
    old_version=${old_tag%%-*}; new_version=${target%%-*}
    [[ $(printf '%s\n%s\n' "$old_version" "$new_version" | sort -V | head -n 1) == "$old_version" ]] \
      || die "Stateful downgrades require version-specific review and PBS/PVE recovery."
  fi
  /usr/local/sbin/matrix-ufw-check || die "UFW policy verification failed; inspect the preserved configuration."
  systemctl is-active --quiet "$SERVICE" || die "$SERVICE must be active before updating."
  actual=$(podman inspect --format '{{.Image}}' "matrix-${component,,}") || die "Cannot inspect running image."
  actual=$(image_id "$actual") || die "Running image is unavailable."
  [[ $actual == "$old_id" ]] || die "Running and configured IDs differ; inspect the selected service."
  wait_for_component "${component,,}" 30 || die "$SERVICE is unhealthy before update."
  if [[ $component == POSTGRES ]]; then
    wait_for_component synapse 30 || die "Synapse must be healthy before a database update."
  fi
  for key in TAG IMAGE IMAGE_ID; do
    configured="${component}_$key"
    case $key in TAG) actual=$old_tag ;; IMAGE) actual=$old_image ;; IMAGE_ID) actual=$old_id ;; esac
    if [[ ${!configured} != "$actual" ]]; then
      printf '  Reconciling %s metadata from its authoritative Quadlet after an interrupted write.\n' "$component"
      write_env "$component" "$old_tag" "$old_image" "$old_id"
      break
    fi
  done
  # Shared implementation; already holding matrix-maint.lock, so do not recurse
  # through the maintenance CLI. This is also the installed-policy gate.
  /usr/local/sbin/matrix-verify
  if (( YES == 0 )); then
    [[ -t 8 ]] || die "Interactive terminal or --yes is required."
    printf '  Take/verify a PVE checkpoint or PBS backup on the host before updating.\n'
    (( PODMAN_FUSE_OVERLAY == 0 )) || printf '  FUSE: use stop-mode PBS; do not freeze a running FUSE CT.\n'
    [[ $component != SYNAPSE ]] || printf '  Read Synapse release notes; an image downgrade may be unsafe after migration.\n'
    [[ $component != ELEMENT ]] || printf '  Element-only change; database/media stay live. Check client compatibility when reverting versions.\n'
    read -r -p "  Update $component $old_tag -> $target? [y/N]: " answer <&8 || return 0
    [[ $answer =~ ^([Yy]|[Yy][Ee][Ss])$ ]] || return 0
  else
    printf '  %s update: external PBS/PVE recovery is the operator responsibility; no backup is created or verified.\n' "$component"
  fi
  # Pull can move a tag. Runtime IDs are immutable, so a pull failure cannot
  # change the current unit or what the next restart uses.
  target_image="$repo:$target"
  if (( use_previous )); then
    new_id=$(image_id "$previous_id") || die "Previous Element image was removed locally; use a reviewed pinned tag instead."
    [[ $new_id == "$previous_id" ]] || die "Previous Element image ID mismatch."
  else
    podman pull "$target_image"
    new_id=$(image_id "$target_image") || die "Target image ID unavailable."
  fi
  if [[ $new_id == "$old_id" && $target == "$old_tag" ]]; then
    /usr/local/sbin/matrix-verify
    printf '  %s image unchanged; no restart.\n' "$component"
    return 0
  fi
  if [[ $component == SYNAPSE ]]; then
    podman run --rm --pull=never --network none --user 991:991 \
      -v "$APP_DIR/synapse:/data:ro" --entrypoint python "$new_id" \
      -m synapse.config -c /data/homeserver.yaml
  elif [[ $component == POSTGRES ]]; then
    [[ $(cat "$APP_DIR/postgresdata/18/docker/PG_VERSION") == 18 ]] || die "Unexpected on-disk PostgreSQL major."
    local uid gid current_uid current_gid actual_owner actual_uid actual_gid actual_mode
    uid=$(podman run --rm --pull=never --network none --entrypoint sh "$new_id" -c 'id -u postgres')
    gid=$(podman run --rm --pull=never --network none --entrypoint sh "$new_id" -c 'id -g postgres')
    current_uid=$(podman exec matrix-postgres id -u postgres)
    current_gid=$(podman exec matrix-postgres id -g postgres)
    # Keep image account changes as a separate migration guard. PGDATA itself
    # can have group root: the selected image changes only its owner and sets
    # mode 0700, so its directory group has no access and need not match postgres.
    [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ && $uid != 0 && $uid == "$current_uid" && $gid == "$current_gid" ]] \
      || die "Target PostgreSQL account $uid:$gid differs from running account $current_uid:$current_gid or is invalid. Separate migration review required."
    actual_owner=$(stat -c '%u:%g:%a' "$APP_DIR/postgresdata/18/docker")
    IFS=: read -r actual_uid actual_gid actual_mode <<< "$actual_owner"
    [[ $actual_uid == "$uid" && $actual_mode == 700 ]] \
      || die "PostgreSQL cluster has uid=$actual_uid gid=$actual_gid mode=$actual_mode; expected uid=$uid and mode=700. No ownership or permission changes are attempted."
    podman run --rm --pull=never --network none --entrypoint postgres "$new_id" --version | grep -Eq '^postgres \(PostgreSQL\) 18\.' \
      || die "Image does not contain PostgreSQL 18."
  else
    python3 -m json.tool "$APP_DIR/element-config.json" >/dev/null
    podman run --rm --pull=never --network none --entrypoint sh "$new_id" -c 'test -s /app/index.html' \
      || die "Target Element image lacks /app/index.html."
  fi
  if [[ $component == ELEMENT && $new_id != "$old_id" ]]; then
    podman tag "$old_id" localhost/matrix-element:previous
  fi
  WORK=$(mktemp -d /run/matrix-update.XXXXXX)
  cp --preserve=mode,ownership "$UNIT" "$WORK/old.container"
  cp --preserve=mode,ownership "$ENV_FILE" "$WORK/old.env"
  # Set before the first write so every ordinary failure restores both files.
  SWITCHED=1
  write_unit "$target" "$target_image" "$new_id" "$old_tag" "$old_image" "$old_id"
  write_env "$component" "$target" "$target_image" "$new_id"
  /usr/lib/systemd/system-generators/podman-system-generator --dryrun >/dev/null
  systemctl daemon-reload
  [[ $(systemctl show "$SERVICE" -p LoadState --value) == loaded ]] || die "Quadlet did not generate $SERVICE."
  if [[ $new_id != "$old_id" ]]; then
    if [[ $component == POSTGRES ]]; then
      APP_STOPPED=1
      systemctl stop matrix-synapse.service
    fi
    # Once a persistent target MIGHT start, never restart the old image automatically.
    START_ATTEMPTED=1
    systemctl restart "$SERVICE"
    wait_for_component "${component,,}" "$([[ $component == SYNAPSE ]] && printf '%s' "$UPDATE_WAIT_SECONDS" || printf 120)" \
      || die "$SERVICE failed readiness or restarted. Inspect logs; migration timeout does not kill Synapse."
    if [[ $component == POSTGRES ]]; then
      systemctl start matrix-synapse.service
      wait_for_component synapse "$UPDATE_WAIT_SECONDS" || die "Synapse did not recover after the database update."
    fi
  fi
  actual=$(podman inspect --format '{{.Image}}' "matrix-${component,,}")
  [[ $(image_id "$actual") == "$new_id" ]] || die "Running image does not match target."
  if [[ $component == ELEMENT ]]; then
    curl -fsS --max-time 10 "http://127.0.0.1:$ELEMENT_PORT/config.json" | python3 -m json.tool >/dev/null
  fi
  /usr/local/sbin/matrix-verify
  SWITCHED=0; START_ATTEMPTED=0; APP_STOPPED=0
  rm -rf -- "$WORK"; WORK=""
  # Keep captured old images for reviewed recovery. Their presence is not a DB
  # rollback and does not make a stateful downgrade safe. No automatic pruning.
  read_state
  printf '  Updated %s to %s (%s).\n' "$component" "$target" "$new_id"
}

[[ $EUID == 0 ]] || die "Run as root inside the Matrix CT."
for command in podman systemctl curl python3 awk sed sort head cat stat grep mktemp cp chmod mv rm flock; do
  command -v "$command" >/dev/null || die "Missing command: $command"
done
[[ -f $ENV_FILE ]] || die "Missing $ENV_FILE; this helper belongs to the rewritten creator."
for path in "$ENV_FILE" "$UNIT_DIR" "$UNIT_DIR"/matrix-{synapse,element,postgres}.container; do
  [[ ! -L $path ]] || die "Refusing a symlinked maintenance control path."
  [[ $(stat -c %u "$path") == 0 ]] || die "Maintenance control paths must be root-owned."
  mode=$(stat -c %a "$path")
  (( (8#$mode & 8#022) == 0 )) || die "Maintenance control paths must not be writable by group/other."
done
exec 9>"$LOCK"
flock -n 9 || die "Another maintenance operation is running."
YES=0
ARGS=()
for arg in "$@"; do
  case $arg in --yes|-y) YES=1 ;; *) ARGS+=("$arg") ;; esac
done
set -- "${ARGS[@]}"
cmd=${1:---help}
(( $# == 0 )) || shift
read_state
case $cmd in
  update|update-element|update-postgres)
    (( $# <= 1 )) || die "$cmd accepts one tag and optional --yes."
    if (( YES == 0 )); then exec 8</dev/tty || die "No terminal; use --yes for an intentional unattended update."; fi
    case $cmd in update) component=SYNAPSE ;; update-element) component=ELEMENT ;; update-postgres) component=POSTGRES ;; esac
    update_component "$component" "${1:-}"
    ;;
  auto-update)
    (( $# == 0 && YES == 0 )) || die "auto-update takes no arguments."
    [[ $AUTO_UPDATE == 1 ]] || { echo '  AUTO_UPDATE=0; skipping.'; exit 0; }
    YES=1
    # No all-stack transaction: earlier successful component changes remain if
    # a later pull/update fails. Each component is independently coherent.
    update_component POSTGRES
    update_component SYNAPSE
    update_component ELEMENT
    ;;
  check)
    (( YES == 0 )) || die "check accepts only optional --initial."
    (( $# == 0 )) || { (( $# == 1 )) && [[ $1 == --initial ]]; } || die "check accepts only optional --initial."
    /usr/local/sbin/matrix-verify "$@"
    ;;
  version)
    (( $# == 0 && YES == 0 )) || die "version takes no arguments."
    for component in SYNAPSE ELEMENT POSTGRES; do
      unit="$UNIT_DIR/matrix-${component,,}.container"
      printf '%s: %s\n  configured: %s\n  running:    %s\n' "$component" \
        "$(unit_value '# MatrixImage=' "$unit")" "$(unit_value 'Image=' "$unit")" \
        "$(podman inspect --format '{{.Image}}' "matrix-${component,,}" 2>/dev/null || printf unavailable)"
    done
    ;;
  --help|-h)
    (( $# == 0 && YES == 0 )) || die "--help takes no arguments."
    cat <<'HELP'
Usage (root inside the CT):
  /usr/local/bin/matrix-maint.sh check [--initial]
  /usr/local/bin/matrix-maint.sh update [Synapse-vX.Y.Z] [--yes]
  /usr/local/bin/matrix-maint.sh update-element [Element-vX.Y.Z|previous] [--yes]
  /usr/local/bin/matrix-maint.sh update-postgres [18.MINOR-same-variant] [--yes]
  /usr/local/bin/matrix-maint.sh auto-update
  /usr/local/bin/matrix-maint.sh version

PBS/PVE owns backups and recovery. No in-CT backup/restore/rollback commands.
check is observational; --initial requires zero restarts and the initial budget.
With FUSE use stop-mode PBS; a live CT freeze can deadlock FUSE mounts.
Manual updates remind you of the checkpoint; --yes/timers do not verify one.
A missing tag re-pulls that component's current tag. Auto-update re-pulls all
three current tags in sequence and restarts only components whose ID changed.
Element can move to an older pinned release without restoring the database.
A failed Element switch automatically restores its actual pre-update image.
update-element previous selects the captured previous ID without re-pulling a tag.
Synapse/PostgreSQL are never automatically downgraded after a target start.
Read Synapse release notes before changing versions; test real client/call
compatibility after Element changes. HTTP readiness is not an end-to-end test.
HELP
    ;;
  *) die "Unknown maintenance command. Use --help." ;;
esac
MAINT
pct push "$CT_ID" "$tmp" /usr/local/bin/matrix-maint.sh --perms 0755
rm -f "$tmp"


INSTALL_STAGE="Quadlet compatibility"
# ── Start via Quadlet ─────────────────────────────────────────────────────────
# daemon-reload triggers the Quadlet generator which produces matrix-synapse.service,
# matrix-element.service and matrix-postgres.service as transient systemd units.
# WantedBy=multi-user.target handles boot restarts. Transient units cannot be
# systemctl-enabled; daemon-reload is sufficient. Starting matrix-synapse.service
# pulls in PostgreSQL via Requires= and waits for its health check (Notify=healthy);
# Element is started alongside and is independent of both.
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  /usr/lib/systemd/system-generators/podman-system-generator --dryrun >/dev/null
  systemctl daemon-reload
  for service in matrix-postgres matrix-synapse matrix-element; do
    test "$(systemctl show "$service.service" -p LoadState --value)" = loaded
  done
'

# Fail before persistent app startup if filtering was disabled during provisioning.
pct exec "$CT_ID" -- /usr/local/sbin/matrix-ufw-check

# First persistent service start: disarm BEFORE the command, including a failed start.
INSTALL_STAGE="application startup"
CLEANUP_ON_FAIL=0
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  systemctl start '${SYNAPSE_QUADLET_SERVICE}' '${ELEMENT_QUADLET_SERVICE}'
"

INSTALL_STAGE="early application verification"
sleep 30
pct exec "$CT_ID" -- /usr/local/bin/matrix-maint.sh check --initial
unset DB_PASSWORD PG_ADMIN_PASSWORD TURN_SHARED_SECRET

INSTALL_STAGE="image timer definitions"
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
TimeoutStartSec=infinity
TimeoutStopSec=180
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
pct exec "$CT_ID" -- systemctl disable --now matrix-update.timer
echo '  Image timer installed; activation waits for final verification.'

# ── Extra packages ────────────────────────────────────────────────────────────
if [[ "${#EXTRA_PACKAGES[@]}" -gt 0 ]]; then
  pct exec "$CT_ID" -- bash -lc "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
    apt-get install -y ${EXTRA_PACKAGES[*]}
  "
fi

INSTALL_STAGE="package cleanup and MOTD"
# ── Cleanup packages ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  apt-get -y clean
'

INSTALL_STAGE="package cleanup and MOTD"
# ── MOTD (dynamic drop-ins) ───────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  : > /etc/motd
  install -d /etc/update-motd.d
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
  rm -f /etc/update-motd.d/*
'
tmp="$(mktemp)"
cat > "$tmp" <<'MOTDHEADER'
#!/bin/sh
printf '\n  Matrix Synapse + Element (Podman/Quadlet)\n'
printf '  ────────────────────────────────────\n'
MOTDHEADER
pct push "$CT_ID" "$tmp" /etc/update-motd.d/00-header --perms 0755
# BEGIN COMMON: MOTD SYSINFO
cat > "$tmp" <<'MOTDSYSINFO'
#!/bin/sh
ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
printf '  Hostname:  %s\n' "$(hostname)"
printf '  IP:        %s\n' "${ip:-n/a}"
printf '  Uptime:    %s\n' "$(uptime -p 2>/dev/null || uptime)"
printf '  Disk:      %s\n' "$(df -h / | awk 'NR==2{printf "%s/%s (%s used)", $3, $2, $5}')"
MOTDSYSINFO
# END COMMON: MOTD SYSINFO
pct push "$CT_ID" "$tmp" /etc/update-motd.d/10-sysinfo --perms 0755
cat > "$tmp" <<'MOTDAPP'
#!/bin/sh
printf '\n'
for service in matrix-postgres matrix-synapse matrix-element; do
  svc=$(systemctl is-active "$service.service" 2>/dev/null); svc=${svc:-unknown}
  printf '  %-20s %s\n' "$service" "$svc"
done
if [ -r /opt/matrix/.env ]; then
  server=$(sed -n 's/^SYNAPSE_FQDN=//p' /opt/matrix/.env)
  chat=$(sed -n 's/^ELEMENT_FQDN=//p' /opt/matrix/.env)
  printf '  Synapse: https://%s/ | Element: https://%s/\n' "$server" "$chat"
  auto=$(sed -n 's/^AUTO_UPDATE=//p' /opt/matrix/.env)
  schedule=$(sed -n 's/^UPDATE_TIME=//p' /opt/matrix/.env)
  zone=$(sed -n 's/^APP_TZ=//p' /opt/matrix/.env)
  printf '  Image updates: AUTO_UPDATE=%s; daily %s (%s)\n' "$auto" "$schedule" "$zone"
  fuse=$(sed -n 's/^PODMAN_FUSE_OVERLAY=//p' /opt/matrix/.env)
  if [ "$fuse" = 1 ]; then printf '  FUSE: stop-mode PBS backups; freezing a live CT can deadlock.\n'; fi
fi
printf '  Config: /opt/matrix/synapse/homeserver.yaml, /opt/matrix/.env\n'
printf '  Maintenance: /usr/local/bin/matrix-maint.sh --help\n'
printf '  Logs: journalctl -u matrix-synapse.service -f\n'
printf '  Ingress: UFW policy in /opt/matrix/firewall-policy.json.\n'
printf '  Check: /usr/local/bin/matrix-maint.sh check\n'
printf '  Versions: /usr/local/bin/matrix-maint.sh version\n'
printf '  Hardening: /usr/local/sbin/lab-hardening-check\n'
printf '  Firewall: ufw status verbose; manage locally through pct enter/exec.\n'
printf '  Before updates: host PBS/PVE checkpoint. Synapse image reversal may be unsafe.\n'
printf '  Element updates are independent; HTTP readiness does not verify calls.\n'
MOTDAPP
pct push "$CT_ID" "$tmp" /etc/update-motd.d/30-app --perms 0755
# BEGIN COMMON: MOTD FOOTER
cat > "$tmp" <<'MOTDFOOTER'
#!/bin/sh
printf '  ────────────────────────────────────\n\n'
MOTDFOOTER
# END COMMON: MOTD FOOTER
pct push "$CT_ID" "$tmp" /etc/update-motd.d/99-footer --perms 0755
rm -f "$tmp"

# BEGIN COMMON: TERMINAL WRAPPER
# COMMON TERMINAL WRAPPER
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'
# END COMMON: TERMINAL WRAPPER

# BEGIN COMMON: TIMEZONE PLAN RECHECK
# COMMON TIMEZONE PLAN RECHECK
TIMEZONE_PLAN_LATE=$(pct exec "$CT_ID" -- /usr/local/sbin/lab-timezone plan "$PRESERVE_EXISTING_TIMEZONE" "$SERVER_TIMEZONE")
[[ $TIMEZONE_PLAN == "$TIMEZONE_PLAN_LATE" ]] || {
  echo 'ERROR: Guest timezone changed since early planning; CT preserved.' >&2
  false
}
unset TIMEZONE_PLAN_LATE
# END COMMON: TIMEZONE PLAN RECHECK

pct exec "$CT_ID" -- rm /run/matrix-install-bootstrap.json
# BEGIN COMMON: HARDENING CALLER
# COMMON HARDENING CALLER
INSTALL_STAGE="shared hardening"
CLEANUP_ON_FAIL=0
[[ $EUID == 0 && -d /etc/pve ]] || {
  echo 'ERROR: Shared hardening caller must be the verified Proxmox host.' >&2
  false
}
command -v pveversion >/dev/null
command -v pct >/dev/null
pveversion >/dev/null
[[ $CT_ID =~ ^[1-9][0-9]+$ ]] || {
  echo 'ERROR: Invalid selected CT_ID.' >&2
  false
}
pct status "$CT_ID" | grep -qx 'status: running'
pct config "$CT_ID" | grep -qx 'unprivileged: 1'
# A verified host login marker is not a guest SSH session.
unset SSH_CONNECTION
UFW_RULES_BEFORE=$(pct exec "$CT_ID" -- bash -s <<'UFW_SNAPSHOT_BEFORE'
set -euo pipefail
sha256sum /etc/ufw/{before,after,user}{,6}.rules
iptables -w 5 -S
ip6tables -w 5 -S
UFW_SNAPSHOT_BEFORE
)
# END COMMON: HARDENING CALLER
# BEGIN CANONICAL HARDENING: v1.2.0
#!/usr/bin/env bash
# ── Shared Debian 13 LXC hardening block ───────────────────────────────────────
# Version: 1.2.0 (2026-09-15; user-authorized LXC timezone adaptation)
# Base v1.1.2 SHA-256: ae2fa917d7dfe007c5f3700ea9d8c6686867a892d4323af2eb78c847092c3774
# Timezone policy source: debian-hardening.sh v1.0.3; native access code excluded.
# Guest-only /etc/localtime handling replaces the native timedated dependency.
# Timezone backups are observational; later failures have no automatic undo.
# Paste this whole file AFTER the creator's MOTD/cleanup steps and BEFORE its
# final verification/summary. Later MOTD code must not delete 25-lab-hardening.
# Replace its old unattended-upgrades and sysctl sections with this block.
# The initial OS upgrade and application/UFW setup must already have run.
# Keep application-specific ports, source rules, users, health checks and units.
# Creators retain set -Eeo pipefail and their ERR trap; do not invoke this block
# as the condition of an if/! command. Late failures must preserve the CT.
#
# On PVE: an existing running CT_ID is mandatory; all changes run via pct exec.
# Direct: root inside an existing Debian 13 LXC. Other environments are refused.
# Scope: Proxmox service LXCs without routing, including Podman Network=host.
# Routers, VPN gateways and containers using bridge forwarding need another policy.
#
# Features: dual-stack sysctl policy and UFW checks; scoped service removal;
# Debian updates without auto-reboot; conservative dependency cleanup;
# persistent bounded journals; report-only needrestart; APT readiness repair;
# hourly/boot checks, local status reporting, configuration backups.
# No remote downloads of scripts; no changes to app images or Proxmox config.
# Reports are local (journal, status.json, MOTD); no email/webhook is configured.
# Re-running saves a new config backup; package removals have no automatic undo.
# UFW logging and all allow/deny rules retain the installer's existing policy.
#
# Managed paths:
#   /etc/localtime; existing /etc/timezone (set mode only)
#   /usr/local/sbin/lab-timezone (plan/check read-only; apply internal)
#   /etc/sysctl.d/99-hardening.conf
#   /etc/apt/apt.conf.d/99-lab-hardening
#   /etc/needrestart/conf.d/99-lab-hardening.conf
#   /etc/systemd/journald.conf.d/99-lab-hardening.conf
#   /etc/systemd/system/apt-daily{,-upgrade}.service.d/90-lab-readiness.conf (LXC)
#   /etc/systemd/system/lab-hardening-check.{service,timer}
#   /usr/local/sbin/lab-{apt-wait-online,hardening-check,postfix-check}
#   /etc/update-motd.d/25-lab-hardening
#   /etc/default/ufw (IPT_SYSCTL only); SSH service/socket masks (when SSH removed)
#   /etc/systemd/system/postfix*.{service,socket,path} masks (when Postfix removed)
#   /var/lib/lab-hardening/{policy.json,status.json,last-index-refresh,check.lock}
#   /var/backups/lab-hardening/<run>/ (configuration copies and dry-run log)
# References: Debian trixie apt.conf(5), systemd-sysctl(8), ifquery(8),
# journald.conf(5), needrestart(1); kernel.org networking/ip-sysctl.html.
#
# Settings may instead be assigned in the creator's top config section.
SERVER_TIMEZONE="${SERVER_TIMEZONE-Europe/Berlin}"
PRESERVE_EXISTING_TIMEZONE="${PRESERVE_EXISTING_TIMEZONE-0}" # 0=set; 1=keep guest zone
HARDENING_PROFILE="${HARDENING_PROFILE:-lxc}"              # lxc; auto remains a compatible alias
HARDENING_RP_FILTER="${HARDENING_RP_FILTER:-1}"            # 1=strict; 2=loose for asymmetric paths
HARDENING_KEEP_SSH="${HARDENING_KEEP_SSH:-0}"              # 0=remove; 1=preserve
HARDENING_REMOVE_POSTFIX="${HARDENING_REMOVE_POSTFIX:-1}"   # 0 for intentional mail service
HARDENING_JOURNAL_DAYS="${HARDENING_JOURNAL_DAYS:-14}"
HARDENING_JOURNAL_MAX_MB="${HARDENING_JOURNAL_MAX_MB:-256}"
HARDENING_JOURNAL_RUNTIME_MB="${HARDENING_JOURNAL_RUNTIME_MB:-64}"
HARDENING_UPDATE_MAX_AGE_HOURS="${HARDENING_UPDATE_MAX_AGE_HOURS:-72}"
# Optional space-separated external listening ports; leave empty to inventory
# only. Loopback listeners are excluded. For DHCP include UDP 68 (and 546 if used).
# Examples: Matrix TCP="8008 8080" UDP="68"; NPM TCP="80 443 81" UDP="68".
# If preserving SSH, include its actual listening port in the TCP list.
HARDENING_TCP_PORTS="${HARDENING_TCP_PORTS:-}"
HARDENING_UDP_PORTS="${HARDENING_UDP_PORTS:-}"

# ── Dispatch into the guest ───────────────────────────────────────────────────
# The subshell isolates the block's options/variables from its parent creator.
# shellcheck disable=SC2034
CLEANUP_ON_FAIL=0
(
set -Eeuo pipefail
export LC_ALL=C
[[ $EUID == 0 ]] || { echo 'ERROR: Run as root.' >&2; exit 1; }
hardening_exec=()
if command -v pveversion >/dev/null 2>&1; then
  [[ ${CT_ID:-} =~ ^[1-9][0-9]+$ ]] || {
    echo 'ERROR: On Proxmox, supply an existing CT_ID; the host is never hardened.' >&2; exit 1;
  }
  pct status "$CT_ID" | grep -qx 'status: running'
  hardening_exec=(pct exec "$CT_ID" --)
fi
"${hardening_exec[@]}" bash -s -- \
  "$HARDENING_PROFILE" "$HARDENING_RP_FILTER" "$HARDENING_KEEP_SSH" \
  "$HARDENING_REMOVE_POSTFIX" "$HARDENING_JOURNAL_DAYS" \
  "$HARDENING_JOURNAL_MAX_MB" "$HARDENING_JOURNAL_RUNTIME_MB" \
  "$HARDENING_UPDATE_MAX_AGE_HOURS" "$HARDENING_TCP_PORTS" \
  "$HARDENING_UDP_PORTS" "$PRESERVE_EXISTING_TIMEZONE" "$SERVER_TIMEZONE" <<'LAB_HARDENING_GUEST'
set -Eeuo pipefail
umask 022
export LC_ALL=C DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
PROFILE=$1 RP_FILTER=$2 KEEP_SSH=$3 REMOVE_POSTFIX=$4
JOURNAL_DAYS=$5 JOURNAL_MAX_MB=$6 JOURNAL_RUNTIME_MB=$7 UPDATE_MAX_AGE=$8
TCP_PORTS=$9 UDP_PORTS=${10}
PRESERVE_TIMEZONE=${11} REQUESTED_TIMEZONE=${12}
[[ $EUID == 0 && -d /run/systemd/system ]] || {
  echo 'ERROR: A running systemd guest and root access are required.' >&2; exit 1;
}
command -v pveversion >/dev/null 2>&1 && {
  echo 'ERROR: Refusing to change a Proxmox host.' >&2; exit 1;
}
# shellcheck disable=SC1091
. /etc/os-release
[[ $ID == debian && $VERSION_ID == 13 ]] || {
  echo 'ERROR: This policy requires Debian 13.' >&2; exit 1;
}
container=$(systemd-detect-virt --container || true)
[[ $container == lxc ]] || {
  echo 'ERROR: This block requires a Debian 13 LXC container.' >&2; exit 1;
}
[[ $PROFILE == lxc || $PROFILE == auto ]] || {
  echo 'ERROR: Only the lxc hardening profile is supported.' >&2; exit 1;
}
PROFILE=lxc
[[ $RP_FILTER == auto ]] && RP_FILTER=1
[[ $KEEP_SSH == auto ]] && KEEP_SSH=0
[[ $RP_FILTER =~ ^[12]$ && $KEEP_SSH =~ ^[01]$ && $REMOVE_POSTFIX =~ ^[01]$ ]] || {
  echo 'ERROR: Invalid hardening setting.' >&2; exit 1;
}
[[ $KEEP_SSH == 1 || -z ${SSH_CONNECTION:-} ]] || {
  echo 'ERROR: Run through pct exec/console before removing SSH, or set HARDENING_KEEP_SSH=1.' >&2; exit 1;
}
for value in "$JOURNAL_DAYS" "$JOURNAL_MAX_MB" "$JOURNAL_RUNTIME_MB" "$UPDATE_MAX_AGE"; do
  [[ $value =~ ^[1-9][0-9]{0,3}$ ]] || { echo 'ERROR: Numeric policy values must be 1..9999.' >&2; exit 1; }
done
for port in $TCP_PORTS $UDP_PORTS; do
  if [[ ! $port =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
    echo 'ERROR: Port lists require space-separated numbers from 1 to 65535.' >&2; exit 1
  fi
done
for command in ufw iptables ip6tables ip ss sysctl python3 systemctl apt-get flock timeout; do
  command -v "$command" >/dev/null || { echo "ERROR: Missing prerequisite: $command" >&2; exit 1; }
done
exec 9>/run/lock/lab-hardening-install.lock
flock -n 9 || { echo 'ERROR: Hardening is already running.' >&2; exit 1; }

# Check before any changes. Existing forwarding usually means bridge/VPN/router
# functionality; do not silently break it with a service-host policy.
for path in /proc/sys/net/ipv4/ip_forward /proc/sys/net/{ipv4,ipv6}/conf/*/forwarding; do
  [[ -r $path && $(cat "$path") == 0 ]] || {
    echo "ERROR: Forwarding enabled/unavailable at $path; review the guest network role." >&2; exit 1;
  }
done
ufw status | grep -qx 'Status: active'
grep -qx 'IPV6=yes' /etc/default/ufw
for tool in iptables ip6tables; do
  prefix=ufw; [[ $tool != ip6tables ]] || prefix=ufw6
  "$tool" -w 5 -S INPUT | grep -qx -- '-P INPUT DROP'
  "$tool" -w 5 -S FORWARD | grep -qx -- '-P FORWARD DROP'
  "$tool" -w 5 -C INPUT -j "$prefix-before-input"
  "$tool" -w 5 -S "$prefix-user-input" >/dev/null
done

# ── Staging and backups ───────────────────────────────────────────────────────
stage=$(mktemp -d /var/tmp/lab-hardening.XXXXXX)
chmod 0700 "$stage"
backup="/var/backups/lab-hardening/$(date -u +%Y%m%dT%H%M%SZ)-$$"
install -d -m 0700 "$backup"
hardening_exit=0
trap 'hardening_exit=$?; rm -rf -- "$stage"; exit "$hardening_exit"' EXIT
trap 'echo "ERROR: Hardening failed near guest line $LINENO. Guest preserved; config backups: $backup" >&2' ERR
# Timezone policy is owned here, inside the verified LXC dispatch boundary.
# Validate and apply before package operations; preserve mode makes no timezone writes.
cat > "$stage/timezone.py" <<'TIMEZONE_HELPER'
#!/usr/bin/python3
"""LXC timezone policy, adapted from debian-hardening.sh v1.0.3.

Only apply writes timezone files; plan/check are read-only. No timedated,
clock, RTC, NTP, SSH, or access-recovery operations are performed.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from zoneinfo import ZoneInfo

ZONES = Path('/usr/share/zoneinfo')
LOCALTIME = Path('/etc/localtime')
TIMEZONE = Path('/etc/timezone')


def guest_guard():
    if os.geteuid() != 0 or shutil.which('pveversion') or Path('/etc/pve').exists():
        raise ValueError('Timezone operations require root inside the selected Debian 13 LXC.')
    release = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines()
                   if '=' in line and not line.startswith('#'))
    if release.get('ID', '').strip('"') != 'debian' or release.get('VERSION_ID', '').strip('"') != '13':
        raise ValueError('Timezone policy requires Debian 13.')
    result = subprocess.run(['systemd-detect-virt', '--container'], text=True,
                            capture_output=True, timeout=10)
    if result.returncode or result.stdout.strip() != 'lxc':
        raise ValueError('Timezone policy refuses environments other than LXC.')


def zone_path(name):
    # Same name grammar as the native source; validate against guest tzdata.
    if not re.fullmatch(r'[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+)*', name):
        raise ValueError('Invalid SERVER_TIMEZONE; use an installed IANA timezone name.')
    if name.split('/')[0] in ('posix', 'right', 'localtime', 'posixrules'):
        raise ValueError('SERVER_TIMEZONE must identify an IANA zone, not a special tzdata tree.')
    path = ZONES / name
    try:
        path.resolve(strict=True).relative_to(ZONES.resolve(strict=True))
        with path.open('rb') as stream:
            ZoneInfo.from_file(stream, key=name)
    except (OSError, ValueError) as exc:
        raise ValueError('Timezone is unavailable or invalid in this guest: ' + name) from exc
    return path


def effective_timezone():
    if not LOCALTIME.exists() and not LOCALTIME.is_symlink():
        zone_path('UTC')
        return 'UTC'  # localtime(5): absent /etc/localtime means UTC.
    if LOCALTIME.is_symlink():
        # Keep the selected alias, rather than resolving US/Eastern to another name.
        link = Path(os.path.normpath(LOCALTIME.parent / os.readlink(LOCALTIME)))
        try:
            name = str(link.relative_to(ZONES))
        except ValueError as exc:
            raise ValueError('/etc/localtime does not link into the guest zoneinfo tree.') from exc
        zone_path(name)
        return name
    if LOCALTIME.is_file() and TIMEZONE.is_file() and not TIMEZONE.is_symlink():
        name = TIMEZONE.read_text().strip()
        if LOCALTIME.read_bytes() == zone_path(name).read_bytes():
            return name
    raise ValueError('Cannot identify the guest timezone from /etc/localtime and /etc/timezone.')


def fingerprint(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return {'kind': 'absent'}
    if stat.S_ISLNK(info.st_mode):
        return {'kind': 'symlink', 'target': os.readlink(path)}
    if stat.S_ISREG(info.st_mode):
        return {'kind': 'file', 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    raise ValueError('Unsupported timezone file type: ' + str(path))


def fingerprints():
    return {str(path): fingerprint(path) for path in (LOCALTIME, TIMEZONE)}


def plan(preserve, requested):
    if preserve not in ('0', '1'):
        raise ValueError('PRESERVE_EXISTING_TIMEZONE must be exactly 0 or 1.')
    if preserve == '0':
        zone_path(requested)
        if TIMEZONE.is_symlink() or (TIMEZONE.exists() and not TIMEZONE.is_file()):
            raise ValueError('Refusing to replace a non-regular /etc/timezone.')
    before = effective_timezone()
    return {'preserve': preserve == '1', 'requested': None if preserve == '1' else requested,
            'before': before, 'effective': before if preserve == '1' else requested,
            'files_before': fingerprints()}


def verify(setting):
    actual = effective_timezone()
    if actual != setting['effective']:
        raise ValueError('Guest timezone drift: expected ' + setting['effective'] + ', found ' + actual)
    expected_files = setting.get('files', setting['files_before'])
    if fingerprints() != expected_files:
        raise ValueError('Guest timezone files changed; review /etc/localtime and /etc/timezone.')
    return actual


def apply(setting, backup):
    if fingerprints() != setting['files_before'] or effective_timezone() != setting['before']:
        raise ValueError('Guest timezone changed after validation; refusing to overwrite it.')
    if not setting['preserve']:
        target = zone_path(setting['requested'])
        saved = Path(backup) / 'timezone'
        saved.mkdir(mode=0o700, parents=True, exist_ok=False)
        (saved / 'before.json').write_text(json.dumps(setting, indent=2) + '\n')
        for path in (LOCALTIME, TIMEZONE):
            if path.exists() or path.is_symlink():
                shutil.copy2(path, saved / path.name, follow_symlinks=False)
        # Atomic per-file replacement; no automatic undo of a later failure.
        if setting['before'] != setting['requested']:
            with tempfile.TemporaryDirectory(prefix='.lab-timezone-', dir=LOCALTIME.parent) as tmp:
                replacement = Path(tmp) / 'localtime'
                replacement.symlink_to(target)
                os.replace(replacement, LOCALTIME)
        # Debian uses /etc/localtime. Keep an existing legacy file consistent;
        # do not introduce /etc/timezone when the template does not maintain it.
        desired = setting['requested'] + '\n'
        if TIMEZONE.exists() and TIMEZONE.read_text() != desired:
            with tempfile.TemporaryDirectory(prefix='.lab-timezone-', dir=TIMEZONE.parent) as tmp:
                replacement = Path(tmp) / 'timezone'
                replacement.write_text(desired)
                replacement.chmod(0o644)
                os.replace(replacement, TIMEZONE)
    final = {**setting, 'files': fingerprints()}
    if setting['preserve'] and final['files'] != setting['files_before']:
        raise ValueError('Preserve mode detected a timezone-file change.')
    verify(final)
    return final


def main():
    guest_guard()
    if len(sys.argv) == 4 and sys.argv[1] == 'plan':
        print(json.dumps(plan(sys.argv[2], sys.argv[3])))
    elif len(sys.argv) == 4 and sys.argv[1] == 'apply':
        setting = json.loads(Path(sys.argv[2]).read_text())
        print(json.dumps(apply(setting, sys.argv[3])))
    elif len(sys.argv) == 3 and sys.argv[1] == 'check':
        policy = json.loads(Path(sys.argv[2]).read_text())
        print(verify(policy['timezone']))
    else:
        raise ValueError('Invalid timezone helper arguments.')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print('ERROR: LXC timezone: ' + str(exc), file=sys.stderr)
        raise SystemExit(1)
TIMEZONE_HELPER
python3 "$stage/timezone.py" plan "$PRESERVE_TIMEZONE" "$REQUESTED_TIMEZONE" > "$stage/timezone-plan.json"
python3 "$stage/timezone.py" apply "$stage/timezone-plan.json" "$backup" > "$stage/timezone-policy.json"
install -d -m 0755 /var/lib/lab-hardening
if [[ $(systemctl show lab-hardening-check.timer -p LoadState --value) == loaded ]]; then
  systemctl stop lab-hardening-check.timer
  systemctl stop lab-hardening-check.service
fi

# APT package operations use locks, strict download errors, and report-only
# needrestart. No dist-upgrade is performed late in an already running app install.
apt-get -o DPkg::Lock::Timeout=120 -o APT::Update::Error-Mode=any update
date +%s > "$stage/index-refreshed"
apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends \
  unattended-upgrades needrestart python3-apt ca-certificates procps

mkdir -p "$stage/etc/apt/apt.conf.d" "$stage/etc/needrestart/conf.d" \
  "$stage/etc/systemd/journald.conf.d" "$stage/etc/sysctl.d" \
  "$stage/etc/systemd/system" "$stage/usr/local/sbin" "$stage/etc/update-motd.d"
install -m 0755 "$stage/timezone.py" "$stage/usr/local/sbin/lab-timezone"
cat > "$stage/etc/apt/apt.conf.d/99-lab-hardening" <<'APT_POLICY'
// Managed by lab-hardening-block.sh. Debian release stays fixed at trixie.
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
  "origin=Debian,codename=trixie,label=Debian";
  "origin=Debian,codename=trixie-updates,label=Debian";
  "origin=Debian,codename=trixie-security,label=Debian-Security";
};
// Preserve deliberate package blacklists/holds; report them in the check.
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Update::Error-Mode "any";
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
Unattended-Upgrade::Automatic-Reboot "false";
APT_POLICY
cat > "$stage/etc/needrestart/conf.d/99-lab-hardening.conf" <<'NEEDRESTART_POLICY'
# Report only. Package maintainer scripts may still restart their own services.
$nrconf{restart} = 'l';
NEEDRESTART_POLICY
cat > "$stage/etc/systemd/journald.conf.d/99-lab-hardening.conf" <<JOURNAL_POLICY
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=${JOURNAL_MAX_MB}M
SystemKeepFree=128M
RuntimeMaxUse=${JOURNAL_RUNTIME_MB}M
MaxRetentionSec=${JOURNAL_DAYS}day
RateLimitIntervalSec=30s
RateLimitBurst=10000
JOURNAL_POLICY

# ── Network policy ───────────────────────────────────────────────────────────
cat > "$stage/etc/sysctl.d/99-hardening.conf" <<SYSCTL_POLICY
# Managed by lab-hardening-block.sh: non-routing Debian 13 LXC.
# Forwarding comes first because changing it can reset IPv4 interface settings.
net.ipv4.ip_forward = 0
net.ipv4.conf.all.forwarding = 0
net.ipv4.conf.default.forwarding = 0
net.ipv4.conf.*.forwarding = 0
net.ipv6.conf.all.forwarding = 0
net.ipv6.conf.default.forwarding = 0
net.ipv6.conf.*.forwarding = 0
net.ipv4.conf.all.rp_filter = $RP_FILTER
net.ipv4.conf.default.rp_filter = $RP_FILTER
net.ipv4.conf.*.rp_filter = $RP_FILTER
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.*.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.*.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.*.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.*.accept_redirects = 0
# -1 rejects all IPv6 routing headers; 0 would still accept type 2.
net.ipv6.conf.all.accept_source_route = -1
net.ipv6.conf.default.accept_source_route = -1
net.ipv6.conf.*.accept_source_route = -1
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
# Preserve IPv6 addressing, router advertisements, autoconf and DHCP.
SYSCTL_POLICY

# ── APT readiness wrapper ─────────────────────────────────────────────────────
# No network-manager disabling, DHCP changes or network restarts. Re-evaluate
# ownership on every APT run; delegate to Debian's helper unless proven safe.
cat > "$stage/usr/local/sbin/lab-apt-wait-online" <<'APT_WAIT_HELPER'
#!/usr/bin/python3
import json
import os
import subprocess
os.environ['LC_ALL'] = 'C'
os.environ['PATH'] = '/usr/sbin:/usr/bin:/sbin:/bin'

def capture(args):
    return subprocess.run(args, text=True, capture_output=True, timeout=15, check=True).stdout

try:
    if capture(['systemd-detect-virt', '--container']).strip() == 'lxc':
        capture(['systemctl', 'is-active', 'networking.service'])
        rows = [line.split() for line in capture(
            ['networkctl', 'list', '--no-legend', '--no-pager']).splitlines() if line.strip()]
        # An unfamiliar output shape cannot authorize bypassing the stock check.
        if rows and all(len(row) == 5 and row[4] == 'unmanaged' for row in rows):
            configured = set(capture(['ifquery', '--list']).split())
            addresses = json.loads(capture(['ip', '-j', '-4', 'address', 'show']))
            routes = json.loads(capture(['ip', '-j', '-4', 'route', 'show', 'default']))
            for link in addresses:
                name = link['ifname']
                if (name in configured and 'UP' in link.get('flags', [])
                        and any(a.get('scope') == 'global' for a in link.get('addr_info', []))
                        and any(r.get('dev') == name for r in routes)):
                    capture(['ifquery', '--state', name])
                    raise SystemExit(0)
except (OSError, subprocess.SubprocessError, ValueError, KeyError):
    pass
os.execv('/usr/lib/apt/apt-helper', ['apt-helper', 'wait-online'])
APT_WAIT_HELPER
# Only replace Debian's single stock pre-check, or our own earlier wrapper.
# Preserve unknown/custom ExecStartPre sequences by refusing to replace them.
for unit in apt-daily.service apt-daily-upgrade.service; do
  systemctl show "$unit" -p ExecStartPre --value > "$stage/precheck"
  python3 - "$stage/precheck" <<'APT_PRECHECK'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
paths = re.findall(r'path=([^ ;]+)', text)
if paths not in (['/usr/lib/apt/apt-helper'], ['/usr/local/sbin/lab-apt-wait-online']):
    raise SystemExit('ERROR: Custom APT ExecStartPre detected; preserve it and review integration.')
if paths == ['/usr/lib/apt/apt-helper'] and not re.search(r'argv\[\]=/usr/lib/apt/apt-helper wait-online\s*;', text):
    raise SystemExit('ERROR: Unexpected apt-helper pre-check arguments.')
APT_PRECHECK
  mkdir -p "$stage/etc/systemd/system/$unit.d"
  cat > "$stage/etc/systemd/system/$unit.d/90-lab-readiness.conf" <<'APT_DROPIN'
[Service]
ExecStartPre=
ExecStartPre=-/usr/local/sbin/lab-apt-wait-online
APT_DROPIN
done

# ── Postfix inventory and runtime verification (read-only) ────────────────────
cat > "$stage/usr/local/sbin/lab-postfix-check" <<'POSTFIX_CHECK_HELPER'
#!/usr/bin/python3
"""Read-only Postfix inventory and removal checks for the native Debian service."""
import os
from pathlib import Path
import re
import subprocess
import sys

os.environ['LC_ALL'] = 'C'
os.environ['PATH'] = '/usr/sbin:/usr/bin:/sbin:/bin'
STANDARD_UNITS = {
    'postfix.service', 'postfix@.service',
    'postfix.socket', 'postfix@.socket',
    'postfix-resolvconf.service', 'postfix-resolvconf.path',
}
INSTANCE = re.compile(r'postfix@[^/\s]+\.(?:service|socket)')
TEMPLATES = {'postfix@.service', 'postfix@.socket'}
# Debian's packaged daemon names are only an ambiguity guard when procfs denies
# executable inspection, never sufficient identity for stopping/killing a PID.
DAEMON_NAMES = {'master', 'anvil', 'bounce', 'cleanup', 'discard', 'dnsblog', 'error',
                'flush', 'fsstone', 'lmtp', 'local', 'nqmgr', 'oqmgr', 'pickup', 'pipe',
                'postlogd', 'postscreen', 'proxymap', 'qmgr', 'qmqpd', 'scache', 'showq',
                'smtp', 'smtpd', 'spawn', 'tlsmgr', 'tlsproxy', 'trivial-rewrite',
                'verify', 'virtual', 'postfix', 'postmulti', 'postdrop', 'postqueue'}

def is_postfix_unit(name):
    return name in STANDARD_UNITS or INSTANCE.fullmatch(name) is not None

def command(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError(f'{" ".join(args)} exited {result.returncode}: '
                           + (result.stderr.strip()[:1500] or '(no stderr)'))
    return result.stdout

try:
    if os.geteuid() != 0:
        raise ValueError('Root is required to inspect process ownership.')
    if len(sys.argv) != 2 or sys.argv[1] not in {
            '--units', '--stop-units', '--check-stopped', '--check-removed'}:
        raise ValueError('Use --units, --stop-units, --check-stopped or --check-removed.')
    mode = sys.argv[1]
    runtime = {}
    # Include not-found/masked units that systemd still has in memory. Never
    # equate LoadState=not-found or package absence with a stopped service.
    output = command(['systemctl', 'list-units', '--all', '--plain', '--full',
                      '--no-legend', '--no-pager', 'postfix*'])
    for line in output.splitlines():
        fields = line.split()
        if not fields:
            continue
        if len(fields) < 4:
            raise ValueError('Malformed systemd unit inventory.')
        unit, load, active, sub = fields[:4]
        if is_postfix_unit(unit):
            runtime[unit] = (load, active, sub)
    units = set(STANDARD_UNITS) | runtime.keys()
    if mode in {'--units', '--check-removed'}:
        output = command(['systemctl', 'list-unit-files', '--full', '--no-legend',
                          '--no-pager', 'postfix*'])
        for line in output.splitlines():
            fields = line.split()
            if fields and is_postfix_unit(fields[0]):
                units.add(fields[0])
    if mode == '--units':
        print('\n'.join(sorted(units)))
        raise SystemExit(0)
    if mode == '--stop-units':
        # Only instantiated runtime units need stopping. Templates cannot run;
        # absent/inactive units would make systemctl stop fail needlessly.
        pending = [unit for unit, (_, active, _) in runtime.items()
                   if unit not in TEMPLATES and active != 'inactive']
        print('\n'.join(sorted(pending, key=lambda u: (u.endswith('.service'), u))))
        raise SystemExit(0)

    errors = []
    for unit, (load, active, sub) in sorted(runtime.items()):
        if active != 'inactive':
            errors.append(f'{unit}: LoadState={load}, ActiveState={active}, SubState={sub}')
    # Executable paths catch detached daemons and deleted executables. Cgroup
    # membership catches remaining workers even if the unit file has vanished.
    # Do not match a bare process name such as "master" and never signal a PID.
    for process in Path('/proc').iterdir():
        if not process.name.isdecimal():
            continue
        try:
            groups = process.joinpath('cgroup').read_text()
            try:
                executable = os.readlink(process / 'exe').removesuffix(' (deleted)')
            except FileNotFoundError:
                executable = ''  # exited process, kernel thread or zombie
            except PermissionError:
                executable = ''
                # LXC root need not have ptrace access to every unrelated
                # process. Keep cgroup detection and fail on ambiguous daemon
                # names instead of requiring extra CT capabilities.
                name = process.joinpath('comm').read_text().strip()
                if name in DAEMON_NAMES:
                    errors.append(f'Cannot exclude a Postfix process: PID={process.name}, '
                                  f'comm={name}; executable inspection denied')
            group_owned = any(is_postfix_unit(component)
                              for line in groups.splitlines()
                              for component in line.split(':', 2)[-1].split('/'))
            exe_owned = (executable.startswith(('/usr/lib/postfix/', '/usr/libexec/postfix/'))
                         or executable in {'/usr/sbin/postfix', '/usr/sbin/postmulti',
                                           '/usr/sbin/postdrop', '/usr/sbin/postqueue'})
            if group_owned or exe_owned:
                errors.append(f'Postfix process remains: PID={process.name}, '
                              f'executable={executable or "unavailable"}')
        except FileNotFoundError:
            continue  # process exited during the read-only scan
        except OSError as exc:
            errors.append(f'Cannot inspect PID {process.name}: {exc.strerror}')
    if mode == '--check-removed':
        package = subprocess.run(['dpkg-query', '-W', '-f=${db:Status-Status}', 'postfix'],
                                 capture_output=True, text=True, timeout=30)
        absent = (package.returncode == 0 and package.stdout.strip() == 'not-installed')
        absent = absent or (package.returncode == 1 and not package.stdout.strip()
                            and package.stderr.strip() == 'dpkg-query: no packages found matching postfix')
        if not absent:
            errors.append('Postfix package is not confirmed purged: '
                          + (package.stdout.strip() or package.stderr.strip()[:500] or 'unknown status'))
        for unit in sorted(units):
            # is-enabled returns nonzero for masked units; validate its text
            # and reject runtime-only masks, which would disappear at boot.
            result = subprocess.run(['systemctl', 'is-enabled', unit],
                                    capture_output=True, text=True, timeout=30)
            if result.returncode not in (0, 1) or result.stdout.strip() != 'masked':
                errors.append(f'Persistent Postfix mask missing: {unit}')
    if errors:
        for error in errors:
            print('ERROR: ' + error, file=sys.stderr)
        raise SystemExit(1)
    print('Postfix units and processes stopped.' if mode == '--check-stopped' else
          'Postfix package purged; units masked; no remaining Postfix processes.')
except Exception as exc:
    print('ERROR: Postfix verification: ' + str(exc), file=sys.stderr)
    raise SystemExit(1)
POSTFIX_CHECK_HELPER

# ── Reusable verification/report helper ────────────────────────────────────────
# This helper reads policy/runtime state. Its only writes are its lock and report.
# It never changes firewall rules, installs updates or restarts applications.
cat > "$stage/usr/local/sbin/lab-hardening-check" <<'CHECK_HELPER'
#!/usr/bin/python3
import fcntl
import glob
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

os.environ['LC_ALL'] = 'C'
os.environ['PATH'] = '/usr/sbin:/usr/bin:/sbin:/bin'

STATE = Path('/var/lib/lab-hardening')
errors, warnings, listeners = [], [], []
timezone = None

def run(args, timeout=30):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip()
    except (OSError, subprocess.SubprocessError) as exc:
        errors.append(f'Cannot run {args[0]}: {exc}')
        return 127, ''

def require(condition, message):
    if not condition:
        errors.append(message)

def read(path):
    try:
        return Path(path).read_text()
    except OSError as exc:
        errors.append(f'Cannot read {path}: {exc}')
        return ''

if os.geteuid() != 0:
    raise SystemExit('Run lab-hardening-check as root.')
lock = open(STATE / 'check.lock', 'a')
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit('A hardening check is already running.')
try:
    policy = json.loads(read(STATE / 'policy.json'))
    for path, digest in policy['files'].items():
        try:
            require(hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest,
                    f'Managed file changed: {path}; review and rerun the hardening block.')
        except OSError:
            errors.append(f'Managed file missing: {path}')

    # Check selected zone and file identity without freezing tzdata database bytes.
    tz_result = subprocess.run(['/usr/local/sbin/lab-timezone', 'check', str(STATE / 'policy.json')],
                               text=True, capture_output=True, timeout=30)
    timezone = tz_result.stdout.strip() if tz_result.returncode == 0 else None
    require(tz_result.returncode == 0, 'Timezone policy verification failed: '
            + (tz_result.stderr.strip()[:1000] or 'see guest timezone files'))

    # Runtime readback, including dotted interface names through procfs globbing.
    for line in read('/etc/sysctl.d/99-hardening.conf').splitlines():
        line = line.split('#', 1)[0].strip()
        if not line:
            continue
        key, expected = (part.strip() for part in line.split('=', 1))
        paths = glob.glob('/proc/sys/' + key.replace('.', '/'))
        require(bool(paths), f'Required sysctl unavailable: {key}')
        for path in paths:
            require(read(path).strip() == expected, f'Sysctl mismatch: {path}, expected {expected}')

    rc, status = run(['ufw', 'status'])
    require(rc == 0 and 'Status: active' in status.splitlines(), 'UFW is inactive.')
    ufw_defaults = read('/etc/default/ufw')
    require(re.search(r'^IPV6=yes$', ufw_defaults, re.M), 'UFW IPv6 support disabled.')
    require(re.search(r'^IPT_SYSCTL=$', ufw_defaults, re.M), 'UFW sysctl loading is enabled.')
    for tool, prefix in [('iptables', 'ufw'), ('ip6tables', 'ufw6')]:
        for chain in ['INPUT', 'FORWARD']:
            rc, rules = run([tool, '-w', '5', '-S', chain])
            require(rc == 0 and f'-P {chain} DROP' in rules.splitlines(), f'{tool} {chain} is not DROP.')
        rc, _ = run([tool, '-w', '5', '-C', 'INPUT', '-j', prefix + '-before-input'])
        require(rc == 0, f'{tool} UFW INPUT hook is missing.')
        rc, _ = run([tool, '-w', '5', '-S', prefix + '-user-input'])
        require(rc == 0, f'{tool} UFW user chain is missing.')

    # APT lists are compared as sets: vendor/local duplication cannot widen policy.
    import apt_pkg
    apt_pkg.init()
    cfg = apt_pkg.config
    origins = {
        'origin=Debian,codename=trixie,label=Debian',
        'origin=Debian,codename=trixie-updates,label=Debian',
        'origin=Debian,codename=trixie-security,label=Debian-Security',
    }
    require(set(cfg.value_list('Unattended-Upgrade::Origins-Pattern')) == origins,
            'Effective unattended-upgrade origins differ from policy.')
    require(not cfg.value_list('Unattended-Upgrade::Allowed-Origins'), 'Additional legacy Allowed-Origins exist.')
    for key, expected in {
        'APT::Periodic::Enable': '1', 'APT::Periodic::Update-Package-Lists': '1',
        'APT::Periodic::Unattended-Upgrade': '1', 'APT::Periodic::AutocleanInterval': '7',
        'APT::Update::Error-Mode': 'any',
        'Unattended-Upgrade::Automatic-Reboot': 'false',
        'Unattended-Upgrade::InstallOnShutdown': 'false',
        'Unattended-Upgrade::Remove-New-Unused-Dependencies': 'true',
        'Unattended-Upgrade::Remove-Unused-Dependencies': 'false',
        'Unattended-Upgrade::Remove-Unused-Kernel-Packages': 'false',
    }.items():
        require(cfg.find(key) == expected, f'APT policy conflict: {key}')
    if cfg.value_list('Unattended-Upgrade::Package-Blacklist'):
        warnings.append('An unattended-upgrades blacklist is active; review excluded packages.')
    if cfg.value_list('Unattended-Upgrade::Package-Whitelist'):
        warnings.append('An unattended-upgrades whitelist is active; review update coverage.')
    rc, holds = run(['apt-mark', 'showhold'])
    require(rc == 0, 'Cannot inspect held packages.')
    if holds:
        warnings.append('Held packages: ' + ', '.join(holds.splitlines()))
    for unit in ['ufw.service', 'unattended-upgrades.service', 'apt-daily.timer',
                 'apt-daily-upgrade.timer', 'lab-hardening-check.timer']:
        require(run(['systemctl', 'is-enabled', '--quiet', unit])[0] == 0, f'{unit} is not enabled.')
        require(run(['systemctl', 'is-active', '--quiet', unit])[0] == 0, f'{unit} is not active.')
    for unit in ['apt-daily.service', 'apt-daily-upgrade.service']:
        rc, result = run(['systemctl', 'show', unit, '-p', 'Result', '--value'])
        require(rc == 0 and result == 'success', f'{unit} last result: {result or "unknown"}')
    now = time.time()
    stamps = [Path('/var/lib/apt/periodic/update-stamp'), STATE / 'last-index-refresh']
    last_refresh = max((p.stat().st_mtime for p in stamps if p.exists()), default=0)
    require(now - last_refresh <= policy['update_max_age_hours'] * 3600,
            'APT indexes have no recent recorded refresh; inspect apt-daily.service.')

    # Verify the merged journald settings; commented defaults are not assignments.
    rc, journal = run(['systemd-analyze', 'cat-config', 'systemd/journald.conf'])
    require(rc == 0, 'Cannot inspect journald policy.')
    effective = {}
    section = ''
    for line in journal.splitlines():
        line = line.strip()
        if line.startswith('['):
            section = line
        elif section == '[Journal]' and '=' in line and not line.startswith(('#', ';')):
            k, v = line.split('=', 1)
            effective[k.strip()] = v.strip()
    for key, expected in policy['journal'].items():
        require(effective.get(key) == expected, f'Journald policy conflict: {key}')
    require(run(['systemctl', 'is-active', '--quiet', 'systemd-journald.service'])[0] == 0,
            'Journald is not active.')
    require(bool(glob.glob('/var/log/journal/*/*.journal')), 'Persistent journal files are missing.')

    removed = []
    if not policy['keep_ssh']:
        removed.append('openssh-server')
    if policy['remove_postfix']:
        removed.append('postfix')
    for package in removed:
        _, status = run(['dpkg-query', '-W', '-f=${db:Status-Status}', package])
        require(status != 'installed', f'Unwanted package installed: {package}')
    if not policy['keep_ssh']:
        for unit in ['ssh.service', 'ssh.socket']:
            require(run(['systemctl', 'is-enabled', unit])[1] == 'masked', f'{unit} is not masked.')
            require(run(['systemctl', 'is-active', '--quiet', unit])[0] != 0, f'{unit} is active.')

    if policy['remove_postfix']:
        # Keep the detailed diagnostic in the hardening report. This helper is
        # read-only and checks runtime units/processes even after package purge.
        postfix = subprocess.run(['/usr/local/sbin/lab-postfix-check', '--check-removed'],
                                 capture_output=True, text=True, timeout=90)
        require(postfix.returncode == 0,
                'Postfix removal incomplete: ' + (postfix.stderr.strip()[:4000] or 'verification failed'))

    # Inventory excludes loopback; optional port lists verify external listeners.
    rc, sockets = run(['ss', '-H', '-lntu'])
    require(rc == 0, 'Cannot inspect listening sockets.')
    for line in sockets.splitlines():
        fields = line.split()
        if len(fields) < 5:
            errors.append('Unrecognized ss output.')
            continue
        proto, endpoint = fields[0], fields[4]
        addr, port = endpoint.rsplit(':', 1)
        # ss may print [IPv6]%interface:port or [IPv6%interface]:port.
        addr = addr.split('%', 1)[0].strip('[]')
        try:
            if ipaddress.ip_address(addr).is_loopback:
                continue
        except ValueError:
            if addr != '*':
                errors.append(f'Unrecognized socket address: {addr}')
        listeners.append(f'{proto} {endpoint}')
        allowed = policy.get(proto + '_ports', [])
        if allowed:
            require(int(port) in allowed, f'Unexpected external listener: {proto} {endpoint}')
    # needrestart's explicit batch/list mode cannot restart applications.
    rc, restart = run(['needrestart', '-b', '-r', 'l', '-l'], timeout=90)
    require(rc == 0, 'needrestart report failed.')
    requests = [line for line in restart.splitlines()
                if line.startswith(('NEEDRESTART-SVC:', 'NEEDRESTART-CONT:', 'NEEDRESTART-SESS:'))]
    if requests:
        warnings.append('Processes need a reviewed restart: ' + '; '.join(requests))
except Exception as exc:
    errors.append(f'Check could not complete: {type(exc).__name__}: {exc}')

status = 'FAIL' if errors else ('WARN' if warnings else 'OK')
report = {'status': status, 'checked_at': int(time.time()), 'errors': errors,
          'warnings': warnings, 'external_listeners': listeners, 'timezone': timezone}
temporary = STATE / ('status.' + str(os.getpid()) + '.tmp')
temporary.write_text(json.dumps(report, indent=2) + '\n')
temporary.chmod(0o644)
os.replace(temporary, STATE / 'status.json')
print('Lab hardening: ' + status)
for entry in errors:
    print('ERROR: ' + entry)
for entry in warnings:
    print('WARNING: ' + entry)
print('External listeners: ' + (', '.join(listeners) or 'none'))
raise SystemExit(1 if errors else 0)
CHECK_HELPER

cat > "$stage/etc/systemd/system/lab-hardening-check.service" <<'CHECK_SERVICE'
[Unit]
Description=Verify lab hardening and report update/restart status
After=network.target systemd-journal-flush.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/lab-hardening-check
Nice=10
TimeoutStartSec=240
StandardOutput=journal
StandardError=journal
CHECK_SERVICE
cat > "$stage/etc/systemd/system/lab-hardening-check.timer" <<'CHECK_TIMER'
[Unit]
Description=Check lab hardening after boot and hourly
[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
RandomizedDelaySec=60
Unit=lab-hardening-check.service
[Install]
WantedBy=timers.target
CHECK_TIMER
cat > "$stage/etc/update-motd.d/25-lab-hardening" <<'MOTD_HELPER'
#!/usr/bin/python3
import json
from pathlib import Path
import time
try:
    p = json.loads(Path('/var/lib/lab-hardening/status.json').read_text())
    stale = time.time() - p['checked_at'] > 3 * 3600
    print('  Hardening: ' + ('STALE' if stale else p['status'])
          + ' | root check: /usr/local/sbin/lab-hardening-check')
except (OSError, ValueError, KeyError):
    print('  Hardening: not yet verified | root check: /usr/local/sbin/lab-hardening-check')
MOTD_HELPER

# ── Install managed files atomically, preserving previous configuration ────────
python3 - "$stage" "$backup" <<'INSTALL_FILES'
import os, pathlib, shutil, sys, tempfile
stage, backup = map(pathlib.Path, sys.argv[1:])
for source in sorted(stage.rglob('*')):
    if not source.is_file() or source.parent == stage:
        continue
    relative = source.relative_to(stage)
    target = pathlib.Path('/') / relative
    if target.is_symlink():
        raise SystemExit(f'ERROR: Refusing to overwrite symlink: {target}')
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        saved = backup / relative
        saved.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(target, saved)
    fd, temporary = tempfile.mkstemp(prefix='.lab-hardening-', dir=target.parent)
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(source.read_bytes())
        mode = 0o755 if str(relative).startswith(('usr/local/sbin/', 'etc/update-motd.d/')) else 0o644
        os.chmod(temporary, mode)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
# Preserve all UFW policy/rules; only stop its competing sysctl loader.
target = pathlib.Path('/etc/default/ufw')
saved = backup / 'etc/default/ufw'
saved.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(target, saved)
import re
text, count = re.subn(r'^IPT_SYSCTL=.*$', 'IPT_SYSCTL=', target.read_text(), flags=re.M)
if count != 1:
    raise SystemExit('ERROR: Expected one IPT_SYSCTL assignment in /etc/default/ufw.')
fd, temporary = tempfile.mkstemp(prefix='.lab-ufw-', dir=target.parent)
with os.fdopen(fd, 'w') as out:
    out.write(text)
os.chmod(temporary, target.stat().st_mode & 0o777)
os.replace(temporary, target)
INSTALL_FILES
install -m 0644 "$stage/index-refreshed" /var/lib/lab-hardening/last-index-refresh

# ── Remove and verify unwanted services ───────────────────────────────────────
remove_packages=()
if [[ $REMOVE_POSTFIX == 1 ]]; then
  # Scope operations to known Debian Postfix units and actual instances only.
  # Read inventory before masking/purging; a not-found unit can still be active.
  postfix_unit_text=$(/usr/local/sbin/lab-postfix-check --units)
  mapfile -t postfix_units <<< "$postfix_unit_text"
  postfix_stop_text=$(/usr/local/sbin/lab-postfix-check --stop-units)
  if [[ -n $postfix_stop_text ]]; then
    mapfile -t postfix_stop_units <<< "$postfix_stop_text"
    echo 'Stopping Postfix units before package removal...'
    timeout 60 systemctl stop "${postfix_stop_units[@]}"
  fi
  # Mask without --force: never overwrite a local custom unit. No blanket
  # process-name kills. If stopping or masking fails, preserve the CT and fail.
  systemctl mask "${postfix_units[@]}"
  /usr/local/sbin/lab-postfix-check --check-stopped
fi
if [[ $KEEP_SSH == 0 ]]; then
  for unit in ssh.service ssh.socket; do
    if [[ $(systemctl show "$unit" -p LoadState --value) != not-found ]]; then
      systemctl stop "$unit"
    fi
  done
  remove_packages+=(openssh-server)
fi
[[ $REMOVE_POSTFIX == 0 ]] || remove_packages+=(postfix)
installed_remove=()
for package in "${remove_packages[@]}"; do
  package_status=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)
  if [[ $package_status == installed ]] ||
     [[ $package == postfix && -n $package_status && $package_status != not-installed ]]; then
    # Include Postfix config-files/partial states, not just fully installed.
    installed_remove+=("$package")
  fi
done
if (( ${#installed_remove[@]} > 0 )); then
  # No blanket autoremove: apps outside dpkg may use packages marked automatic.
  apt-get -o DPkg::Lock::Timeout=120 purge -y "${installed_remove[@]}"
fi
if [[ $KEEP_SSH == 0 ]]; then
  systemctl mask ssh.service ssh.socket
fi

# ── Activate common policy ────────────────────────────────────────────────────
systemctl daemon-reload
if [[ $REMOVE_POSTFIX == 1 ]]; then
  # Package maintainer scripts can remove a mask; restore our explicit policy.
  systemctl mask "${postfix_units[@]}"
  /usr/local/sbin/lab-postfix-check --check-removed
fi
install -d -o root -g systemd-journal -m 2755 /var/log/journal
systemctl restart systemd-journald.service
journalctl --flush
/usr/lib/systemd/systemd-sysctl --strict --prefix=/net/ipv4 --prefix=/net/ipv6
systemctl enable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer
echo 'Checking unattended upgrades without installing updates...'
if ! timeout 300 unattended-upgrade --dry-run --debug > "$backup/unattended-dry-run.log" 2>&1; then
  tail -n 40 "$backup/unattended-dry-run.log" >&2
  false
fi

# Store expected settings and file hashes for drift detection. No secrets.
python3 - "$stage" "$PROFILE" "$KEEP_SSH" "$REMOVE_POSTFIX" "$JOURNAL_DAYS" \
  "$JOURNAL_MAX_MB" "$JOURNAL_RUNTIME_MB" "$UPDATE_MAX_AGE" "$TCP_PORTS" "$UDP_PORTS" <<'SAVE_POLICY'
import hashlib, json, os, pathlib, sys
stage = pathlib.Path(sys.argv[1])
_, _, profile, keep, remove, days, maximum, runtime, age, tcp, udp = sys.argv
files = {}
for source in stage.rglob('*'):
    if source.is_file() and source.parent != stage:
        target = pathlib.Path('/') / source.relative_to(stage)
        files[str(target)] = hashlib.sha256(target.read_bytes()).hexdigest()
policy = {'profile': profile, 'keep_ssh': keep == '1', 'remove_postfix': remove == '1',
          'update_max_age_hours': int(age), 'tcp_ports': list(map(int, tcp.split())),
          'udp_ports': list(map(int, udp.split())), 'files': files,
          'version': '1.2.0',
          'timezone': json.loads((stage / 'timezone-policy.json').read_text()),
          'journal': {'Storage': 'persistent', 'Compress': 'yes', 'SystemMaxUse': maximum + 'M',
                      'SystemKeepFree': '128M', 'RuntimeMaxUse': runtime + 'M',
                      'MaxRetentionSec': days + 'day', 'RateLimitIntervalSec': '30s', 'RateLimitBurst': '10000'}}
target = pathlib.Path('/var/lib/lab-hardening/policy.json')
temporary = target.with_suffix('.tmp')
temporary.write_text(json.dumps(policy, indent=2) + '\n')
temporary.chmod(0o644)
os.replace(temporary, target)
SAVE_POLICY
systemctl enable --now lab-hardening-check.timer
if ! systemctl start lab-hardening-check.service; then
  journalctl -u lab-hardening-check.service -n 50 --no-pager >&2
  false
fi
cat /var/lib/lab-hardening/status.json
effective_timezone=$(/usr/local/sbin/lab-timezone check /var/lib/lab-hardening/policy.json)
timezone_action=set; [[ $PRESERVE_TIMEZONE != 1 ]] || timezone_action=preserved
printf "Timezone: %s (%s; guest files verified).\n" "$effective_timezone" "$timezone_action"
printf '\nShared hardening applied (%s). Backups: %s\n' "$PROFILE" "$backup"
echo 'Manual check: /usr/local/sbin/lab-hardening-check'
echo 'Local reports: /var/lib/lab-hardening/status.json and journalctl -u lab-hardening-check'
echo 'Application image updates, source-specific UFW rules and app health remain with the creator.'
LAB_HARDENING_GUEST
)
# ── End shared hardening block ────────────────────────────────────────────────
# END CANONICAL HARDENING: v1.2.0
# BEGIN COMMON: UFW PRESERVATION CHECK
# COMMON UFW PRESERVATION CHECK
INSTALL_STAGE="final verification"
UFW_RULES_AFTER=$(pct exec "$CT_ID" -- bash -s <<'UFW_SNAPSHOT_AFTER'
set -euo pipefail
sha256sum /etc/ufw/{before,after,user}{,6}.rules
iptables -w 5 -S
ip6tables -w 5 -S
UFW_SNAPSHOT_AFTER
)
[[ $UFW_RULES_BEFORE == "$UFW_RULES_AFTER" ]] || {
  echo 'ERROR: Persistent/effective UFW rules changed during hardening; CT preserved.' >&2
  false
}
unset UFW_RULES_BEFORE UFW_RULES_AFTER
# END COMMON: UFW PRESERVATION CHECK

pct exec "$CT_ID" -- /usr/local/bin/matrix-maint.sh check --initial
pct exec "$CT_ID" -- /usr/local/sbin/lab-hardening-check
# BEGIN COMMON: FINAL TIMEZONE CHECK
# COMMON FINAL TIMEZONE CHECK
EFFECTIVE_GUEST_TIMEZONE=$(pct exec "$CT_ID" -- /usr/local/sbin/lab-timezone check /var/lib/lab-hardening/policy.json)
[[ $EFFECTIVE_GUEST_TIMEZONE == "$APP_TZ" ]] || {
  echo 'ERROR: Planned application timezone differs from the final guest timezone; CT preserved.' >&2
  false
}
unset TIMEZONE_PLAN
# END COMMON: FINAL TIMEZONE CHECK

HARDENING_STATUS=$(pct exec "$CT_ID" -- python3 -c 'import json; print(json.load(open("/var/lib/lab-hardening/status.json"))["status"])')
[[ $HARDENING_STATUS == OK || $HARDENING_STATUS == WARN ]] || {
  echo 'ERROR: Hardening verification did not pass; CT preserved.' >&2
  false
}

INSTALL_STAGE="timer and protection"
# Persistent image timers may catch up immediately. Activate only after all
# final application/common/timezone verification above has succeeded.
pct exec "$CT_ID" -- systemctl daemon-reload
if [[ $AUTO_UPDATE == 1 ]]; then
  pct exec "$CT_ID" -- systemctl enable --now matrix-update.timer
else
  pct exec "$CT_ID" -- systemctl disable --now matrix-update.timer
fi
pct exec "$CT_ID" -- python3 - "$AUTO_UPDATE" "$UPDATE_TIME" "$APP_TZ" <<'TIMER_VERIFY'
import json, re, subprocess, sys
from pathlib import Path
enabled, schedule, zone = sys.argv[1:]
def require(ok, message):
    if not ok:
        raise SystemExit('ERROR: Matrix timer: ' + message)
def show(prop):
    result = subprocess.run(['systemctl', 'show', 'matrix-update.timer', '-p', prop, '--value'],
                            capture_output=True, text=True, timeout=15)
    require(result.returncode == 0, 'cannot inspect timer state')
    return result.stdout.strip()
content = Path('/etc/systemd/system/matrix-update.timer').read_text()
calendar = '*-*-* ' + schedule + ':00'
require(re.findall(r'^OnCalendar=(.*)$', content, re.M) == [calendar], 'installed calendar differs')
require(re.findall(r'^Persistent=(.*)$', content, re.M) == ['true'], 'persistent catch-up policy differs')
require(re.findall(r'^WantedBy=(.*)$', content, re.M) == ['timers.target'], 'timer install target differs')
require(calendar in show('TimersCalendar'), 'loaded calendar differs')
require(show('Unit') == 'matrix-update.service', 'timer service differs')
require(show('UnitFileState') == ('enabled' if enabled == '1' else 'disabled'), 'enablement differs')
require(show('ActiveState') == ('active' if enabled == '1' else 'inactive'), 'active state differs')
next_elapse = show('NextElapseUSecRealtime')
require(enabled != '1' or next_elapse not in ('', 'n/a', '0'), 'active timer lacks next elapse')
service = Path('/etc/systemd/system/matrix-update.service').read_text()
require(re.findall(r'^ExecStart=(.*)$', service, re.M) == ['/usr/local/bin/matrix-maint.sh auto-update'], 'maintenance command differs')
require(json.loads(Path('/var/lib/lab-hardening/policy.json').read_text())['timezone']['effective'] == zone,
        'final timezone policy differs')
result = subprocess.run(['systemd-analyze', 'calendar', '--iterations=1', calendar],
                        text=True, capture_output=True, timeout=15)
require(result.returncode == 0 and 'Next elapse:' in result.stdout, 'calendar has no computable next elapse')
next_calendar = next(line.strip() for line in result.stdout.splitlines() if 'Next elapse:' in line)
print('Image timer: ' + ('enabled/active' if enabled == '1' else 'disabled/inactive') + '; daily ' + schedule + ' (' + zone + ')')
print('  ' + next_calendar + (' (calendar preview; timer inactive)' if enabled == '0' else ''))
TIMER_VERIFY

MX_DESC="Matrix Synapse + Element Web; Debian 13 unprivileged LXC.
Element: https://${ELEMENT_FQDN}/ | Synapse: https://${SYNAPSE_FQDN}/
Permanent Matrix ID: @user:${SYNAPSE_SERVER_NAME}
UFW inside CT: ${FIREWALL_ACCESS}. PostgreSQL: loopback only.
Hardening v1.2.0: ${HARDENING_STATUS}; timezone: ${EFFECTIVE_GUEST_TIMEZONE}.
Image updates: AUTO_UPDATE=${AUTO_UPDATE}, daily ${UPDATE_TIME} local time."
pct set "$CT_ID" --description "$MX_DESC"
# BEGIN COMMON: PROTECTION
pct set "$CT_ID" --protection 1
# END COMMON: PROTECTION
pct config "$CT_ID" | grep -qx 'protection: 1'
pct exec "$CT_ID" -- passwd -S root | awk '$2 == "P" {ok=1} END {exit !ok}'
CT_IPV6=$(pct exec "$CT_ID" -- ip -6 -o addr show scope global | awk '{print $4}' | paste -sd ' ')

INSTALL_STAGE="summary"
cat <<SUMMARY

  MATRIX INSTALLATION VERIFIED

  Container: $HN | CT $CT_ID | IPv4 $CT_IP | IPv6 ${CT_IPV6:-none}
  Debian 13, unprivileged, protected. Root password set; console: pct enter $CT_ID.
  SSH policy: keep=$HARDENING_KEEP_SSH (0=removed/masked; 1=preserved without new access).

  Access:
    Synapse: https://${SYNAPSE_FQDN}/ -> http://${CT_IP}:${SYNAPSE_PORT}
    Element: https://${ELEMENT_FQDN}/ -> http://${CT_IP}:${ELEMENT_PORT}
    Permanent Matrix ID: @user:${SYNAPSE_SERVER_NAME} — do not change server_name.
    HTTP access: $FIREWALL_ACCESS
    NPM/client IPv4 hosts: ${BACKEND_ALLOWED_IPV4[*]:-none selected}
    NPM/client IPv6 hosts: ${BACKEND_ALLOWED_IPV6[*]:-none selected}
    PostgreSQL: 127.0.0.1:5432, SCRAM; restricted synapse role, C locale.
    Administrator API: use CT loopback; block /_synapse/admin at the public proxy.

  Firewall: UFW inside CT, IPv4/IPv6; no Proxmox firewall dependency.
    All six UFW rule files and both full filter tables unchanged across hardening.
    Listener inventory only: TCP=${HARDENING_TCP_PORTS:-inventory-only}; UDP=${HARDENING_UDP_PORTS:-inventory-only}
    Inventory does not add UFW access. DHCP/control-traffic rules are retained.

  Timezone: $EFFECTIVE_GUEST_TIMEZONE ($TIMEZONE_ACTION).
    TZ delivery verified for Synapse, Element and PostgreSQL; Synapse local-time
    behavior checked. Element browser time and PostgreSQL SQL/log zones stay separate.

  Runtime and files:
    Synapse:    $SYNAPSE_IMAGE
                $SYNAPSE_IMAGE_ID
    Element:    $ELEMENT_IMAGE
                $ELEMENT_IMAGE_ID
    PostgreSQL: $POSTGRES_IMAGE
                $POSTGRES_IMAGE_ID
    Immutable IDs; Pull=never; host networking.
    Quadlets: /etc/containers/systemd/matrix-*.container
    State/policy: /opt/matrix/.env, install-policy.json, firewall-policy.json
    Persistent data: /opt/matrix/postgresdata/18/docker, /opt/matrix/synapse
    Element config: /opt/matrix/element-config.json
    PRIVATE credentials: /opt/matrix/postgres.env and synapse/homeserver.yaml (0600).

  Updates and recovery:
    Image AUTO_UPDATE=$AUTO_UPDATE; daily $UPDATE_TIME ($EFFECTIVE_GUEST_TIMEZONE).
    Common hardening checker: after boot and hourly; status=$HARDENING_STATUS.
    Wait budgets: initial ${INITIAL_WAIT_SECONDS}s; maintenance ${UPDATE_WAIT_SECONDS}s.
    PBS/PVE checkpoint is your responsibility; --yes creates/verifies no backup.
    Cover the full CT: /opt/matrix, /var/lib/containers/storage, units and policies.
    No external data mounts are created. A live snapshot alone proves no DB consistency.
    FUSE=$PODMAN_FUSE_OVERLAY: with FUSE use stop-mode PBS; otherwise validate backups under I/O.
    Old images are retained. Image reversal does not undo a database migration.
    Stateful target starts never trigger automatic image/database downgrades.

  Run on Proxmox:
    pct exec $CT_ID -- /usr/local/bin/matrix-maint.sh check
    pct exec $CT_ID -- /usr/local/bin/matrix-maint.sh version
    pct exec $CT_ID -- /usr/local/sbin/lab-hardening-check
    pct enter $CT_ID

  Run inside CT:
    /usr/local/bin/matrix-maint.sh check [--initial]
    /usr/local/bin/matrix-maint.sh version
    /usr/local/sbin/lab-hardening-check
    journalctl -u matrix-synapse.service -u matrix-postgres.service -u matrix-element.service
    /usr/local/bin/matrix-maint.sh --help

  Verification: shared Matrix checks passed before and after common hardening.
    Common result: $HARDENING_STATUS. WARN requires review; no automatic restart/reboot.
    Still test: NPM/client reachability and denied sources, public DNS/HTTPS,
    registration/login/federation, real calls/TURN, DHCP renewal, reviewed reboot
    persistence, and a reviewed update/check cycle with verified PBS/PVE coverage.

  Initial public setup:
    Reserve Matrix/NPM IPs. Route both names through NPM to the HTTP ports above;
    enable WebSockets. Set client_max_body_size ${MAX_UPLOAD_SIZE}, proxy_read_timeout
    600s, proxy_send_timeout 600s, and location ^~ /_synapse/admin { return 403; }.
    Configure public HTTPS. With Cloudflare Tunnel -> NPM HTTP, TLS terminates at
    Cloudflare. Matrix API/well-known paths must not receive browser challenges.
    x_forwarded is enabled: UFW source access and proxy-header trust are separate.
    Trust CF-Connecting-IP only from the actual cloudflared peer; loopback only
    when cloudflared reaches NPM in that same namespace. Never trust all sources.
    Enter-to-allow-any also permits direct HTTP; public client setup uses HTTPS.

    First administrator (inside CT, interactive):
      podman exec -it matrix-synapse register_new_matrix_user -c /data/homeserver.yaml http://127.0.0.1:${SYNAPSE_PORT}
    Registration tokens: use the administrator API on CT loopback; keep tokens private.
    Then sign in at https://${ELEMENT_FQDN}/.

    Legacy TURN: $TURN_MODE
    MatrixRTC auth: ${MATRIX_RTC_AUTH_URL:-not configured}
    LiveKit/MatrixRTC run separately. TURN alone is insufficient for modern calls.
SUMMARY
