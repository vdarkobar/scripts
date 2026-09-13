#!/usr/bin/env bash
set -Eeo pipefail

# Fresh-install creator; run on the Proxmox host. Edit the top Config block.
# Lab baseline: Tier 1 pinned Quadlet images, host networking, PBS/PVE recovery.
# Revision: 2026-09-13 — embedded approved hardening v1.1.1; final verification.
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
# Provisioning must create system files readable by unprivileged services (_apt).
# Restrict permissions locally when writing credentials; do not pass 077 to pct.
umask 022
export LC_ALL=C

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
APP_TZ="Europe/Berlin"
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
SYNAPSE_WAIT_SECONDS=1800             # upgrades: allow long migrations; never auto-downgrade
PODMAN_FUSE_OVERLAY=1                 # lab default; use stop-mode PBS backups with FUSE
# Native overlay (=0) still needs validation under snapshot-mode backup with I/O.
EXTRA_PACKAGES=()
CLEANUP_ON_FAIL=1                     # until first service start; CT preserved after that
SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/matrix-quadlet.sh"
SCRIPT_LOCAL="/root/matrix-quadlet.sh"

# Shared hardening: final port lists inventory/reject external listeners only;
# they do not create UFW rules or prove health. Empty = inventory-only.
HARDENING_PROFILE="lxc"              # Debian 13 service LXC; no VPS/VM profile
HARDENING_RP_FILTER="1"              # 1=strict; 2=loose for asymmetric paths
HARDENING_KEEP_SSH="0"               # 0=remove SSH; manage with pct enter/exec
HARDENING_REMOVE_POSTFIX="1"         # 1=remove Postfix; 0=keep intentional mail service
HARDENING_JOURNAL_DAYS="14"
HARDENING_JOURNAL_MAX_MB="256"
HARDENING_JOURNAL_RUNTIME_MB="64"
HARDENING_UPDATE_MAX_AGE_HOURS="72"
HARDENING_TCP_PORTS="auto"           # Creator-only auto = finalized Synapse + Element ports
HARDENING_UDP_PORTS="68 546"          # DHCPv4/v6 can listen even with ip6=manual
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

# ── Trap cleanup ──────────────────────────────────────────────────────────────
# rc is captured before the trap is reset; $LINENO is the failing line at top
# level (BASH_LINENO[0] is 0 outside a function). After CREATED=1, failing
# checks must use `false` rather than `exit 1` so this trap runs cleanup.
STAGE="preflight"
# Assigned inside the trap at runtime.
# shellcheck disable=SC2154
trap 'rc=$?;
  trap - ERR
  echo "  ERROR: ${STAGE:-unknown} failed (rc=$rc) near line ${LINENO:-?}" >&2
  # BASH_COMMAND can contain an entire heredoc, including embedded code. Print
  # only its command word; guest stderr above retains the original failure.
  command_word=${BASH_COMMAND%%[[:space:]]*}
  printf "  Command: %.80s (arguments/body omitted)\n" "$command_word" >&2
  if [[ "${CLEANUP_ON_FAIL:-0}" -eq 1 && "${CREATED:-0}" -eq 1 ]]; then
    echo "  Cleanup: stopping/destroying CT ${CT_ID} ..." >&2
    pct stop "${CT_ID}" >/dev/null 2>&1 || true
    pct destroy "${CT_ID}" >/dev/null 2>&1 || true
  fi
  exit "$rc"
' ERR

trap 'rc=130;
  trap - ERR INT TERM HUP
  echo "  Interrupted during ${STAGE:-unknown} (rc=$rc), line ${LINENO:-?}" >&2
  if [[ "${CLEANUP_ON_FAIL:-0}" -eq 1 && "${CREATED:-0}" -eq 1 ]]; then
    echo "  Cleanup: stopping/destroying CT ${CT_ID} ..." >&2
    pct stop "${CT_ID}" >/dev/null 2>&1 || true
    pct destroy "${CT_ID}" >/dev/null 2>&1 || true
  fi
  exit "$rc"
' INT TERM HUP

# ── Preflight — root & commands ───────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pveversion sha256sum pvesh pveam pct pvesm qm curl python3 ip awk grep sed sort paste seq readlink cp chmod dpkg head tail tr mktemp mv flock rm sleep id cat bash install sync; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

# Verified Proxmox-only caller: discard the HOST login marker before any guest
# dispatch. A real SSH session running the standalone block inside a CT retains
# its marker and is still refused when KEEP_SSH=0.
pveversion >/dev/null
unset SSH_CONNECTION

[[ "$HN" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "ERROR: Invalid HN." >&2; exit 1; }
[[ -f "/usr/share/zoneinfo/$APP_TZ" ]] || { echo "ERROR: Unknown APP_TZ." >&2; exit 1; }
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
  Timezone:          $APP_TZ
  Podman storage:    $([ "$PODMAN_FUSE_OVERLAY" -eq 1 ] && echo "fuse-overlayfs (fuse=1)" || echo "native overlay (no FUSE)")
  Tags:              $TAGS
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled — daily at ${UPDATE_TIME} (re-pull ${SYNAPSE_TAG} / ${ELEMENT_TAG} / ${POSTGRES_TAG})" || echo "disabled (${SYNAPSE_TAG} / ${ELEMENT_TAG} / ${POSTGRES_TAG}, manual)")
  Cleanup on fail:   $CLEANUP_ON_FAIL (until first service start; CT preserved after that)
  Update recovery:   PBS/PVE checkpoint managed on the host; no in-CT archives
  Initial health:    ${INITIAL_WAIT_SECONDS}s; crash loops fail earlier
  Migration wait:    ${SYNAPSE_WAIT_SECONDS}s; timeout never downgrades a migrated database
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

response=""
read -r -p "  Continue with these settings? [y/N]: " response <&8 || response=""
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
for number in CPU RAM DISK SYNAPSE_PORT ELEMENT_PORT SYNAPSE_WAIT_SECONDS INITIAL_WAIT_SECONDS TURN_USER_LIFETIME_MS; do
  [[ ${!number} =~ ^[1-9][0-9]{0,9}$ ]] || { echo "ERROR: $number must be a positive decimal integer." >&2; exit 1; }
done
(( CPU >= 1 && RAM >= 2048 && DISK >= 16 )) || { echo "ERROR: CPU >= 1, RAM >= 2048 MB, DISK >= 16 GB required." >&2; exit 1; }
[[ $DEBIAN_VERSION == 13 ]] || { echo "ERROR: This installer targets Debian 13 only." >&2; exit 1; }
(( SYNAPSE_WAIT_SECONDS >= 60 && SYNAPSE_WAIT_SECONDS <= 86400 )) || { echo "ERROR: SYNAPSE_WAIT_SECONDS must be 60..86400." >&2; exit 1; }
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
[[ $APP_TZ =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)+$ && -f /usr/share/zoneinfo/$APP_TZ ]] || { echo "ERROR: Invalid timezone." >&2; exit 1; }
[[ $TAGS =~ ^[a-z0-9._-]+(;[a-z0-9._-]+)*$ ]] || { echo "ERROR: Invalid tags." >&2; exit 1; }
[[ -z $MAPTILER_KEY || $MAPTILER_KEY =~ ^[A-Za-z0-9_-]+$ ]] || { echo "ERROR: Invalid MapTiler key." >&2; exit 1; }
for pkg in "${EXTRA_PACKAGES[@]}"; do
  [[ $pkg =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || { echo "ERROR: Invalid extra package name." >&2; exit 1; }
done
for name in BRIDGE TEMPLATE_STORAGE CONTAINER_STORAGE; do
  [[ ${!name} =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { echo "ERROR: Invalid $name." >&2; exit 1; }
done
(( INITIAL_WAIT_SECONDS >= 30 && INITIAL_WAIT_SECONDS <= 600 )) || { echo "ERROR: INITIAL_WAIT_SECONDS must be 30..600." >&2; exit 1; }
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
[[ $HARDENING_TCP_PORTS != auto ]] || HARDENING_TCP_PORTS="$SYNAPSE_PORT $ELEMENT_PORT"
[[ $HARDENING_PROFILE == lxc ]] || { echo "ERROR: This creator requires HARDENING_PROFILE=lxc." >&2; exit 1; }
[[ $HARDENING_RP_FILTER =~ ^[12]$ ]] || { echo "ERROR: HARDENING_RP_FILTER must be 1 or 2." >&2; exit 1; }
for flag in HARDENING_KEEP_SSH HARDENING_REMOVE_POSTFIX; do
  [[ ${!flag} =~ ^[01]$ ]] || { echo "ERROR: $flag must be 0 or 1." >&2; exit 1; }
done
for number in HARDENING_JOURNAL_DAYS HARDENING_JOURNAL_MAX_MB HARDENING_JOURNAL_RUNTIME_MB HARDENING_UPDATE_MAX_AGE_HOURS; do
  [[ ${!number} =~ ^[1-9][0-9]{0,3}$ ]] || { echo "ERROR: $number must be 1..9999." >&2; exit 1; }
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

STAGE="CT creation"
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

STAGE="OS bootstrap"
# ── OS update ─────────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  export LANG=C.UTF-8
  export LC_ALL=C.UTF-8
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
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  apt-get update -qq
  apt-get install -y locales curl ca-certificates iproute2 podman tar gzip python3 python3-yaml util-linux ufw iptables ${PODMAN_FUSE_PKG}
  sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
  ln -sf /usr/share/zoneinfo/${APP_TZ} /etc/localtime
  echo '${APP_TZ}' > /etc/timezone
"

STAGE="firewall setup"
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
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
# A running oneshot unit alone does not prove UFW was enabled or rules loaded.
# Called before every Synapse/Element start, including boot and updates.
grep -qx 'ENABLED=yes' /etc/ufw/ufw.conf
grep -qx 'IPV6=yes' /etc/default/ufw
status=$(/usr/sbin/ufw status)
grep -qx 'Status: active' <<< "$status"
for tool in /usr/sbin/iptables /usr/sbin/ip6tables; do
  prefix=ufw
  [[ ${tool##*/} != ip6tables ]] || prefix=ufw6
  rules=$("$tool" -w 5 -S INPUT)
  grep -qx -- '-P INPUT DROP' <<< "$rules"
  rules=$("$tool" -w 5 -S FORWARD)
  grep -qx -- '-P FORWARD DROP' <<< "$rules"
  # UFW uses ufw-* for IPv4 and ufw6-* for IPv6, even with no allowed IPv6 sources.
  "$tool" -w 5 -C INPUT -j "${prefix}-before-input"
  "$tool" -w 5 -S "${prefix}-user-input" >/dev/null
done
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

STAGE="image acquisition"
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

STAGE="image compatibility"
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

STAGE="application configuration"
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
SYNAPSE_WAIT_SECONDS=${SYNAPSE_WAIT_SECONDS}
PODMAN_FUSE_OVERLAY=${PODMAN_FUSE_OVERLAY}
TURN_MODE=${TURN_MODE}
MATRIX_RTC_AUTH_URL=${MATRIX_RTC_AUTH_URL}
MATRIX_RTC_HEALTH_URL=${MATRIX_RTC_HEALTH_URL}
EOF2
  chmod 0600 '${APP_DIR}/.env'
"

STAGE="startup"
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
CLEANUP_ON_FAIL=0
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  systemctl start '${SYNAPSE_QUADLET_SERVICE}' '${ELEMENT_QUADLET_SERVICE}'
"

STAGE="early verification"
# ── Verification ──────────────────────────────────────────────────────────────
sleep 30
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

RUNNING="$(pct exec "$CT_ID" -- sh -lc \
  'podman ps --filter name=^matrix-synapse$ --filter name=^matrix-element$ --filter name=^matrix-postgres$ --format "{{.Names}}" 2>/dev/null | wc -l' \
  2>/dev/null || echo 0)"
pct exec "$CT_ID" -- bash -lc 'set -euo pipefail; podman ps' || true

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
DB_COLLATE="$(pct exec "$CT_ID" -- sh -lc "podman exec matrix-postgres psql -U postgres -d synapse -tAc \"select datcollate from pg_database where datname = current_database()\" 2>/dev/null" 2>/dev/null | tr -d '[:space:]' || true)"
if [[ "$DB_COLLATE" == "C" ]]; then
  echo "  Database collation is C (Synapse requirement)"
else
  echo "  ERROR: synapse database collation is '${DB_COLLATE:-n/a}', expected 'C' — POSTGRES_INITDB_ARGS was not applied at initdb" >&2
  echo "  Inspect POSTGRES_INITDB_ARGS in ${POSTGRES_ENV_FILE} without sharing its secrets." >&2
  VERIFY_FAIL=1
fi

SY_HEALTHY=0
SY_WAIT_START=$SECONDS
while (( SECONDS - SY_WAIT_START < INITIAL_WAIT_SECONDS )); do
  SY_STATE=$(pct exec "$CT_ID" -- systemctl show matrix-synapse.service -p ActiveState --value)
  SY_RESTARTS=$(pct exec "$CT_ID" -- systemctl show matrix-synapse.service -p NRestarts --value)
  [[ $SY_STATE != failed && ${SY_RESTARTS:-0} == 0 ]] || break
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
KEY_SERVER_NAME="$(pct exec "$CT_ID" -- python3 -c '
import json, sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=3) as response:
    print(json.load(response)["server_name"])
' "http://127.0.0.1:${SYNAPSE_PORT}/_matrix/key/v2/server" 2>/dev/null || true)"
if [[ "$KEY_SERVER_NAME" == "$SYNAPSE_SERVER_NAME" ]]; then
  echo "  Synapse server_name confirmed: ${KEY_SERVER_NAME}"
else
  echo "  ERROR: Synapse reports server_name '${KEY_SERVER_NAME:-n/a}', expected '${SYNAPSE_SERVER_NAME}'" >&2
  VERIFY_FAIL=1
fi

# Synapse creates its schema on first start; an empty public schema means it came
# up without a working database block (or the deltas failed silently).
TABLE_COUNT="$(pct exec "$CT_ID" -- sh -lc "podman exec matrix-postgres psql -U postgres -d synapse -tAc \"select count(*) from pg_tables where schemaname='public'\" 2>/dev/null" 2>/dev/null | tr -d '[:space:]' || true)"
if [[ "$TABLE_COUNT" =~ ^[0-9]+$ ]] && (( TABLE_COUNT > 0 )); then
  echo "  Database schema created (${TABLE_COUNT} tables in schema public)"
else
  echo "  ERROR: No tables found in the synapse database — schema was not created" >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u matrix-synapse.service --no-pager -n 80" >&2
  VERIFY_FAIL=1
fi

EL_HEALTHY=0
# shellcheck disable=SC2034
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

# ── Verify authentication and effective database privileges ───────────────────
# pg_isready alone cannot verify passwords. Require a deliberately bad password
# to fail, then verify the real application password over TCP without argv leaks.
if pct exec "$CT_ID" -- podman exec -e PGPASSWORD=deliberately-wrong matrix-postgres \
  psql -w -h 127.0.0.1 -U synapse -d synapse -tAc 'SELECT 1' >/dev/null 2>&1; then
  echo "ERROR: PostgreSQL accepted an incorrect password on TCP loopback." >&2
  VERIFY_FAIL=1
fi
if ! printf '%s\n' "$DB_PASSWORD" | pct exec "$CT_ID" -- podman exec -i matrix-postgres \
  bash -c 'IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql -w -h 127.0.0.1 -U synapse -d synapse -tAc "SELECT 1"' >/dev/null; then
  echo "ERROR: PostgreSQL rejected the application password over TCP." >&2
  VERIFY_FAIL=1
fi
ROLE_OK=$(pct exec "$CT_ID" -- podman exec matrix-postgres psql -U postgres -d postgres -tAc \
  "SELECT rolcanlogin AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication AND NOT rolbypassrls FROM pg_roles WHERE rolname='synapse'" | tr -d '[:space:]')
[[ $ROLE_OK == t ]] || { echo "ERROR: Synapse database role has unexpected privileges." >&2; VERIFY_FAIL=1; }
OWNER_OK=$(pct exec "$CT_ID" -- podman exec matrix-postgres psql -U postgres -d postgres -tAc \
  "SELECT pg_get_userbyid(datdba)='synapse' AND datcollate='C' AND datctype='C' FROM pg_database WHERE datname='synapse'" | tr -d '[:space:]')
[[ $OWNER_OK == t ]] || { echo "ERROR: Database owner/locale is incorrect." >&2; VERIFY_FAIL=1; }
HBA_OK=$(pct exec "$CT_ID" -- podman exec matrix-postgres psql -U postgres -d postgres -tAc \
  "SELECT count(*)=0 FROM pg_hba_file_rules WHERE error IS NOT NULL OR (type LIKE 'host%' AND auth_method <> 'scram-sha-256')" | tr -d '[:space:]')
[[ $HBA_OK == t ]] || { echo "ERROR: Unexpected host authentication rule in pg_hba.conf." >&2; VERIFY_FAIL=1; }
# Round-trip unquoted env-file secrets, without printing their values.
for secret in POSTGRES_PASSWORD SYNAPSE_DB_PASSWORD; do
  got=$(pct exec "$CT_ID" -- podman exec matrix-postgres printenv "$secret") || got=""
  expected=$DB_PASSWORD
  [[ $secret != POSTGRES_PASSWORD ]] || expected=$PG_ADMIN_PASSWORD
  [[ $got == "$expected" ]] || { echo "ERROR: $secret env-file round trip failed." >&2; VERIFY_FAIL=1; }
done
unset DB_PASSWORD PG_ADMIN_PASSWORD TURN_SHARED_SECRET got expected


if ! pct exec "$CT_ID" -- /usr/local/sbin/matrix-ufw-check; then
  echo "  ERROR: UFW is inactive or its IPv4/IPv6 filtering is incomplete." >&2
  VERIFY_FAIL=1
fi

if (( VERIFY_FAIL == 1 )); then
  echo "" >&2
  echo "  FATAL: Core verification failed — CT $CT_ID is preserved but the install is incomplete." >&2
  echo "  Collect read-only diagnostics; correct the creator and use a fresh ID and hostname." >&2
  false
fi

STAGE="maintenance setup"
# ── Maintenance helper ────────────────────────────────────────────────────────
tmp="$(mktemp)"
cat > "$tmp" <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail
umask 077
export LC_ALL=C

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
      SYNAPSE_IMAGE_REPO|SYNAPSE_TAG|SYNAPSE_IMAGE|SYNAPSE_IMAGE_ID|ELEMENT_IMAGE_REPO|ELEMENT_TAG|ELEMENT_IMAGE|ELEMENT_IMAGE_ID|POSTGRES_IMAGE_REPO|POSTGRES_TAG|POSTGRES_IMAGE|POSTGRES_IMAGE_ID|SYNAPSE_PORT|ELEMENT_PORT|SYNAPSE_WAIT_SECONDS|AUTO_UPDATE|PODMAN_FUSE_OVERLAY)
        [[ $value =~ ^[A-Za-z0-9_./:+-]+$ ]] || die "Invalid value for $key. Use unquoted KEY=value."
        printf -v "$key" '%s' "$value"
        ;;
      *) ;;  # preserve other configuration keys without executing or interpreting them
    esac
  done < "$ENV_FILE"
  for key in SYNAPSE_PORT ELEMENT_PORT SYNAPSE_WAIT_SECONDS AUTO_UPDATE PODMAN_FUSE_OVERLAY; do
    [[ ${seen[$key]+yes} ]] || die "Missing state key: $key"
  done
  [[ $SYNAPSE_PORT =~ ^[1-9][0-9]{3,4}$ && $ELEMENT_PORT =~ ^[1-9][0-9]{3,4}$ ]] || die "Invalid HTTP ports."
  (( SYNAPSE_PORT <= 65535 && ELEMENT_PORT <= 65535 )) || die "Invalid HTTP ports."
  [[ $SYNAPSE_WAIT_SECONDS =~ ^[1-9][0-9]{1,4}$ ]] && (( SYNAPSE_WAIT_SECONDS <= 86400 )) || die "Invalid migration wait."
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
          systemctl start matrix-synapse.service && wait_for_component synapse "$SYNAPSE_WAIT_SECONDS" || restored=0
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
      [[ $COMPONENT != POSTGRES ]] || printf '  After PostgreSQL is healthy: systemctl start matrix-synapse.service\n' >&2
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
  local old_variant new_variant old_version new_version target_image use_previous=0 previous_id="" old_previous_id=""
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
    old_previous_id=$(unit_value '# PreviousImageID=' "$UNIT" 2>/dev/null || true)
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
  /usr/local/sbin/matrix-ufw-check || die "UFW filtering is not active; restore firewall policy before maintenance."
  systemctl is-active --quiet "$SERVICE" || die "$SERVICE must be active before updating."
  actual=$(podman inspect --format '{{.Image}}' "matrix-${component,,}") || die "Cannot inspect running image."
  actual=$(image_id "$actual") || die "Running image is unavailable."
  [[ $actual == "$old_id" ]] || die "Running and configured IDs differ; inspect/restart the selected service first."
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
    wait_for_component "${component,,}" "$([[ $component == SYNAPSE ]] && printf '%s' "$SYNAPSE_WAIT_SECONDS" || printf 120)" \
      || die "$SERVICE failed readiness or restarted. Inspect logs; migration timeout does not kill Synapse."
    if [[ $component == POSTGRES ]]; then
      systemctl start matrix-synapse.service
      wait_for_component synapse "$SYNAPSE_WAIT_SECONDS" || die "Synapse did not recover after the database update."
    fi
  fi
  actual=$(podman inspect --format '{{.Image}}' "matrix-${component,,}")
  [[ $(image_id "$actual") == "$new_id" ]] || die "Running image does not match target."
  if [[ $component == ELEMENT ]]; then
    curl -fsS --max-time 10 "http://127.0.0.1:$ELEMENT_PORT/config.json" | python3 -m json.tool >/dev/null
  fi
  SWITCHED=0; START_ATTEMPTED=0; APP_STOPPED=0
  rm -rf -- "$WORK"; WORK=""
  if [[ $old_id != "$new_id" ]]; then
    # Element: retain exactly one previous image under a local reference. Reverting
    # its exact captured ID uses update-element previous, with no DB restore.
    if [[ $component == ELEMENT ]]; then
      if [[ $old_previous_id =~ ^sha256:[a-f0-9]{64}$ && $old_previous_id != "$old_id" && $old_previous_id != "$new_id" ]]; then
        podman rmi "$old_previous_id" >/dev/null 2>&1 || true
      fi
    else
      podman rmi "$old_id" >/dev/null 2>&1 || true
    fi
  fi
  read_state
  printf '  Updated %s to %s (%s).\n' "$component" "$target" "$new_id"
}

[[ $EUID == 0 ]] || die "Run as root inside the Matrix CT."
for command in podman systemctl curl python3 awk sed sort head cat stat grep mktemp cp chmod mv rm flock; do
  command -v "$command" >/dev/null || die "Missing command: $command"
done
[[ -f $ENV_FILE ]] || die "Missing $ENV_FILE; this helper belongs to the rewritten creator."
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
    (( $# == 0 )) || die "auto-update takes no positional arguments."
    [[ $AUTO_UPDATE == 1 ]] || { echo '  AUTO_UPDATE=0; skipping.'; exit 0; }
    YES=1
    # No all-stack transaction: earlier successful component changes remain if
    # a later pull/update fails. Each component is independently coherent.
    update_component POSTGRES
    update_component SYNAPSE
    update_component ELEMENT
    ;;
  version)
    (( $# == 0 )) || die "version takes no arguments."
    for component in SYNAPSE ELEMENT POSTGRES; do
      unit="$UNIT_DIR/matrix-${component,,}.container"
      printf '%s: %s\n  configured: %s\n  running:    %s\n' "$component" \
        "$(unit_value '# MatrixImage=' "$unit")" "$(unit_value 'Image=' "$unit")" \
        "$(podman inspect --format '{{.Image}}' "matrix-${component,,}" 2>/dev/null || printf unavailable)"
    done
    ;;
  --help|-h)
    cat <<'HELP'
Usage (root inside the CT):
  /usr/local/bin/matrix-maint.sh update [Synapse-vX.Y.Z] [--yes]
  /usr/local/bin/matrix-maint.sh update-element [Element-vX.Y.Z|previous] [--yes]
  /usr/local/bin/matrix-maint.sh update-postgres [18.MINOR-same-variant] [--yes]
  /usr/local/bin/matrix-maint.sh auto-update
  /usr/local/bin/matrix-maint.sh version

PBS/PVE owns backups and recovery. No in-CT backup/restore/rollback commands.
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
  *) die "Unknown command: $cmd. Use --help." ;;
esac
MAINT
pct push "$CT_ID" "$tmp" /usr/local/bin/matrix-maint.sh --perms 0755
rm -f "$tmp"
pct exec "$CT_ID" -- /usr/local/bin/matrix-maint.sh version

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
if [[ "$AUTO_UPDATE" -eq 1 ]]; then
  pct exec "$CT_ID" -- bash -lc 'set -euo pipefail; systemctl enable --now matrix-update.timer'
  echo "  Auto-update timer enabled"
else
  pct exec "$CT_ID" -- bash -lc 'set -euo pipefail; systemctl disable --now matrix-update.timer >/dev/null 2>&1 || true'
  echo "  Auto-update timer installed but disabled"
fi

# ── Extra packages ────────────────────────────────────────────────────────────
if [[ "${#EXTRA_PACKAGES[@]}" -gt 0 ]]; then
  pct exec "$CT_ID" -- bash -lc "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
    apt-get install -y ${EXTRA_PACKAGES[*]}
  "
fi

STAGE="package cleanup"
# ── Cleanup packages ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  apt-get purge -y man-db manpages 2>/dev/null || true
  apt-get -y autoremove
  apt-get -y clean
'

STAGE="MOTD"
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
cat > "$tmp" <<'MOTDSYSINFO'
#!/bin/sh
ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
printf '  Hostname:  %s\n' "$(hostname)"
printf '  IP:        %s\n' "${ip:-n/a}"
printf '  Uptime:    %s\n' "$(uptime -p 2>/dev/null || uptime)"
printf '  Disk:      %s\n' "$(df -h / | awk 'NR==2{printf "%s/%s (%s used)", $3, $2, $5}')"
MOTDSYSINFO
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
  fuse=$(sed -n 's/^PODMAN_FUSE_OVERLAY=//p' /opt/matrix/.env)
  if [ "$fuse" = 1 ]; then printf '  FUSE: stop-mode PBS backups; freezing a live CT can deadlock.\n'; fi
fi
printf '  Config: /opt/matrix/synapse/homeserver.yaml, /opt/matrix/.env\n'
printf '  Maintenance: /usr/local/bin/matrix-maint.sh --help\n'
printf '  Logs: journalctl -u matrix-synapse.service -f\n'
printf '  Ingress: UFW policy in /opt/matrix/firewall-policy.json.\n'
printf '  Verify: /usr/local/sbin/matrix-verify; /usr/local/sbin/lab-hardening-check\n'
printf '  Firewall: ufw status verbose; manage locally through pct enter/exec.\n'
printf '  Before updates: host PBS/PVE checkpoint. Synapse image reversal may be unsafe.\n'
printf '  Element updates are independent; HTTP readiness does not verify calls.\n'
MOTDAPP
pct push "$CT_ID" "$tmp" /etc/update-motd.d/30-app --perms 0755
cat > "$tmp" <<'MOTDFOOTER'
#!/bin/sh
printf '  ────────────────────────────────────\n\n'
MOTDFOOTER
pct push "$CT_ID" "$tmp" /etc/update-motd.d/99-footer --perms 0755
rm -f "$tmp"

# ── Final verification helper ─────────────────────────────────────────────────
# Reads configuration/runtime state; no updates, restarts or report-file writes.
tmp=$(mktemp)
cat > "$tmp" <<'MATRIX_VERIFY'
#!/usr/bin/python3
"""Read-only Matrix checks. No repairs, package/image changes or report writes."""
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import urllib.request
import yaml

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
        require(k not in result, 'Duplicate configuration key')
        result[k] = v
    return result

def http(port, path):
    with urllib.request.urlopen(f'http://127.0.0.1:{port}{path}', timeout=5) as response:
        require(response.status == 200, 'Unexpected HTTP status')
        return response.read()

def check_firewall():
    run(['/usr/local/sbin/matrix-ufw-check'], 'UFW boot guard')
    policy = json.loads(Path('/opt/matrix/firewall-policy.json').read_text())
    require(policy['ports'] == [sy_port, el_port], 'Firewall/application ports differ')
    sources = [ipaddress.ip_network(s) for s in policy['sources']]
    for family, tool, prefix in [(4, 'iptables', 'ufw'), (6, 'ip6tables', 'ufw6')]:
        chain = prefix + '-user-input'
        networks = [s for s in sources if s.version == family] if sources else [None]
        expected = set()
        for source in networks:
            for port in policy['ports']:
                rule = (['-s', str(source)] if source else []) + ['-p', 'tcp', '-m', 'tcp', '--dport', str(port), '-j', 'ACCEPT']
                run([tool, '-w', '5', '-C', chain] + rule, f'IPv{family} selected source rule / TCP {port}')
                expected.add(tuple(['-A', chain] + rule))
        actual = run([tool, '-w', '5', '-S', chain], f'IPv{family} user rules')
        # Exact user-chain policy also rejects broad/earlier rules that could
        # override the selected sources. Normalize host /32 and /128 spelling.
        actual_rules = set()
        for line in actual.splitlines():
            words = shlex.split(line)
            if words[:1] != ['-A']:
                continue
            if '-s' in words:
                i = words.index('-s') + 1
                words[i] = str(ipaddress.ip_network(words[i]))
            actual_rules.add(tuple(words))
        require(actual_rules == expected, f'IPv{family} UFW user policy has extra/mismatched rules; review without resetting UFW')

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
        info = json.loads(run(['podman', 'inspect', container], container + ' inspection'))[0]
        require(info['State']['Running'] and 'sha256:' + info['Image'].removeprefix('sha256:') == ids[0], container + ': running image/identity')
        require(info['HostConfig']['NetworkMode'] == 'host', container + ': host network')
        actual = {m['Destination']: (m['Source'], m['RW']) for m in info['Mounts']}
        for destination, value in mounts.items():
            require(actual.get(destination) == value, container + ': persistent mount ' + destination)
        run(['systemctl', 'is-active', '--quiet', container + '.service'], container + ' active')
        before = run(['systemctl', 'show', container + '.service', '-p', 'NRestarts', '--value'], container + ' restarts')
        require(before.isdigit(), container + ': missing restart counter')
        restart_counts[container] = before
        status = Path('/proc/' + str(info['State']['Pid']) + '/status').read_text()
        uid = int(re.search(r'^Uid:\s+(\d+)', status, re.M)[1])
        if name == 'synapse':
            require(uid == 991, 'Synapse main process UID must be 991')
        elif name == 'postgres':
            expected_uid = int(run(['podman', 'exec', container, 'id', '-u', 'postgres'], 'PostgreSQL UID'))
            require(uid == expected_uid and uid != 0, 'PostgreSQL main process UID')
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

def check_http():
    start = time.monotonic()
    while True:
        try:
            http(sy_port, '/health')
            key = json.loads(http(sy_port, '/_matrix/key/v2/server'))
            require(key['server_name'] == state['SYNAPSE_SERVER_NAME'], 'Synapse server identity')
            versions = json.loads(http(sy_port, '/_matrix/client/versions'))
            require(bool(versions['versions']), 'Matrix client versions response')
            require(json.loads(http(el_port, '/config.json')) == json.loads(Path('/opt/matrix/element-config.json').read_text()), 'Element served configuration')
            index = run(['podman', 'exec', 'matrix-element', 'cat', '/app/index.html'], 'Element image index')
            require(http(el_port, '/').decode().strip() == index, 'Element index differs from running image')
            return
        except Exception:
            if time.monotonic() - start >= 60:
                raise
            time.sleep(2)

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
    sockets = run(['ss', '-H', '-lnt'], 'TCP socket inventory')
    ports = {}
    for line in sockets.splitlines():
        endpoint = line.split()[3]
        address, port = endpoint.rsplit(':', 1)
        address = address.split('%', 1)[0].strip('[]')
        ports.setdefault(int(port), []).append(address)
    require(ports.get(5432) == ['127.0.0.1'], 'PostgreSQL must listen on IPv4 loopback only')
    for port in [sy_port, el_port]:
        require(any(a == '*' or not ipaddress.ip_address(a).is_loopback for a in ports.get(port, [])), f'External application TCP {port} missing')

require(os.geteuid() == 0, 'Run matrix-verify as root inside the Matrix CT')
try:
    state = state_file('/opt/matrix/.env')
    sy_port, el_port = int(state['SYNAPSE_PORT']), int(state['ELEMENT_PORT'])
    config = yaml.safe_load(Path('/opt/matrix/synapse/homeserver.yaml').read_text())
except Exception:
    raise SystemExit('FAIL: Matrix configuration is missing or malformed; no changes made.')
restart_counts = {}
for label, check in [('UFW effective sources', check_firewall), ('Services, images, mounts and ownership', check_identity), ('Application HTTP contracts', check_http), ('Database authentication and privileges', check_database), ('Listener bindings', check_sockets)]:
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

# ── Shared hardening integration ──────────────────────────────────────────────
STAGE="hardening"
# Capture all six persistent rule files and effective filter tables. No counters
# are included, so normal traffic cannot produce a false preservation failure.
UFW_FILES_BEFORE=$(pct exec "$CT_ID" -- sha256sum /etc/ufw/before.rules /etc/ufw/after.rules /etc/ufw/user.rules /etc/ufw/before6.rules /etc/ufw/after6.rules /etc/ufw/user6.rules)
UFW_V4_BEFORE=$(pct exec "$CT_ID" -- iptables -w 5 -S)
UFW_V6_BEFORE=$(pct exec "$CT_ID" -- ip6tables -w 5 -S)
# BEGIN APPROVED BASELINE: lab-hardening-block-v1.1.1.sh
# SHA256: d9a70377b0bea40f2d415f89a26678bf5b266b7812f734706235509dbf18f6b2
#!/usr/bin/env bash
# ── Shared Debian 13 LXC hardening block ───────────────────────────────────────
# Version: 1.1.1 (2026-09-12; scoped IPv6 listener parsing fix)
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
#   /etc/sysctl.d/99-hardening.conf
#   /etc/apt/apt.conf.d/99-lab-hardening
#   /etc/needrestart/conf.d/99-lab-hardening.conf
#   /etc/systemd/journald.conf.d/99-lab-hardening.conf
#   /etc/systemd/system/apt-daily{,-upgrade}.service.d/90-lab-readiness.conf (LXC)
#   /etc/systemd/system/lab-hardening-check.{service,timer}
#   /usr/local/sbin/lab-{apt-wait-online,hardening-check}
#   /etc/update-motd.d/25-lab-hardening
#   /etc/default/ufw (IPT_SYSCTL only); SSH service/socket masks (when SSH removed)
#   /var/lib/lab-hardening/{policy.json,status.json,last-index-refresh,check.lock}
#   /var/backups/lab-hardening/<run>/ (configuration copies and dry-run log)
# References: Debian trixie apt.conf(5), systemd-sysctl(8), ifquery(8),
# journald.conf(5), needrestart(1); kernel.org networking/ip-sysctl.html.
#
# Settings may instead be assigned in the creator's top config section.
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
  "$HARDENING_UDP_PORTS" <<'LAB_HARDENING_GUEST'
set -Eeuo pipefail
umask 022
export LC_ALL=C DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
PROFILE=$1 RP_FILTER=$2 KEEP_SSH=$3 REMOVE_POSTFIX=$4
JOURNAL_DAYS=$5 JOURNAL_MAX_MB=$6 JOURNAL_RUNTIME_MB=$7 UPDATE_MAX_AGE=$8
TCP_PORTS=$9 UDP_PORTS=${10}
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
for command in ufw iptables ip6tables ip ss sysctl python3 systemctl apt-get flock; do
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
          'warnings': warnings, 'external_listeners': listeners}
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
  if [[ $(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true) == installed ]]; then
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
printf '\nShared hardening applied (%s). Backups: %s\n' "$PROFILE" "$backup"
echo 'Manual check: /usr/local/sbin/lab-hardening-check'
echo 'Local reports: /var/lib/lab-hardening/status.json and journalctl -u lab-hardening-check'
echo 'Application image updates, source-specific UFW rules and app health remain with the creator.'
LAB_HARDENING_GUEST
)
# ── End shared hardening block ────────────────────────────────────────────────
# END APPROVED BASELINE: lab-hardening-block-v1.1.1.sh

STAGE="final verification"
UFW_FILES_AFTER=$(pct exec "$CT_ID" -- sha256sum /etc/ufw/before.rules /etc/ufw/after.rules /etc/ufw/user.rules /etc/ufw/before6.rules /etc/ufw/after6.rules /etc/ufw/user6.rules)
UFW_V4_AFTER=$(pct exec "$CT_ID" -- iptables -w 5 -S)
UFW_V6_AFTER=$(pct exec "$CT_ID" -- ip6tables -w 5 -S)
[[ $UFW_FILES_BEFORE == "$UFW_FILES_AFTER" && $UFW_V4_BEFORE == "$UFW_V4_AFTER" && $UFW_V6_BEFORE == "$UFW_V6_AFTER" ]] || {
  echo "ERROR: Hardening changed persistent/effective UFW rules. CT preserved for diagnosis." >&2
  false
}
pct exec "$CT_ID" -- /usr/local/sbin/matrix-verify
# The common block already ran its check service: WARN is a successful outcome.
HARDENING_STATUS=$(pct exec "$CT_ID" -- python3 -c 'import json; print(json.load(open("/var/lib/lab-hardening/status.json"))["status"])')
[[ $HARDENING_STATUS == OK || $HARDENING_STATUS == WARN ]] || { echo "ERROR: Hardening did not pass." >&2; false; }
echo "  UFW persistent/effective rules preserved; hardening: $HARDENING_STATUS"

# ── Proxmox UI description ────────────────────────────────────────────────────
LINK_STYLE="text-decoration: none; color: #00617f;"
MX_DESC="Public: <a href='https://${ELEMENT_FQDN}/' target='_blank' rel='noopener noreferrer' style='${LINK_STYLE}'>Element Web</a> · <a href='https://${SYNAPSE_FQDN}/' target='_blank' rel='noopener noreferrer' style='${LINK_STYLE}'>Synapse</a>
Backend ingress: UFW inside this CT; ${FIREWALL_ACCESS}.
<details><summary>Details</summary>Matrix Synapse + Element Web (Podman/Quadlet) on Debian ${DEBIAN_VERSION} LXC
Server name: ${SYNAPSE_SERVER_NAME} | Synapse: ${SYNAPSE_TAG} | Element: ${ELEMENT_TAG} | PostgreSQL: ${POSTGRES_TAG}
Created by matrix-quadlet.sh</details>"
pct set "$CT_ID" --description "$MX_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Terminal quality of life ──────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

STAGE="success reporting"
# ── Summary ───────────────────────────────────────────────────────────────────
cat <<SUMMARY

  MATRIX INSTALLATION COMPLETE

  OPEN ELEMENT       https://${ELEMENT_FQDN}/
  HOMESERVER         https://${SYNAPSE_FQDN}/
  CONTAINER          $HN | CT $CT_ID | $CT_IP
  LOGIN              root password set
  HARDENING          $HARDENING_STATUS (v1.1.1); SSH keep=$HARDENING_KEEP_SSH
  LISTENER POLICY    TCP=${HARDENING_TCP_PORTS:-inventory-only}; UDP=${HARDENING_UDP_PORTS:-inventory-only}
  PERMANENT ID       @user:${SYNAPSE_SERVER_NAME}

  IMPORTANT: Keep this Matrix server name. It is part of every user's identity.

  FIRST SETUP

  1. RESERVE THE IP ADDRESSES

     In your router/DHCP server, reserve the Matrix and NPM addresses:
       Matrix IPv4   $CT_IP
       NPM IPv4      ${BACKEND_ALLOWED_IPV4[*]}
       NPM IPv6      ${BACKEND_ALLOWED_IPV6[*]:-(none)}
     Selected backend access: $FIREWALL_ACCESS.

  2. CONFIGURE NGINX PROXY MANAGER (NPM)

     Create these two proxy hosts:
       ${SYNAPSE_FQDN} -> http://${CT_IP}:${SYNAPSE_PORT}
       ${ELEMENT_FQDN} -> http://${CT_IP}:${ELEMENT_PORT}

     For BOTH hosts:
       Scheme               http
       Forward Hostname/IP   $CT_IP
       Forward Port          Synapse: ${SYNAPSE_PORT} | Element: ${ELEMENT_PORT}
       Websockets Support    ON

     Synapse proxy host > Advanced tab (paste these nginx settings):
       client_max_body_size ${MAX_UPLOAD_SIZE};
       proxy_read_timeout 600s;
       proxy_send_timeout 600s;
       location ^~ /_synapse/admin { return 403; }

     HTTPS: Choose the setup that matches your ingress.

       CLOUDFLARE TUNNEL -> NPM PORT 80
         Leave NPM's SSL tab empty; Force SSL stays OFF.
         Cloudflare provides public HTTPS. Exempt Matrix API/well-known paths
         from browser challenges using the appropriate Cloudflare settings.

       DIRECT INTERNET -> NPM
         Configure a valid certificate and HTTPS in NPM.

     Public DNS and HTTPS must work for BOTH domains before Element login.
     Preserve Matrix request paths. Synapse serves its own discovery endpoints:
       /.well-known/matrix/server
       /.well-known/matrix/client

  3. CHECK ACCESS

     RUN INSIDE THE NPM CT -- each command should print HTTP 200:
       curl -sS -o /dev/null -w 'HTTP %{http_code}\n' --max-time 5 http://${CT_IP}:${SYNAPSE_PORT}/health
       curl -sS -o /dev/null -w 'HTTP %{http_code}\n' --max-time 5 http://${CT_IP}:${ELEMENT_PORT}/

     Restricted mode: other source hosts must be blocked on these URLs.
     Any-source mode: these URLs are allowed from any routable source.
     Element login still requires the public HTTPS domains above.
     Installer rule checks do not prove this full network path.

     Federation test (open in a browser):
       https://federationtester.matrix.org/#${SYNAPSE_SERVER_NAME}

  4. CREATE YOUR FIRST ADMINISTRATOR

     RUN ON THE PROXMOX HOST to enter the Matrix CT:
       pct enter $CT_ID

     THEN RUN INSIDE THE MATRIX CT:
       podman exec -it matrix-synapse register_new_matrix_user -c /data/homeserver.yaml http://127.0.0.1:${SYNAPSE_PORT}

     Answer y when asked whether the new account should be an administrator.
     Then sign in at https://${ELEMENT_FQDN}/

     Registration tokens: use an administrator access token with the admin API
     on CT loopback (127.0.0.1). Keep bearer tokens off unencrypted LAN HTTP.

  BEFORE UPDATING -- VERIFY YOUR BACKUP

     PBS/PVE is responsible for backup and recovery. The maintenance helper
     does not create or verify backups and has no full-stack restore command.

     BACK UP THE FULL CT, including:
       /opt/matrix                         database, media, keys and app config
       /var/lib/containers/storage         locally pinned container images
       Quadlets, maintenance files and UFW configuration

     For stateful updates, verify a suitable preupd recovery checkpoint with
     applications stopped. A live snapshot alone does not prove consistency.
SUMMARY
if (( PODMAN_FUSE_OVERLAY )); then
  echo "     BACKUP MODE: STOP -- FUSE is enabled; do not freeze a running FUSE CT."
else
  echo "     BACKUP MODE: Native overlay -- validate snapshot backups under I/O load."
fi
cat <<SUMMARY

  MAINTENANCE COMMANDS

     RUN ON THE PROXMOX HOST -- show current versions:
       pct exec $CT_ID -- /usr/local/bin/matrix-maint.sh version

     For interactive updates, enter the CT from the Proxmox host:
       pct enter $CT_ID

     THEN RUN INSIDE THE MATRIX CT -- one component at a time:

       Synapse:
         /usr/local/bin/matrix-maint.sh update ${SYNAPSE_TAG}

       Element:
         /usr/local/bin/matrix-maint.sh update-element ${ELEMENT_TAG}

       PostgreSQL:
         /usr/local/bin/matrix-maint.sh update-postgres ${POSTGRES_TAG}

     These are the installed tags. Reusing them checks for image rebuilds.
     To change versions, replace the tag with the desired full release tag.
     PostgreSQL must remain on major 18 and the same image variant.
     The helper prompts for confirmation; read the checkpoint reminder first.

     REVERT ELEMENT ONLY -- previous captured image, no registry pull:
       /usr/local/bin/matrix-maint.sh update-element previous

     Element updates/reverts preserve the database and media; check client
     compatibility. Synapse/PostgreSQL NEVER auto-downgrade after target start.
     If a stateful update fails, inspect migration logs and recover matching
     PBS/PVE state if needed. Earlier successful component updates stay applied.

     UNATTENDED UPDATES -- --yes skips confirmation; it does NOT verify a backup.
     Proxmox-host example, after you have verified the checkpoint:
       pct exec $CT_ID -- /usr/local/bin/matrix-maint.sh update ${SYNAPSE_TAG} --yes
     The same form works with update-element and update-postgres.

     Wait limits: first install ${INITIAL_WAIT_SECONDS}s; Synapse upgrades ${SYNAPSE_WAIT_SECONDS}s.
     Crashes fail earlier. A migration timeout does not kill Synapse.

  AUTOMATIC IMAGE UPDATES
SUMMARY
if (( AUTO_UPDATE )); then
  echo "     STATUS: ENABLED -- daily at $UPDATE_TIME ($APP_TZ)."
else
  echo "     STATUS: DISABLED -- the installed timer is inactive."
  echo "     Configured time if enabled: $UPDATE_TIME ($APP_TZ)."
fi
cat <<SUMMARY
     Auto-refresh checks the current pinned tags; it does not select new tags.
     Policy: AUTO_UPDATE in /opt/matrix/.env; timer enablement is separate.
     Schedule: OnCalendar in /etc/systemd/system/matrix-update.timer.
     After editing the timer, reload systemd and restart it if it is enabled.

  FIREWALL AND TROUBLESHOOTING

     UFW filters IPv4 and IPv6 inside this CT. Incoming connections are denied
     by default; ports ${SYNAPSE_PORT} and ${ELEMENT_PORT}: $FIREWALL_ACCESS.
     Outgoing traffic is allowed. Standard loopback, replies, DHCP and ICMP remain.
     PostgreSQL listens only on 127.0.0.1:5432, using SCRAM and a restricted role.
     No Proxmox Datacenter firewall switch or PVE firewall rules are required.

     RUN ON THE PROXMOX HOST:
       pct exec $CT_ID -- ufw status verbose
       pct exec $CT_ID -- /usr/local/sbin/matrix-verify
       pct exec $CT_ID -- /usr/local/sbin/lab-hardening-check
       pct enter $CT_ID

     INSIDE THE MATRIX CT -- follow Synapse logs (Ctrl+C stops following):
       journalctl -u matrix-synapse.service -f

     NPM ADDRESS CHANGED? For a successfully installed CT, run inside it.
     After a reviewed rule change, update the sources in
     /opt/matrix/firewall-policy.json to match the intended policy.
     Replace NEW_NPM_IP and OLD_NPM_IP with the exact host addresses.

       FIRST add the new address:
         ufw allow in proto tcp from NEW_NPM_IP to any port ${SYNAPSE_PORT}
         ufw allow in proto tcp from NEW_NPM_IP to any port ${ELEMENT_PORT}

       VERIFY access from NPM, THEN remove the old address:
         ufw delete allow in proto tcp from OLD_NPM_IP to any port ${SYNAPSE_PORT}
         ufw delete allow in proto tcp from OLD_NPM_IP to any port ${ELEMENT_PORT}

     UFW allow/delete commands apply immediately. Do not restart ufw.service
     for a rule edit: restarting it stops the dependent Matrix services.
     If you did restart UFW, start those services again inside this CT:
       systemctl start matrix-synapse.service matrix-element.service

  CALLING

     Legacy TURN mode: $TURN_MODE
SUMMARY
if [[ $TURN_MODE == disabled ]]; then
  echo "     No TURN relay is configured for legacy calls."
else
  echo "     TURN URIs: ${TURN_URIS[*]}"
  echo "     Test relay allocation from different networks; HTTP checks do not test calls."
fi
if [[ -n $MATRIX_RTC_AUTH_URL ]]; then
  echo "     Modern Element Call: external MatrixRTC backend configured."
  echo "     Authorization URL: $MATRIX_RTC_AUTH_URL"
  echo "     LiveKit and authorization run separately; verify with a real call."
else
  echo "     Modern Element Call: NOT CONFIGURED."
  echo "     It needs LiveKit + MatrixRTC authorization; TURN alone is insufficient."
  echo "     Set both RTC URLs to integrate an existing backend."
fi
if [[ $TURN_MODE == openrelay ]]; then
  echo "     Public test relay terms: https://www.metered.ca/tools/openrelay/"
fi
cat <<SUMMARY

  CONFIGURATION REFERENCE

     Maintenance policy     /opt/matrix/.env
                            Comments and blank lines are accepted.
     Synapse configuration  $SYNAPSE_DATA_DIR/homeserver.yaml
     Database credentials   $POSTGRES_ENV_FILE
     Element configuration  $ELEMENT_CONFIG_FILE
     Quadlet units          /etc/containers/systemd/matrix-*.container

     PRIVATE: homeserver.yaml and postgres.env contain secrets (permissions 0600).
     Keep them private when sharing diagnostics.

     Installed images:
       Synapse     $SYNAPSE_IMAGE
       Element     $ELEMENT_IMAGE
       PostgreSQL  $POSTGRES_IMAGE
     Quadlets use immutable image IDs with Pull=never.

     Cloudflare client IP forwarding -- NPM Advanced settings:
       ONLY if cloudflared reaches NPM through loopback in the same namespace:
         set_real_ip_from 127.0.0.1;
         real_ip_header CF-Connecting-IP;
       Otherwise trust the actual cloudflared source address, never all sources.
     Upload setting: ${MAX_UPLOAD_SIZE}; leave headroom below your upstream body cap.

  NEXT: Complete FIRST SETUP above, then open https://${ELEMENT_FQDN}/

SUMMARY
